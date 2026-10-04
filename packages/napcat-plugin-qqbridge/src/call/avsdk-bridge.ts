// 通话信令桥：在 QQ 内核（NodeIKernelAVSDKService）与 AV Host（加载 libAVSDKPlugin.so 的第二个 QQ/Electron 进程）之间转发数据。
// 思路与已知指令号来自 ClaudiaGardner/maibot-qq-voice-call（GPL-3.0）的 QQ AV Bridge；
// 与它不同的是：来电默认不自动接听，而是等 iPhone 端（经服务端）调用 accept()。
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import type { CaptureWriter } from '../capture.js';
import type { BridgeConfig } from '../config.js';
import { HttpError, type ControlServer } from '../control-server.js';
import { displayNameByUid, selfInfo, session, uinByUid } from '../core.js';
import type { NapCatPluginContext } from '../napcat.js';
import { redactDeep, summarizeValue } from '../redact.js';
import { buildAcceptParams } from './accept-params.js';

/** 发给 AVSDK 插件的指令（embed.postMessage 的 cmd）。 */
export const AvCommand = { login: 1, accept: 5, kernelData: 55 } as const;

/** AVSDK 插件输出（AV Host 转发过来的 message 事件的 cmd）。 */
export const AvOutput = {
  network: 20001,
  inviteDetail: 20006,
  acceptResult: 5,
  enterRoom: 20004,
  /**
   * 通话引擎自己的运行日志（一行文本，以 "avsdk output(wrapper):" 开头）。
   * maibot 把它当成"要求重新登录"，2026-10-04 抓负载确认不是：登录结果（输出 1）每次都是成功。
   */
  engineLog: 20050,
  relogin: 120043,
} as const;

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

  registerRoutes(server: ControlServer, lab: boolean): void {
    server.route('GET', '/v1/status', () => this.status());
    server.route('GET', '/v1/calls/current', () => this.current());
    server.route('POST', '/v1/calls/accept', () => this.accept());
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
        this.call = { ...this.call, callerUid, callerUin: null, callerName: null };
        if (callerUid) void this.resolveCaller(callerUid, this.call.callId);
        if (this.call.acceptRequested) this.scheduleAccept(50);
        else if (this.cfg.autoAccept) this.scheduleAccept(500);
        this.emit();
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
      const first = args[0] as { invite_type?: unknown } | undefined;
      this.call = {
        ...idleCall(),
        callId: randomUUID(),
        phase: 'ringing',
        inviteAt: new Date().toISOString(),
        inviteType: typeof first?.invite_type === 'number' ? first.invite_type : null,
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
