// 插件到服务端的上游连接（docs/design.md 4.3）：主动连服务端，断线自动重连并从服务端确认的位置续传。
// 事件先进本地持久队列（queue.ts），这里只负责"发出去、等确认、按确认清理"，以及响应服务端的调用。
import WebSocket from 'ws';
import type { PluginLogger } from '../napcat.js';
import type { UpstreamQueue } from './queue.js';
import { WIRE_VERSION, type HelloFrame, type PluginFrame, type ServerFrame } from './wire.js';

export type RpcHandler = (params: any) => Promise<unknown>;

export interface LinkOptions {
  url: string;
  token: string;
  queue: UpstreamQueue;
  /** 连接建立时调用，提供本 QQ 号与版本信息；QQ 还没登录好时抛错，稍后重试。 */
  hello: () => Promise<Pick<HelloFrame, 'self' | 'impl'>>;
  handlers: Record<string, RpcHandler>;
  logger: PluginLogger;
  /** 已发送未确认的事件数上限。 */
  maxInFlight?: number;
  batchSize?: number;
  minBackoffMs?: number;
  maxBackoffMs?: number;
  /** 这么久没收到服务端任何数据（包括心跳 ping）就认为连接已死，主动断开重连。 */
  idleTimeoutMs?: number;
  maxBufferedBytes?: number;
}

export interface LinkState {
  connected: boolean;
  welcomed: boolean;
  sentUpTo: number;
  ackedUpTo: number;
  backlog: number;
}

export class UpstreamLink {
  private ws: WebSocket | null = null;
  private stopped = true;
  private welcomed = false;
  private sentUpTo = 0;
  private ackedUpTo = 0;
  private pumping = false;
  private backoffMs: number;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private idleTimer: NodeJS.Timeout | null = null;
  private pumpTimer: NodeJS.Timeout | null = null;
  private readonly o: Required<Omit<LinkOptions, 'hello' | 'handlers' | 'logger' | 'queue' | 'url' | 'token'>> &
    Pick<LinkOptions, 'hello' | 'handlers' | 'logger' | 'queue' | 'url' | 'token'>;

  constructor(opts: LinkOptions) {
    this.o = {
      maxInFlight: 1000,
      batchSize: 200,
      minBackoffMs: 1000,
      maxBackoffMs: 30_000,
      idleTimeoutMs: 60_000,
      maxBufferedBytes: 8 * 1024 * 1024,
      ...opts,
    };
    this.backoffMs = this.o.minBackoffMs;
  }

  start(): void {
    if (!this.stopped) return;
    this.stopped = false;
    this.connect();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    for (const timer of [this.reconnectTimer, this.idleTimer, this.pumpTimer]) if (timer) clearTimeout(timer);
    this.reconnectTimer = this.idleTimer = this.pumpTimer = null;
    const ws = this.ws;
    if (!ws) return;
    await new Promise<void>((resolve) => {
      ws.once('close', () => resolve());
      ws.close(1000, 'plugin stopping');
      setTimeout(() => {
        ws.terminate();
        resolve();
      }, 2000).unref();
    });
  }

  /** 新事件入队后调用：已连上且追上进度时立刻发送。 */
  notify(): void {
    if (this.welcomed) this.pump();
  }

  get state(): LinkState {
    return {
      connected: this.ws?.readyState === WebSocket.OPEN,
      welcomed: this.welcomed,
      sentUpTo: this.sentUpTo,
      ackedUpTo: this.ackedUpTo,
      backlog: this.o.queue.last - this.ackedUpTo,
    };
  }

  private connect(): void {
    this.reconnectTimer = null;
    if (this.stopped) return;
    const ws = new WebSocket(this.o.url, {
      headers: { authorization: `Bearer ${this.o.token}` },
      handshakeTimeout: 10_000,
      maxPayload: 64 * 1024 * 1024,
    });
    this.ws = ws;
    ws.on('open', () => {
      this.touch();
      void this.sendHello(ws);
    });
    ws.on('message', (data) => {
      this.touch();
      let frame: ServerFrame;
      try {
        frame = JSON.parse(data.toString()) as ServerFrame;
      } catch {
        this.o.logger.warn('[qqbridge] upstream: ignoring malformed frame');
        return;
      }
      this.onFrame(ws, frame);
    });
    ws.on('ping', () => this.touch());
    ws.on('error', (error) => this.o.logger.warn('[qqbridge] upstream error:', error.message));
    ws.on('close', (code, reason) => this.onClose(ws, code, reason.toString()));
  }

  private async sendHello(ws: WebSocket): Promise<void> {
    try {
      const info = await this.o.hello();
      const q = this.o.queue;
      this.send(ws, { t: 'hello', v: WIRE_VERSION, queue: { id: q.id, first: q.first, last: q.last }, ...info });
    } catch (error) {
      this.o.logger.warn('[qqbridge] upstream: not ready to say hello:', error instanceof Error ? error.message : error);
      ws.close(4001, 'not ready');
    }
  }

  private onFrame(ws: WebSocket, frame: ServerFrame): void {
    const q = this.o.queue;
    switch (frame.t) {
      case 'welcome': {
        if (frame.reset) {
          this.o.logger.warn('[qqbridge] upstream: server is ahead of the local queue, starting a new queue id');
          q.reset();
          ws.close(4002, 'queue reset');
          return;
        }
        this.welcomed = true;
        this.backoffMs = this.o.minBackoffMs;
        this.ackedUpTo = frame.resume;
        q.ack(frame.resume);
        if (frame.resume < q.first - 1) {
          this.o.logger.warn(`[qqbridge] upstream: events ${frame.resume + 1}..${q.first - 1} were dropped locally before the server got them`);
        }
        this.sentUpTo = Math.max(frame.resume, q.first - 1);
        this.o.logger.info(`[qqbridge] upstream connected: resume=${frame.resume} last=${q.last}`);
        this.pump();
        return;
      }
      case 'ack':
        if (frame.c > this.ackedUpTo) {
          this.ackedUpTo = frame.c;
          q.ack(frame.c);
        }
        this.pump();
        return;
      case 'req':
        void this.handle(ws, frame);
        return;
    }
  }

  private pump(): void {
    const ws = this.ws;
    if (this.pumping || !ws || !this.welcomed) return;
    this.pumping = true;
    try {
      const q = this.o.queue;
      while (ws.readyState === WebSocket.OPEN && this.sentUpTo < q.last) {
        const window = this.o.maxInFlight - (this.sentUpTo - this.ackedUpTo);
        if (window <= 0) return; // 等 ack
        if (ws.bufferedAmount > this.o.maxBufferedBytes) {
          this.pumpTimer ??= setTimeout(() => {
            this.pumpTimer = null;
            this.pump();
          }, 20);
          return;
        }
        const list = q.read(this.sentUpTo, Math.min(this.o.batchSize, window));
        if (list.length === 0) return;
        this.send(ws, { t: 'events', list });
        this.sentUpTo = list[list.length - 1]!.c;
      }
    } finally {
      this.pumping = false;
    }
  }

  private async handle(ws: WebSocket, req: Extract<ServerFrame, { t: 'req' }>): Promise<void> {
    const handler = this.o.handlers[req.action];
    try {
      if (!handler) throw new Error(`unknown action: ${req.action}`);
      const data = await handler(req.params);
      this.send(ws, { t: 'res', id: req.id, ok: true, data: data ?? null });
    } catch (error) {
      this.send(ws, { t: 'res', id: req.id, ok: false, error: error instanceof Error ? error.message : String(error) });
    }
  }

  private send(ws: WebSocket, frame: PluginFrame): void {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(frame));
  }

  private touch(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    const ws = this.ws;
    this.idleTimer = setTimeout(() => {
      this.o.logger.warn('[qqbridge] upstream: no data from server, reconnecting');
      ws?.terminate();
    }, this.o.idleTimeoutMs);
    this.idleTimer.unref?.();
  }

  private onClose(ws: WebSocket, code: number, reason: string): void {
    if (this.ws !== ws) return;
    this.ws = null;
    this.welcomed = false;
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = null;
    if (this.stopped) return;
    const delay = Math.round(this.backoffMs * (0.8 + Math.random() * 0.4));
    this.backoffMs = Math.min(this.backoffMs * 2, this.o.maxBackoffMs);
    this.o.logger.warn(`[qqbridge] upstream closed (${code} ${reason}), reconnecting in ${delay}ms`);
    this.reconnectTimer = setTimeout(() => this.connect(), delay);
    this.reconnectTimer.unref?.();
  }
}
