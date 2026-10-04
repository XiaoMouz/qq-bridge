// 上游接入点（docs/design.md 4.3）：NapCat 插件主动连进来，事件先原样写进收件箱（upstream_events）再确认，
// 确认之后插件才会删除本地队列里的事件——所以任何时候断线、崩溃都不会丢事件。
// 同一条连接上，服务端可以调用插件（换媒体链接、按 seq 拉历史等）。
import { randomUUID, timingSafeEqual } from 'node:crypto';
import websocket from '@fastify/websocket';
import { sql } from 'drizzle-orm';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { Logger } from 'pino';
import type { WebSocket } from 'ws';
import { one, type Db } from '../db/client.ts';
import { pgJson } from '../db/nul.ts';
import type { IngestService } from '../ingest/service.ts';
import { SourceUnavailableError } from '../media/source.ts';
import { eventKind } from './napcat/map.ts';
import type { NapcatEvent } from './napcat/types.ts';
import { WIRE_VERSION, type HelloFrame, type PluginFrame, type QueuedEvent, type ServerFrame } from './wire.ts';

export const UPSTREAM_PATH = '/upstream/napcat';

/** 上游（插件）当前不在线：调用方应稍后重试，而不是把任务判为失败。 */
export class UpstreamOfflineError extends SourceUnavailableError {
  constructor(qqAccountId: number) {
    super(`upstream for qq account ${qqAccountId} is offline`);
  }
}

/** 插件明确返回了失败（例如 QQ 拒绝发送）：重试通常没有意义。 */
export class UpstreamCallError extends Error {}

/** 调用超时：插件可能仍在处理（发送类调用由插件按 client_random_id 去重，可以安全重试）。 */
export class UpstreamTimeoutError extends Error {}

export interface HubOptions {
  token: string;
  /** QQ 号归属的服务端账号（个人自用：通常就是唯一的所有者账号）。 */
  resolveAccount: () => Promise<number>;
  logger: Logger;
  pingIntervalMs?: number;
  helloTimeoutMs?: number;
  rpcTimeoutMs?: number;
}

export interface UpstreamConnectionInfo {
  qqAccountId: number;
  uin: number;
  queueId: string;
  connectedAt: Date;
  /** 插件版本（hello 里带来的）。 */
  pluginVersion?: string;
}

interface Connection extends UpstreamConnectionInfo {
  socket: WebSocket;
  pending: Map<string, { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>;
}

export class UpstreamHub {
  private readonly byAccount = new Map<number, Connection>();
  private readonly token: Buffer;
  /** 收件箱有新事件。 */
  onEvents: ((qqAccountId: number) => void) | null = null;
  /** 插件连上并完成握手（适合触发对账 / 预热）。 */
  onConnected: ((info: UpstreamConnectionInfo) => void) | null = null;

  constructor(
    private readonly db: Db,
    private readonly ingest: IngestService,
    private readonly opts: HubOptions,
  ) {
    this.token = Buffer.from(opts.token);
  }

  async register(app: FastifyInstance): Promise<void> {
    await app.register(websocket, { options: { maxPayload: 64 * 1024 * 1024 } });
    app.get(
      UPSTREAM_PATH,
      {
        websocket: true,
        preValidation: async (request, reply) => {
          if (!this.authorized(request)) await reply.code(401).send({ error: 'unauthorized' });
        },
      },
      (socket) => this.accept(socket),
    );
  }

  isConnected(qqAccountId: number): boolean {
    return this.byAccount.has(qqAccountId);
  }

  connections(): UpstreamConnectionInfo[] {
    return [...this.byAccount.values()].map(({ qqAccountId, uin, queueId, connectedAt, pluginVersion }) => ({
      qqAccountId,
      uin,
      queueId,
      connectedAt,
      ...(pluginVersion ? { pluginVersion } : {}),
    }));
  }

  /** 调用插件动作（见插件 upstream/handlers.ts）。 */
  async call<T = unknown>(qqAccountId: number, action: string, params: unknown, timeoutMs = this.opts.rpcTimeoutMs ?? 15_000): Promise<T> {
    const conn = this.byAccount.get(qqAccountId);
    if (!conn) throw new UpstreamOfflineError(qqAccountId);
    const id = randomUUID();
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        conn.pending.delete(id);
        reject(new UpstreamTimeoutError(`upstream call ${action} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      conn.pending.set(id, { resolve: resolve as (v: unknown) => void, reject, timer });
      this.send(conn.socket, { t: 'req', id, action, params });
    });
  }

  close(): void {
    for (const conn of this.byAccount.values()) conn.socket.close(1001, 'server shutting down');
  }

  private authorized(request: FastifyRequest): boolean {
    const header = request.headers.authorization ?? '';
    const given = Buffer.from(header.startsWith('Bearer ') ? header.slice(7).trim() : '');
    return given.length === this.token.length && timingSafeEqual(given, this.token);
  }

  private accept(socket: WebSocket): void {
    let conn: Connection | null = null;
    let alive = true;
    const helloTimer = setTimeout(() => socket.close(4000, 'hello timeout'), this.opts.helloTimeoutMs ?? 10_000);
    const ping = setInterval(() => {
      if (!alive) return socket.terminate();
      alive = false;
      socket.ping();
    }, this.opts.pingIntervalMs ?? 20_000);
    socket.on('pong', () => (alive = true));

    // 帧按到达顺序串行处理，保证 ack 单调递增。
    let chain: Promise<void> = Promise.resolve();
    socket.on('message', (data) => {
      alive = true;
      let frame: PluginFrame;
      try {
        frame = JSON.parse(data.toString()) as PluginFrame;
      } catch {
        socket.close(4400, 'malformed frame');
        return;
      }
      if (frame.t === 'res') {
        const pending = conn?.pending.get(frame.id);
        if (!pending) return;
        conn!.pending.delete(frame.id);
        clearTimeout(pending.timer);
        if (frame.ok) pending.resolve(frame.data);
        else pending.reject(new UpstreamCallError(frame.error));
        return;
      }
      chain = chain
        .then(async () => {
          if (frame.t === 'hello') {
            clearTimeout(helloTimer);
            conn = await this.hello(socket, frame);
          } else if (frame.t === 'events') {
            if (!conn) throw new Error('events before hello');
            await this.storeEvents(conn, frame.list);
          }
        })
        .catch((error: unknown) => {
          this.opts.logger.error({ err: error }, 'upstream frame failed');
          socket.close(4500, 'server error');
        });
    });

    socket.on('close', () => {
      clearTimeout(helloTimer);
      clearInterval(ping);
      if (!conn) return;
      for (const pending of conn.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(new UpstreamOfflineError(conn.qqAccountId));
      }
      if (this.byAccount.get(conn.qqAccountId) === conn) this.byAccount.delete(conn.qqAccountId);
      this.opts.logger.info({ uin: conn.uin }, 'upstream disconnected');
    });
  }

  private async hello(socket: WebSocket, hello: HelloFrame): Promise<Connection | null> {
    const uin = Number(hello.self?.uin);
    if (hello.v !== WIRE_VERSION || !Number.isSafeInteger(uin) || uin <= 0 || typeof hello.queue?.id !== 'string') {
      socket.close(4401, 'bad hello');
      return null;
    }
    const accountId = await this.opts.resolveAccount();
    const qqAccountId = await this.ingest.registerQqAccount(accountId, uin, hello.self.nick);
    if (hello.self.uid) await this.db.execute(sql`update qq_accounts set uid = ${hello.self.uid} where id = ${qqAccountId}`);
    const queue = await one<{ last_cursor: number; qq_account_id: number }>(
      this.db,
      sql`insert into upstream_queues (queue_id, qq_account_id) values (${hello.queue.id}, ${qqAccountId})
          on conflict (queue_id) do update set last_seen_at = now(), qq_account_id = excluded.qq_account_id
          returning last_cursor, qq_account_id`,
    );
    if (queue.last_cursor > hello.queue.last) {
      // 服务端收到过的比插件现有的还新（插件数据目录被还原等）：让插件换新队列 id，从头重发（重复的会被去重）。
      this.send(socket, { t: 'welcome', resume: queue.last_cursor, reset: true });
      return null;
    }

    const previous = this.byAccount.get(qqAccountId);
    if (previous && previous.socket !== socket) previous.socket.close(4409, 'replaced by a newer connection');
    const conn: Connection = {
      qqAccountId,
      uin,
      queueId: hello.queue.id,
      connectedAt: new Date(),
      ...(typeof hello.impl?.plugin === 'string' ? { pluginVersion: hello.impl.plugin } : {}),
      socket,
      pending: new Map(),
    };
    this.byAccount.set(qqAccountId, conn);
    this.send(socket, { t: 'welcome', resume: queue.last_cursor });
    this.opts.logger.info(
      { uin, queue: hello.queue, resume: queue.last_cursor, plugin: hello.impl?.plugin },
      'upstream connected',
    );
    this.onConnected?.({ qqAccountId, uin, queueId: conn.queueId, connectedAt: conn.connectedAt });
    // 积压的事件可能在上次处理到一半时服务端退出了：连上就先处理一遍。
    this.onEvents?.(qqAccountId);
    return conn;
  }

  /** 原样写进收件箱，提交后再确认（累计确认到这一批的最大游标）。 */
  private async storeEvents(conn: Connection, list: QueuedEvent[]): Promise<void> {
    const valid = list.filter((e) => Number.isSafeInteger(e?.c) && e.c > 0 && e.e && typeof e.e === 'object');
    if (valid.length === 0) return;
    const maxCursor = Math.max(...valid.map((e) => e.c));
    await this.db.transaction(async (tx) => {
      const rows = valid.map((e) => {
        const event = e.e as NapcatEvent;
        const enqueuedAt = Number.isFinite(e.at) ? new Date(e.at).toISOString() : null;
        return sql`(${conn.queueId}, ${e.c}, ${conn.qqAccountId}, ${eventKind(event)}, ${pgJson(event)}::jsonb, ${enqueuedAt}::timestamptz)`;
      });
      await tx.execute(
        sql`insert into upstream_events (queue_id, cursor, qq_account_id, kind, payload, enqueued_at)
            values ${sql.join(rows, sql`, `)}
            on conflict (queue_id, cursor) do nothing`,
      );
      await tx.execute(
        sql`update upstream_queues set last_cursor = greatest(last_cursor, ${maxCursor}), last_seen_at = now()
             where queue_id = ${conn.queueId}`,
      );
    });
    this.send(conn.socket, { t: 'ack', c: maxCursor });
    this.onEvents?.(conn.qqAccountId);
  }

  private send(socket: WebSocket, frame: ServerFrame): void {
    if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(frame));
  }
}
