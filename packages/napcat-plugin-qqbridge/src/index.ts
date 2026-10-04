// QQ Bridge NapCat 插件入口，包含三部分：
// - 消息上游：事件进本地持久队列，经 WebSocket 推给服务端，按游标确认、断线续传（docs/design.md 4.3）；
// - P0 采样器（probe）：把事件写成 JSONL 供分析；
// - 通话信令桥（AVSDK）。
import path from 'node:path';
import { CaptureWriter } from './capture.js';
import { AvsdkBridge } from './call/avsdk-bridge.js';
import { loadConfig } from './config.js';
import { ControlServer } from './control-server.js';
import { selfInfo } from './core.js';
import type { NapCatPluginContext, OB11Event } from './napcat.js';
import { Probe } from './probe.js';
import { EventForwarder } from './upstream/forwarder.js';
import { createHandlers } from './upstream/handlers.js';
import { UpstreamLink, type RpcHandler } from './upstream/link.js';
import { UpstreamQueue } from './upstream/queue.js';
import { Sender } from './upstream/sender.js';

declare const __QQBRIDGE_PLUGIN_VERSION__: string | undefined;
const PLUGIN_VERSION = typeof __QQBRIDGE_PLUGIN_VERSION__ === 'string' ? __QQBRIDGE_PLUGIN_VERSION__ : 'dev';

interface Upstream {
  queue: UpstreamQueue;
  link: UpstreamLink;
  forwarder: EventForwarder;
}

interface Runtime {
  capture: CaptureWriter;
  server: ControlServer;
  probe: Probe;
  calls: AvsdkBridge | null;
  upstream: Upstream | null;
}

let runtime: Runtime | null = null;

export async function plugin_init(ctx: NapCatPluginContext): Promise<void> {
  const logger = ctx.logger;
  try {
    const cfg = loadConfig();
    const capture = new CaptureWriter(ctx.dataPath, cfg.captureEnabled, (error) =>
      logger.warn('[qqbridge] capture write failed:', error),
    );
    const server = new ControlServer(cfg.controlHost, cfg.controlPort, cfg.token, logger);
    const probe = new Probe(ctx, capture, cfg.probeMediaUrls);
    probe.registerRoutes(server);

    let calls: AvsdkBridge | null = cfg.calls ? new AvsdkBridge(ctx, cfg, capture) : null;
    try {
      calls?.start();
      calls?.registerRoutes(server, cfg.lab);
    } catch (error) {
      // 没有 AVSDK（例如非 Linux 或精简版 QQ）时消息功能照常工作。
      logger.warn('[qqbridge] call bridge disabled:', error);
      calls = null;
    }

    await server.start();
    const upstream = startUpstream(ctx, cfg.upstreamUrl, cfg.upstreamToken, calls);
    // 通话状态的每次变化都作为事件进上游队列，服务端据此推送来电、记录通话。
    if (calls && upstream) {
      calls.onChange((call) => upstream.forwarder.onEvent({ post_type: 'qqbridge_call', time: Math.floor(Date.now() / 1000), call }));
    }
    runtime = { capture, server, probe, calls, upstream };
    logger.info(
      `[qqbridge] ready: control=${cfg.controlHost}:${cfg.controlPort} capture=${cfg.captureEnabled} ` +
        `calls=${calls ? 'on' : 'off'} autoAccept=${cfg.autoAccept} lab=${cfg.lab} upstream=${upstream ? cfg.upstreamUrl : 'off'}`,
    );
  } catch (error) {
    logger.error('[qqbridge] startup failed:', error);
  }
}

export async function plugin_onevent(_ctx: NapCatPluginContext, event: OB11Event): Promise<void> {
  runtime?.upstream?.forwarder.onEvent(event);
  runtime?.probe.onEvent(event);
}

function startUpstream(ctx: NapCatPluginContext, url: string | null, token: string | null, calls: AvsdkBridge | null): Upstream | null {
  if (!url) return null;
  if (!token) {
    ctx.logger.warn('[qqbridge] QQBRIDGE_UPSTREAM_URL is set but the upstream token is missing or shorter than 32 bytes; upstream disabled');
    return null;
  }
  const queue = UpstreamQueue.open(path.join(ctx.dataPath, 'upstream'), {
    onDrop: ({ from, to, bytes }) =>
      ctx.logger.warn(`[qqbridge] upstream queue full: dropped events ${from}..${to} (${bytes} bytes) that the server never received`),
  });
  // 转发器要用连接（入队后唤醒发送），发送器要用转发器（短 id → seq），连接又要用发送器的处理函数：
  // 先给连接一个空的 handlers 对象，建好发送器后再填进去。
  const handlers: Record<string, RpcHandler> = {};
  const link = new UpstreamLink({
    url,
    token,
    queue,
    hello: async () => {
      const self = selfInfo(ctx.core);
      const nick = ctx.core?.selfInfo?.nick;
      return {
        self: { ...self, ...(typeof nick === 'string' && nick ? { nick } : {}) },
        impl: { plugin: PLUGIN_VERSION },
      };
    },
    handlers,
    logger: ctx.logger,
  });
  const forwarder = new EventForwarder(ctx, queue, link, ctx.logger);
  const sender = new Sender(ctx, forwarder, path.join(ctx.dataPath, 'upstream'), ctx.logger);
  Object.assign(handlers, createHandlers(ctx, { sender, calls }));
  link.start();
  return { queue, link, forwarder };
}

export async function plugin_cleanup(): Promise<void> {
  const current = runtime;
  runtime = null;
  if (!current) return;
  current.calls?.stop();
  if (current.upstream) {
    await current.upstream.link.stop();
    current.upstream.queue.close();
  }
  current.probe.close();
  await current.server.close();
  await current.capture.flush();
}
