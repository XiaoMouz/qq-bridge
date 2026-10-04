import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { CaptureWriter } from '../src/capture.js';
import { AvCommand, AvOutput, AvsdkBridge } from '../src/call/avsdk-bridge.js';
import type { BridgeConfig } from '../src/config.js';
import type { NapCatPluginContext } from '../src/napcat.js';

const TOKEN = 'x'.repeat(40);

interface Invocation {
  command: number;
  params: unknown[];
}

/** 假的 AV Host：记录插件发来的 AVSDK 指令。 */
async function startFakeAvHost(): Promise<{ port: number; invocations: Invocation[]; close(): Promise<void> }> {
  const invocations: Invocation[] = [];
  const server = http.createServer(async (req, res) => {
    if (req.headers.authorization !== `Bearer ${TOKEN}`) {
      res.writeHead(401).end();
      return;
    }
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    invocations.push(JSON.parse(Buffer.concat(chunks).toString('utf8')) as Invocation);
    res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"code":0}');
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', () => resolve()));
  const port = (server.address() as { port: number }).port;
  return { port, invocations, close: () => new Promise((resolve) => server.close(() => resolve())) };
}

function makeContext(service: Record<string, unknown>): NapCatPluginContext {
  const logger = { log() {}, info() {}, warn() {}, error() {} };
  return {
    core: {
      selfInfo: { uid: 'u_self', uin: '10001' },
      dataPath: '/tmp/qq',
      context: {
        session: {
          getAVSDKService: () => service,
          getAccountPath: (uin: number) => `/accounts/${uin}`,
        },
      },
      apis: {
        UserApi: {
          getUinByUidV2: async (uid: string) => (uid === 'u_caller' ? '20002' : '0'),
          getCoreAndBaseInfo: async (uids: string[]) => new Map(uids.map((uid) => [uid, { coreInfo: { nick: 'Caller' } }])),
        },
      },
    },
    actions: { call: async () => null },
    pluginName: 'napcat-plugin-qqbridge',
    pluginPath: '/plugins/qqbridge',
    configPath: '/config/qqbridge.json',
    dataPath: '/data/qqbridge',
    adapterName: 'plugin_manager',
    pluginManager: { config: {} },
    logger,
    router: { get() {} },
  };
}

describe('AvsdkBridge', () => {
  let avHost: Awaited<ReturnType<typeof startFakeAvHost>>;
  let listener: Record<string, (...args: unknown[]) => void>;
  let service: { addKernelAVSDKListener: ReturnType<typeof vi.fn>; setActionFromAVSDK: ReturnType<typeof vi.fn> };
  let bridge: AvsdkBridge;
  let capture: CaptureWriter;
  let tmpDir: string;
  const captureErrors: unknown[] = [];

  // 采样目录在整个文件结束后才删：桥里还有异步续写（例如来电者身份解析完成后的状态快照）。
  beforeAll(async () => {
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-test-'));
  });

  afterAll(async () => {
    await fs.rm(tmpDir, { recursive: true, force: true });
  });

  beforeEach(async () => {
    avHost = await startFakeAvHost();
    service = {
      addKernelAVSDKListener: vi.fn((l: Record<string, (...args: unknown[]) => void>) => {
        listener = l;
        return 7;
      }),
      setActionFromAVSDK: vi.fn(async () => undefined),
    };
    const cfg: BridgeConfig = {
      controlHost: '127.0.0.1',
      controlPort: 6110,
      avHost: '127.0.0.1',
      avPort: avHost.port,
      token: TOKEN,
      captureEnabled: true,
      autoAccept: false,
      captureAvsdkValues: false,
      probeMediaUrls: false,
      lab: false,
      calls: true,
      upstreamUrl: null,
      upstreamToken: null,
    };
    capture = new CaptureWriter(tmpDir, true, (error) => captureErrors.push(error));
    bridge = new AvsdkBridge(makeContext(service), cfg, capture, { reloginBaseDelayMs: 20 });
    bridge.start();
  });

  afterEach(async () => {
    bridge.stop();
    await capture.flush();
    await avHost.close();
    expect(captureErrors).toEqual([]);
  });

  it('records kernel events and AVSDK outputs to the capture stream', async () => {
    listener.onInviteActionToAVSDK!({ invite_type: 1 }, 3, 'kernel-payload');
    await bridge.handleOutput({ command: AvOutput.enterRoom, id: 1, value: [1] });
    await capture.flush();
    const day = new Date().toISOString().slice(0, 10);
    const lines = (await fs.readFile(path.join(tmpDir, 'capture', `avsdk-${day}.jsonl`), 'utf8')).trim().split('\n');
    const records = lines.map((line) => JSON.parse(line) as { dir: string; name?: string; command?: number });
    expect(records.some((r) => r.dir === 'kernel' && r.name === 'onInviteActionToAVSDK')).toBe(true);
    expect(records.some((r) => r.dir === 'av-output' && r.command === AvOutput.enterRoom)).toBe(true);
    // 默认只记录结构摘要：原始负载字符串不能出现在采样里。
    expect(lines.join('\n')).not.toContain('kernel-payload');
  });

  it('logs the AV Host in with the QQ identity and account path', async () => {
    await vi.waitFor(() => expect(avHost.invocations[0]).toBeDefined(), { timeout: 3000 });
    expect(avHost.invocations[0]).toEqual({
      command: AvCommand.login,
      params: ['u_self', '10001', '10001', '/accounts/10001', ''],
    });
  });

  it('rings without auto-accepting, accepts on request, and tracks the call to the end', async () => {
    const invite = [1, 'u_caller', 'u_self', 2, 'room', null, null, null, null, null, 0, 'extra'];

    listener.onInviteActionToAVSDK!({ invite_type: 1 }, 3, 'kernel-payload');
    expect(bridge.current().phase).toBe('ringing');
    await vi.waitFor(() =>
      expect(avHost.invocations).toContainEqual({ command: AvCommand.kernelData, params: [3, 'kernel-payload'] }),
    );

    await bridge.handleOutput({ command: AvOutput.inviteDetail, id: 1, value: invite });
    await vi.waitFor(() => expect(bridge.current()).toMatchObject({ callerUin: '20002', callerName: 'Caller' }));
    // 没有人接听时绝不能发出接听指令。
    await new Promise((resolve) => setTimeout(resolve, 700));
    expect(avHost.invocations.some((inv) => inv.command === AvCommand.accept)).toBe(false);

    await bridge.accept();
    await vi.waitFor(() =>
      expect(avHost.invocations).toContainEqual({
        command: AvCommand.accept,
        params: [1, 'u_caller', ['u_caller'], 2, 'room', false, 'extra'],
      }),
    );

    await bridge.handleOutput({ command: AvOutput.acceptResult, id: 2, value: [0] });
    expect(bridge.current().phase).toBe('accepted');
    await bridge.handleOutput({ command: AvOutput.enterRoom, id: 3, value: [0] });
    expect(bridge.current().phase).toBe('connected');

    listener.onS2CActionToAVSDK!({ destroyReason: 2 });
    expect(bridge.current()).toMatchObject({ phase: 'ended', endReason: 2 });
  });

  it('backs off when AVSDK keeps asking to re-login, and pauses instead of looping', async () => {
    const logins = () => avHost.invocations.filter((i) => i.command === AvCommand.login).length;
    await vi.waitFor(() => expect(logins()).toBe(1), { timeout: 3000 });
    for (let n = 2; n <= 4; n++) {
      // 同一轮里重复的"要求重登"只算一次。
      for (let k = 0; k < 5; k++) await bridge.handleOutput({ command: AvOutput.relogin, id: 1, value: [] });
      await vi.waitFor(() => expect(logins()).toBe(n), { timeout: 3000 });
    }
    await bridge.handleOutput({ command: AvOutput.relogin, id: 1, value: [] });
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(logins()).toBe(4); // 第 4 次要求重登：不再登录，暂停通话桥
    expect(bridge.status().reloginPaused).toMatch(/paused/);
  });

  it('treats 20050 as engine log lines, never as a re-login request', async () => {
    const logins = () => avHost.invocations.filter((i) => i.command === AvCommand.login).length;
    await vi.waitFor(() => expect(logins()).toBe(1), { timeout: 3000 });
    for (let k = 0; k < 50; k++) {
      await bridge.handleOutput({ command: AvOutput.engineLog, id: 0, value: [`avsdk output(wrapper): InitConponents. line ${k}`] });
    }
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(logins()).toBe(1);
    expect(bridge.status().reloginPaused).toBeNull();
  });

  it('hands AVSDK network output back to the kernel', async () => {
    await bridge.handleOutput({ command: AvOutput.network, id: 9, value: [4, 'net-payload'] });
    expect(service.setActionFromAVSDK).toHaveBeenCalledWith(4, 'net-payload');
  });

  it('refuses to accept when nothing is ringing', async () => {
    await expect(bridge.accept()).rejects.toThrow(/no ringing call/);
  });
});
