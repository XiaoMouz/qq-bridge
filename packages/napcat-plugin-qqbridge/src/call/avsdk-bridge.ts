// 通话信令桥：在 QQ 内核（NodeIKernelAVSDKService）与 AV Host（加载 libAVSDKPlugin.so 的第二个 QQ/Electron 进程）之间转发数据。
// 思路与已知指令号来自 ClaudiaGardner/maibot-qq-voice-call（GPL-3.0）的 QQ AV Bridge；
// 与它不同的是：来电默认不自动接听，而是等 iPhone 端（经服务端）调用 accept()。
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import type { CaptureWriter } from '../capture.js';
import type { BridgeConfig } from '../config.js';
import { HttpError, type ControlServer } from '../control-server.js';
import { displayNameByUid, selfInfo, session, uidByUin, uinByUid } from '../core.js';
import type { NapCatPluginContext } from '../napcat.js';
import { redactDeep, summarizeValue } from '../redact.js';
import { buildAcceptParams } from './accept-params.js';

/**
 * 发给 AVSDK 插件的指令（embed.postMessage 的 cmd）。
 * 指令号 = libAVSDKPlugin.so 里 QRTCServiceInterfaceWrapper 方法表（成员函数指针，每项 16 字节）的下标：
 * 1 Login、2 LoginOut、4 StartCall、5 Accept、6 Ignore、7 Invite、8 Quit、9 Reject、10 Close、
 * 22 CloseMic、23 OpenMic、55 OnPenetrateEvent（转发内核数据）……（2026-10-13 从符号和 .rela.dyn 还原，1/5/55 与已验证的一致）。
 * param 是方法除第一个参数（实例 id）以外的参数；字符串数组后面的个数参数由插件自己补。
 */
export const AvCommand = { login: 1, startCall: 4, accept: 5, quit: 8, reject: 9, close: 10, kernelData: 55 } as const;

/** 来电的 invite_type / 来电数组 [0]：1 是 1 对 1，3 是群语音（多人通话，进房间后有成员进出、各人音量的输出）。 */
export const GROUP_INVITE_TYPE = 3;

/** AVSDK 插件输出（AV Host 转发过来的 message 事件的 cmd）。 */
export const AvOutput = {
  network: 20001,
  inviteDetail: 20006,
  acceptResult: 5,
  /** 拒接结果：[0, ""] 成功（引擎随即发 SsoRefuseInvite）。 */
  rejectResult: 9,
  enterRoom: 20004,
  /**
   * 通话引擎自己的运行日志（一行文本，以 "avsdk output(wrapper):" 开头）。
   * maibot 把它当成"要求重新登录"，2026-10-04 抓负载确认不是：登录结果（输出 1）每次都是成功。
   */
  engineLog: 20050,
  relogin: 120043,
} as const;

/** endReason：被本系统拒接（QQ 自己的结束原因都是非负数）。 */
export const REJECTED_HERE = -2;

export type CallPhase = 'idle' | 'ringing' | 'accepting' | 'accepted' | 'connected' | 'ended';

export interface CallState {
  callId: string | null;
  phase: CallPhase;
  inviteAt: string | null;
  acceptedAt: string | null;
  connectedAt: string | null;
  endedAt: string | null;
  endReason: number | null;
  inviteType: number | null;
  /** 群语音（多人通话，invite_type 3）所在的群号；1 对 1 通话为 null。 */
  groupCode: string | null;
  /** 自己打出去的（StartCall）。 */
  outgoing?: boolean;
  callerUid: string | null;
  callerUin: string | null;
  callerName: string | null;
  acceptRequested: boolean;
}

const KNOWN_KERNEL_CALLBACKS = [
  'onS2CActionToAVSDK',
  'onActionToAVSDK',
  'onAVSDKData',
  'onAVSdkCrash',
  'onReceiveInvite',
  'onInviteActionToAVSDK',
  'onGroupVideoActionToAVSDK',
  'onGroupVideoServerPushToAVSDK',
];

const MAX_NETWORK_PAYLOAD = 1024 * 1024;

/**
 * 通话引擎要求重新登录（120043）时的退避：第 n 次等 5s·2^(n-1)，10 分钟内超过 3 次就暂停通话桥。
 * 2026-10-02 在主号上出现过每秒 5 次的重登死循环：当时把引擎日志（20050）误当成"要求重登"，
 * 每次重登引擎又打出新日志。现在 20050 只记日志，这里的退避作为保险保留。
 */
const RELOGIN_WINDOW_MS = 10 * 60_000;
const RELOGIN_MAX = 3;
const RELOGIN_BASE_DELAY_MS = 5_000;

function idleCall(): CallState {
  return {
    callId: null,
    phase: 'idle',
    inviteAt: null,
    acceptedAt: null,
    connectedAt: null,
    endedAt: null,
    endReason: null,
    inviteType: null,
    groupCode: null,
    callerUid: null,
    callerUin: null,
    callerName: null,
    acceptRequested: false,
  };
}

export class AvsdkBridge {
  private service: Record<string, any> | null = null;
  private listenerId: number | null = null;
  /** AVSDK 输出 20006 给出的来电详情；接听参数从这里重排得到。 */
  private activeInvite: unknown[] | null = null;
  private acceptPostedFor: string | null = null;
  private loginPosted = false;
  private relogins: number[] = [];
  private reloginPaused: string | null = null;
  private loginTimer: NodeJS.Timeout | null = null;
  private acceptTimer: NodeJS.Timeout | null = null;
  private call: CallState = idleCall();
  private readonly changeListeners = new Set<(call: CallState) => void>();
  private readonly stats = {
    kernelEvents: 0,
    kernelForwarded: 0,
    avOutputs: 0,
    networkOutputs: 0,
    engineLogLines: 0,
    lastOutputCommand: null as number | null,
    lastError: null as string | null,
  };

  constructor(
    private readonly ctx: NapCatPluginContext,
    private readonly cfg: BridgeConfig,
    private readonly capture: CaptureWriter,
    private readonly opts: { reloginBaseDelayMs?: number } = {},
  ) {}

  start(): void {
    const s = session(this.ctx.core);
    const service = typeof s.getAVSDKService === 'function' ? s.getAVSDKService() : null;
    if (!service || typeof service.addKernelAVSDKListener !== 'function') {
      throw new Error('AVSDK service is unavailable in this QQ/NapCat build');
    }
    this.service = service;
    this.listenerId = service.addKernelAVSDKListener(this.makeListener());
    this.scheduleLogin(500);
  }

  stop(): void {
    if (this.loginTimer) clearTimeout(this.loginTimer);
    if (this.acceptTimer) clearTimeout(this.acceptTimer);
    this.loginTimer = null;
    this.acceptTimer = null;
    if (this.service && this.listenerId !== null && typeof this.service.removeKernelAVSDKListener === 'function') {
      try {
        this.service.removeKernelAVSDKListener(this.listenerId);
      } catch (error) {
        this.ctx.logger.warn('[qqbridge] AVSDK listener cleanup failed:', error);
      }
    }
    this.service = null;
    this.listenerId = null;
  }

  onChange(listener: (call: CallState) => void): () => void {
    this.changeListeners.add(listener);
    return () => this.changeListeners.delete(listener);
  }

  current(): CallState {
    return { ...this.call };
  }

  status(): Record<string, unknown> {
    return {
      serviceAvailable: Boolean(this.service),
      serviceNull: typeof this.service?.isNull === 'function' ? Boolean(this.service.isNull()) : null,
      serviceMethods: discoverMethods(this.service),
      listenerRegistered: this.listenerId !== null,
      loginPosted: this.loginPosted,
      reloginPaused: this.reloginPaused,
      autoAccept: this.cfg.autoAccept,
      stats: { ...this.stats },
      call: this.current(),
    };
  }

  /** 由 iPhone 端（经服务端）接听。来电详情可能晚于振铃到达，到达后自动补发接听。 */
  async accept(): Promise<CallState> {
    if (this.call.phase !== 'ringing' && this.call.phase !== 'accepting') {
      throw new HttpError(409, `no ringing call (phase=${this.call.phase})`);
    }
    this.call.acceptRequested = true;
    if (this.activeInvite) await this.sendAccept();
    this.emit();
    return this.current();
  }

  /**
   * 挂断（iPhone 端或服务端发起）：还在响铃就拒接（Reject），已经接了就结束通话（Close）。
   * 参数和接听一样取自来电数组：[类型 invite[0], 对方 uid invite[1], 原因 0]。
   * 结束状态以 QQ 内核的 onS2CActionToAVSDK（destroyReason）为准；3 秒内没等到就自己记为结束。
   */
  async hangup(): Promise<CallState> {
    const phase = this.call.phase;
    if (phase === 'idle' || phase === 'ended') return this.current();
    const callId = this.call.callId;
    const invite = this.activeInvite;
    if (this.acceptTimer) {
      clearTimeout(this.acceptTimer);
      this.acceptTimer = null;
    }
    this.call.acceptRequested = false;
    if (Array.isArray(invite) && typeof invite[0] === 'number' && typeof invite[1] === 'string') {
      // 自己打出去的：响铃中挂断也是 Close（取消呼叫），不是拒接。
      const answered = phase === 'accepting' || phase === 'accepted' || phase === 'connected' || this.call.outgoing === true;
      if (answered && invite[0] === GROUP_INVITE_TYPE) {
        // 群语音：Close 不会退出房间（2026-10-13 实测引擎回成功但没有退房的请求），要用 Quit [类型, 原因]。
        await this.invokeAVHost(AvCommand.quit, [invite[0], 0]);
      } else {
        await this.invokeAVHost(answered ? AvCommand.close : AvCommand.reject, [invite[0], invite[1], 0]);
      }
    }
    const timer = setTimeout(() => {
      if (this.call.callId !== callId || this.call.phase === 'ended' || this.call.phase === 'idle') return;
      this.call = { ...this.call, phase: 'ended', endedAt: new Date().toISOString(), endReason: this.call.endReason ?? -1 };
      this.emit();
    }, 3000);
    timer.unref?.();
    return this.current();
  }

  /**
   * 打出去（1 对 1 语音）：StartCall(4) 的参数是一段 JSON，字段从 libAVSDKPlugin.so 里还原
   * （scene / relation_id / sub_business_type / invite_uids …），1 对 1 是 scene 1、business_type 1（与来电的引擎日志一致）。
   * 引擎自己发邀请（输出 20001 交回内核），对方接了会进房间（20004），之后和来电一样。
   */
  async startCall(peerUin: string): Promise<CallState> {
    if (this.call.phase !== 'idle' && this.call.phase !== 'ended') throw new HttpError(409, `already in a call (phase=${this.call.phase})`);
    const uid = await uidByUin(this.ctx.core, peerUin);
    if (!uid) throw new HttpError(404, `no uid for ${peerUin}`);
    const params = {
      scene: 1,
      relation_id: 0,
      sub_business_type: 1,
      invite_uids: [uid],
      invite_count: 1,
      invite_reason: 0,
      invite_original: 0,
    };
    this.activeInvite = [1, uid, [uid]];
    this.acceptPostedFor = null;
    this.call = {
      ...idleCall(),
      callId: randomUUID(),
      phase: 'ringing',
      outgoing: true,
      inviteAt: new Date().toISOString(),
      inviteType: 1,
      callerUid: uid,
      callerUin: peerUin,
    };
    void this.resolveCaller(uid, this.call.callId);
    this.emit();
    await this.invokeAVHost(AvCommand.startCall, [JSON.stringify(params)]);
    return this.current();
  }

  registerRoutes(server: ControlServer, lab: boolean): void {
    server.route('GET', '/v1/status', () => this.status());
    server.route('GET', '/v1/calls/current', () => this.current());
    server.route('POST', '/v1/calls/accept', () => this.accept());
    server.route('POST', '/v1/calls/hangup', () => this.hangup());
    server.route('POST', '/v1/calls/start', ({ body }) => this.startCall(String((body as { peerUin?: unknown } | null)?.peerUin ?? '')));
    server.route('POST', '/v1/avsdk/output', async ({ body }) => {
      await this.handleOutput(body);
      return 'accepted';
    });
    if (lab) {
      // 研究用（G2 指令录制后的重放）：向 AVSDK 发送任意指令。
      server.route('POST', '/v1/avsdk/invoke', async ({ body }) => {
        const { command, params } = (body ?? {}) as { command?: unknown; params?: unknown };
        if (!Number.isInteger(command)) throw new HttpError(400, 'command must be an integer');
        if (!Array.isArray(params) || params.length > 16) throw new HttpError(400, 'params must be an array (<=16)');
        await this.invokeAVHost(command as number, params);
        return 'posted';
      });
    }
  }

  /** AV Host 把 AVSDK 插件的 message 事件转发到这里。 */
  async handleOutput(body: unknown): Promise<void> {
    const { command, id, value } = (body ?? {}) as { command?: unknown; id?: unknown; value?: unknown };
    if (!Number.isInteger(command)) throw new HttpError(400, 'invalid AVSDK output command');
    const cmd = command as number;
    this.stats.avOutputs += 1;
    this.stats.lastOutputCommand = cmd;
    if (cmd === AvOutput.engineLog) {
      // 引擎日志单独成文件（量大，混在指令采样里没法看）；排查通话问题时看 capture/avsdk-log-*.jsonl。
      this.stats.engineLogLines += 1;
      const line = Array.isArray(value) && typeof value[0] === 'string' ? value[0] : JSON.stringify(value);
      this.capture.write('avsdk-log', { line: line.slice(0, 4000) });
      return;
    }
    this.capture.write('avsdk', { dir: 'av-output', command: cmd, id, value: this.capturedValue(value) });

    switch (cmd) {
      case AvOutput.network: {
        if (!Array.isArray(value) || typeof value[0] !== 'number' || typeof value[1] !== 'string') {
          throw new HttpError(400, 'invalid AVSDK network output');
        }
        if (value[1].length > MAX_NETWORK_PAYLOAD) throw new HttpError(413, 'AVSDK network output is too large');
        if (typeof this.service?.setActionFromAVSDK !== 'function') throw new Error('setActionFromAVSDK is unavailable');
        await this.service.setActionFromAVSDK(value[0], value[1]);
        this.stats.networkOutputs += 1;
        break;
      }
      case AvOutput.inviteDetail: {
        if (!Array.isArray(value)) break;
        this.activeInvite = value;
        const callerUid = typeof value[1] === 'string' ? value[1] : null;
        // 来电数组：[类型, 邀请人 uid, [被邀请的 uid], ?, 群号（群语音）/ 会话键, ?, 房间号, …]
        const groupCode = value[0] === GROUP_INVITE_TYPE && value[4] ? String(value[4]) : this.call.groupCode;
        this.call = { ...this.call, callerUid, callerUin: null, callerName: null, groupCode };
        if (callerUid) void this.resolveCaller(callerUid, this.call.callId);
        if (this.call.acceptRequested) this.scheduleAccept(50);
        else if (this.cfg.autoAccept) this.scheduleAccept(500);
        this.emit();
        break;
      }
      case AvOutput.rejectResult: {
        // 拒接成功：没接通的来电 QQ 内核不会再给结束回调，这里直接记为结束（endReason -2 = 本系统拒接）。
        if (Array.isArray(value) && value[0] === 0 && this.call.phase === 'ringing') {
          this.call = { ...this.call, phase: 'ended', endedAt: new Date().toISOString(), endReason: REJECTED_HERE };
          this.emit();
        }
        break;
      }
      case AvOutput.acceptResult: {
        const ok = Array.isArray(value) && value[0] === 0;
        if (ok) {
          this.call = { ...this.call, phase: 'accepted', acceptedAt: new Date().toISOString() };
        } else {
          // 接听失败：允许再次 accept() 重试。
          this.acceptPostedFor = null;
          this.call = { ...this.call, phase: 'ringing' };
          this.stats.lastError = 'native accept returned failure';
        }
        this.emit();
        break;
      }
      case AvOutput.enterRoom: {
        if (Array.isArray(value) && value[0] === 0) {
          this.call = { ...this.call, phase: 'connected', connectedAt: new Date().toISOString() };
          this.emit();
        }
        break;
      }
      case AvOutput.relogin: {
        // 已在等下一次登录或已暂停：忽略重复的"要求重登"。
        if (!this.loginPosted || this.reloginPaused) break;
        this.loginPosted = false;
        const now = Date.now();
        this.relogins = this.relogins.filter((t) => now - t < RELOGIN_WINDOW_MS);
        this.relogins.push(now);
        if (this.relogins.length > RELOGIN_MAX) {
          this.reloginPaused = `AVSDK asked to re-login ${this.relogins.length} times within 10 minutes; call bridge paused`;
          this.ctx.logger.warn(`[qqbridge] ${this.reloginPaused}`);
          break;
        }
        this.scheduleLogin((this.opts.reloginBaseDelayMs ?? RELOGIN_BASE_DELAY_MS) * 2 ** (this.relogins.length - 1));
        break;
      }
      default:
        break;
    }
    this.stats.lastError = null;
  }

  private makeListener(): Record<string, (...args: unknown[]) => void> {
    const target: Record<string, (...args: unknown[]) => void> = {};
    for (const name of KNOWN_KERNEL_CALLBACKS) target[name] = (...args) => this.onKernelEvent(name, args);
    // 未知回调也照单全收并记录：研究新版本 QQ 的通话事件时有用。
    return new Proxy(target, {
      get: (object, property, receiver) => {
        if (Reflect.has(object, property)) return Reflect.get(object, property, receiver);
        if (typeof property !== 'string') return Reflect.get(object, property, receiver);
        const callback = (...args: unknown[]) => this.onKernelEvent(property, args);
        Reflect.set(object, property, callback);
        return callback;
      },
    });
  }

  private onKernelEvent(name: string, args: unknown[]): void {
    this.stats.kernelEvents += 1;
    this.capture.write('avsdk', { dir: 'kernel', name, args: this.capturedValue(args) });
    const lower = name.toLowerCase();
    if (lower === 'oninviteactiontoavsdk') {
      this.activeInvite = null;
      this.acceptPostedFor = null;
      const first = args[0] as { invite_type?: unknown; relation_id?: unknown } | undefined;
      const inviteType = typeof first?.invite_type === 'number' ? first.invite_type : null;
      this.call = {
        ...idleCall(),
        callId: randomUUID(),
        phase: 'ringing',
        inviteAt: new Date().toISOString(),
        inviteType,
        // 群语音：relation_id 是群号（2026-10-13 抓到：invite_type 3，relation_id 521409608）。
        groupCode: inviteType === GROUP_INVITE_TYPE && first?.relation_id ? String(first.relation_id) : null,
      };
      this.emit();
    } else if (lower === 'ons2cactiontoavsdk') {
      const destroyReason = (args[0] as { destroyReason?: unknown } | undefined)?.destroyReason;
      if (typeof destroyReason === 'number' && this.call.phase !== 'idle' && this.call.phase !== 'ended') {
        if (this.acceptTimer) clearTimeout(this.acceptTimer);
        this.acceptTimer = null;
        this.activeInvite = null;
        this.call = { ...this.call, phase: 'ended', endedAt: new Date().toISOString(), endReason: destroyReason };
        this.emit();
      }
    }
    this.forwardKernelAction(lower, args);
  }

  private forwardKernelAction(lowerName: string, args: unknown[]): void {
    let actionType: unknown = null;
    let payload: unknown = null;
    if (lowerName === 'oninviteactiontoavsdk') {
      actionType = args[1];
      payload = args[2];
    } else if (lowerName === 'onactiontoavsdk') {
      actionType = args[0];
      payload = args[1];
    }
    if (typeof actionType !== 'number' || typeof payload !== 'string') return;
    this.invokeAVHost(AvCommand.kernelData, [actionType, payload]).then(
      () => {
        this.stats.kernelForwarded += 1;
        const wantsAccept = this.call.acceptRequested || this.cfg.autoAccept;
        if (lowerName === 'onactiontoavsdk' && this.activeInvite && wantsAccept) this.scheduleAccept(75);
      },
      (error) => {
        this.stats.lastError = `kernel action forward failed: ${errorMessage(error)}`;
      },
    );
  }

  private scheduleAccept(delayMs: number): void {
    if (this.acceptTimer) clearTimeout(this.acceptTimer);
    this.acceptTimer = setTimeout(() => {
      this.acceptTimer = null;
      void this.sendAccept().catch((error) => {
        this.call = { ...this.call, phase: 'ringing' };
        this.stats.lastError = `native accept failed: ${errorMessage(error)}`;
        this.ctx.logger.warn(`[qqbridge] ${this.stats.lastError}`);
        this.emit();
      });
    }, delayMs);
    this.acceptTimer.unref?.();
  }

  private async sendAccept(): Promise<void> {
    const callId = this.call.callId;
    if (!this.activeInvite || !callId || this.call.phase === 'ended') return;
    if (this.acceptPostedFor === callId) return;
    this.acceptPostedFor = callId;
    this.call = { ...this.call, phase: 'accepting' };
    this.emit();
    await this.invokeAVHost(AvCommand.accept, buildAcceptParams(this.activeInvite));
  }

  private scheduleLogin(delayMs: number): void {
    if (this.loginTimer) clearTimeout(this.loginTimer);
    this.loginTimer = setTimeout(async () => {
      this.loginTimer = null;
      try {
        const { uid, uin } = selfInfo(this.ctx.core);
        const s = session(this.ctx.core);
        const accountPath = String(
          (typeof s.getAccountPath === 'function' ? s.getAccountPath(Number.parseInt(uin, 10)) : '') ||
            this.ctx.core?.dataPath ||
            '',
        );
        if (!accountPath) throw new Error('QQ account path is unavailable');
        await this.invokeAVHost(AvCommand.login, [uid, uin, uin, accountPath, '']);
        this.loginPosted = true;
        this.stats.lastError = null;
        this.ctx.logger.info('[qqbridge] AV Host login posted');
      } catch (error) {
        this.stats.lastError = `AV Host login failed: ${errorMessage(error)}`;
        this.scheduleLogin(Math.min(Math.max(delayMs, 250) * 2, 10_000));
      }
    }, delayMs);
    this.loginTimer.unref?.();
  }

  private async resolveCaller(uid: string, callId: string | null): Promise<void> {
    const [uin, name] = await Promise.all([uinByUid(this.ctx.core, uid), displayNameByUid(this.ctx.core, uid)]);
    if (this.call.callId !== callId) return;
    this.call = { ...this.call, callerUin: uin, callerName: name };
    this.emit();
  }

  private emit(): void {
    const snapshot = this.current();
    this.capture.write('calls', { call: snapshot });
    for (const listener of this.changeListeners) {
      try {
        listener(snapshot);
      } catch (error) {
        this.ctx.logger.warn('[qqbridge] call listener failed:', error);
      }
    }
  }

  private capturedValue(value: unknown): unknown {
    return this.cfg.captureAvsdkValues ? redactDeep(value) : summarizeValue(value);
  }

  private invokeAVHost(command: number, params: unknown[], retries = 2): Promise<void> {
    this.capture.write('avsdk', { dir: 'av-invoke', command, params: this.capturedValue(params) });
    return new Promise((resolve, reject) => {
      const encoded = Buffer.from(JSON.stringify({ command, params }));
      const request = http.request(
        {
          host: this.cfg.avHost,
          port: this.cfg.avPort,
          path: '/v1/invoke',
          method: 'POST',
          headers: {
            Authorization: `Bearer ${this.cfg.token}`,
            'Content-Type': 'application/json',
            'Content-Length': encoded.byteLength,
          },
          timeout: 3000,
        },
        (response) => {
          response.resume();
          response.on('end', () => {
            const status = response.statusCode ?? 0;
            if (status >= 200 && status < 300) resolve();
            else reject(new Error(`AV Host returned HTTP ${status}`));
          });
        },
      );
      request.on('timeout', () => request.destroy(new Error('AV Host timeout')));
      request.on('error', (error) => {
        if (retries > 0) {
          setTimeout(() => this.invokeAVHost(command, params, retries - 1).then(resolve, reject), 250);
        } else {
          reject(error);
        }
      });
      request.end(encoded);
    });
  }
}

function discoverMethods(value: unknown): string[] {
  const methods = new Set<string>();
  let cursor: unknown = value;
  for (let depth = 0; cursor && depth < 6; depth += 1) {
    for (const key of Reflect.ownKeys(cursor as object)) {
      if (typeof key !== 'string' || key === 'constructor') continue;
      try {
        if (typeof (value as Record<string, unknown>)[key] === 'function') methods.add(key);
      } catch {
        // 原生 getter 在枚举时可能抛错。
      }
    }
    cursor = Object.getPrototypeOf(cursor);
  }
  return [...methods].sort();
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
