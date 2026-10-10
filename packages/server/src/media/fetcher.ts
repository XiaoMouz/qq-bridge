// 媒体下载任务（docs/design.md 4.6）：QQ 的链接会过期，所以收到消息就下载。
//   认领待下载的引用（FOR UPDATE SKIP LOCKED）→ 按策略检查大小 → 取下载地址（必要时向上游换新链接）
//   → 边下载边哈希、按 sha256 去重落盘 → 图片生成缩略图 / 预览图 / thumbhash → 更新消息里的媒体状态。
// 失败按指数退避重试；链接彻底拿不到记为 expired，超过大小上限记为 skipped。
import { Readable } from 'node:stream';
import { resolveScoped, type PolicyRecord, type Scene } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, rows, toDate, type Db } from '../db/client.ts';
import { sqlList } from '../sync/rows.ts';
import { QQ_THUMB_ROLE, type IngestService } from '../ingest/service.ts';
import type { MediaService } from './service.ts';
import { qqThumbUrl, SourceUnavailableError, type FetchTarget, type MediaSource, type PendingRef } from './source.ts';
import { TooLargeError } from './store.ts';
import type { MediaProcessor } from './processing.ts';

export interface FetcherOptions {
  concurrency?: number;
  pollMs?: number;
  httpTimeoutMs?: number;
  maxAttempts?: number;
  backoffBaseMs?: number;
  backoffMaxMs?: number;
  /** 没有配置策略时的自动下载大小上限。 */
  defaultMaxBytes?: number;
  /** 上游不在线时多久后再试。 */
  offlineRetryMs?: number;
  /** 正在被查看的会话：它们的媒体优先下载（DialogService.SetActiveChat）。 */
  priorityChatIds?: () => readonly number[];
  logger?: Logger;
}

type DownloadResult =
  | { kind: 'stored'; sha256: string; size: number; mime: string | null }
  | { kind: 'gone'; status: number }
  | { kind: 'too_large' }
  | { kind: 'error'; error: string };

const GONE_STATUSES = new Set([403, 404, 410]);

/** 重新取回的结果：restored = 已从 QQ 拿回并放进热存储；unavailable = QQ 暂时不在线；expired = QQ 那边也拿不到了。 */
export type RehydrateResult = 'restored' | 'unavailable' | 'expired';

export class MediaFetcher {
  private running = false;
  private readonly rehydrating = new Map<string, Promise<RehydrateResult>>();
  private loop: Promise<void> | null = null;
  private wake: (() => void) | null = null;
  private readonly opts: Required<Omit<FetcherOptions, 'logger' | 'priorityChatIds'>> &
    Pick<FetcherOptions, 'logger' | 'priorityChatIds'>;

  constructor(
    private readonly db: Db,
    private readonly media: MediaService,
    private readonly ingest: IngestService,
    private readonly source: MediaSource,
    opts: FetcherOptions = {},
    private readonly processor: MediaProcessor | null = null,
  ) {
    this.opts = {
      concurrency: opts.concurrency ?? 3,
      pollMs: opts.pollMs ?? 2000,
      httpTimeoutMs: opts.httpTimeoutMs ?? 120_000,
      maxAttempts: opts.maxAttempts ?? 8,
      backoffBaseMs: opts.backoffBaseMs ?? 30_000,
      backoffMaxMs: opts.backoffMaxMs ?? 6 * 3600_000,
      defaultMaxBytes: opts.defaultMaxBytes ?? 200 * 1024 * 1024,
      offlineRetryMs: opts.offlineRetryMs ?? 60_000,
      ...(opts.priorityChatIds ? { priorityChatIds: opts.priorityChatIds } : {}),
      ...(opts.logger ? { logger: opts.logger } : {}),
    };
  }

  /** 进程上次退出时还在下载中的引用，重新放回队列（单进程部署）。 */
  async recover(): Promise<number> {
    const res = await this.db.execute(sql`update media_refs set fetch_state = 'pending' where fetch_state = 'fetching'`);
    return res.rowCount ?? 0;
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.loop = (async () => {
      let recovered = false;
      while (this.running) {
        const n = await (async () => {
          if (!recovered) {
            await this.recover();
            recovered = true;
          }
          return this.runOnce();
        })().catch((error) => {
          this.opts.logger?.error({ err: error }, 'media fetch round failed');
          return 0;
        });
        if (n === 0 && this.running) await this.sleep(this.opts.pollMs);
      }
    })();
  }

  /** 有新的待下载媒体时调用，立即开始下一轮（不必等轮询间隔）。 */
  poke(): void {
    this.wake?.();
  }

  async stop(): Promise<void> {
    this.running = false;
    this.poke();
    await this.loop;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(done, ms);
      const self = this;
      function done() {
        clearTimeout(timer);
        if (self.wake === done) self.wake = null;
        resolve();
      }
      this.wake = done;
    });
  }

  /** 认领并处理一批；返回处理了多少个（测试里直接调用）。 */
  async runOnce(limit = this.opts.concurrency): Promise<number> {
    const refs = await this.claim(limit);
    await Promise.all(refs.map((ref) => this.process(ref)));
    return refs.length;
  }

  /**
   * 认领一批：正在被查看的会话优先，其次新的优先（积压时先让最近的消息出图；
   * 旧消息的链接若因此过期，会走"换新链接"）。
   */
  private async claim(limit: number): Promise<PendingRef[]> {
    const priority = this.opts.priorityChatIds?.() ?? [];
    const list = await rows(
      this.db,
      sql`update media_refs set fetch_state = 'fetching', attempts = attempts + 1
           where id in (
             select id from media_refs
              where fetch_state = 'pending'
                 or (fetch_state = 'failed' and next_attempt_at is not null and next_attempt_at <= now())
              order by ${priority.length > 0 ? sql`(chat_id in ${sqlList(priority)}) desc,` : sql``} id desc
              limit ${limit}
              for update skip locked)
           returning ${sql.raw(REF_COLUMNS)}`,
    );
    return list.map(toPendingRef);
  }

  /**
   * 马上下载这一个（客户端在等，例如看大图要原图），不排队；正被后台下载时等它下完。
   * 返回时下载已结束（成功、拿不到，或超时）。
   */
  async fetchNow(refId: number, timeoutMs = 90_000): Promise<void> {
    const claimed = await rows(
      this.db,
      sql`update media_refs set fetch_state = 'fetching', attempts = attempts + 1
           where id = ${refId} and fetch_state = 'pending'
       returning ${sql.raw(REF_COLUMNS)}`,
    );
    if (claimed[0]) {
      await this.process(toPendingRef(claimed[0]));
      return;
    }
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const row = await maybeOne<{ fetch_state: string }>(this.db, sql`select fetch_state from media_refs where id = ${refId}`);
      if (!row || (row.fetch_state !== 'pending' && row.fetch_state !== 'fetching')) return;
      await new Promise((resolve) => setTimeout(resolve, 300));
    }
  }

  private async process(ref: PendingRef): Promise<void> {
    try {
      const maxBytes = await this.maxBytesFor(ref.chatId);
      if (ref.size !== null && ref.size > maxBytes) {
        await this.ingest.mediaUnavailable(ref.id, 'skipped', `size ${ref.size} exceeds limit ${maxBytes}`);
        return;
      }
      let target = await this.target(ref, false);
      if (!target) {
        await this.ingest.mediaUnavailable(ref.id, 'expired', 'no download url');
        return;
      }
      let result = await this.download(target.url, target.headers, ref, maxBytes);
      if (result.kind === 'gone') {
        // 链接失效（rkey 过期等）：向上游换一次新链接再试。
        target = await this.target(ref, true);
        result = target ? await this.download(target.url, target.headers, ref, maxBytes) : result;
      }
      switch (result.kind) {
        case 'stored':
          await this.complete(ref, result);
          return;
        case 'too_large':
          await this.ingest.mediaUnavailable(ref.id, 'skipped', `exceeds limit ${maxBytes}`);
          return;
        case 'gone':
          await this.ingest.mediaUnavailable(ref.id, 'expired', `HTTP ${result.status}`);
          return;
        case 'error':
          await this.retryLater(ref, result.error);
          return;
      }
    } catch (error) {
      if (error instanceof SourceUnavailableError) {
        await this.postpone(ref, error.message);
        return;
      }
      await this.retryLater(ref, error instanceof Error ? error.message : String(error));
    }
  }

  /**
   * 冷存储的盘不在时，从 QQ 重新取回一份内容（用它出现过的媒体引用里的定位信息换链接下载），按 sha256 校验后放进热存储。
   * 同一内容同时只取一次。不改媒体引用的状态：盘回来后原件照样在。
   */
  rehydrate(sha256: string): Promise<RehydrateResult> {
    const running = this.rehydrating.get(sha256);
    if (running) return running;
    const task = this.doRehydrate(sha256).finally(() => this.rehydrating.delete(sha256));
    this.rehydrating.set(sha256, task);
    return task;
  }

  private async doRehydrate(sha256: string): Promise<RehydrateResult> {
    const blob = await this.media.getBlob(sha256);
    if (!blob) return 'expired';
    const refs = await rows(
      this.db,
      sql`select id, chat_id, kind, role, url, url_expires_at, size, name, mime, qq_md5, qq_file_uuid, qq_resource_id, qq_file_id, locator, attempts
            from media_refs where sha256 = ${sha256} order by id desc limit 5`,
    );
    let offline = false;
    for (const r of refs) {
      const ref: PendingRef = {
        id: r.id as number,
        chatId: r.chat_id as number,
        kind: r.kind as string,
        role: r.role as string,
        url: (r.url as string | null) ?? null,
        urlExpiresAt: toDate(r.url_expires_at),
        size: (r.size as number | null) ?? null,
        name: (r.name as string | null) ?? null,
        mime: (r.mime as string | null) ?? null,
        qqMd5: (r.qq_md5 as string | null) ?? null,
        qqFileUuid: (r.qq_file_uuid as string | null) ?? null,
        qqResourceId: (r.qq_resource_id as string | null) ?? null,
        qqFileId: (r.qq_file_id as string | null) ?? null,
        locator: (r.locator as Record<string, unknown> | null) ?? null,
        attempts: 0,
      };
      try {
        // 入库时的链接多半早过期了：直接向上游换新链接。
        const target = await this.target(ref, true);
        if (!target) continue;
        const result = await this.download(target.url, target.headers, ref, blob.size + 1);
        if (result.kind === 'stored' && result.sha256 === sha256) {
          this.opts.logger?.info({ sha256 }, 'restored from QQ while cold storage is offline');
          return 'restored';
        }
      } catch (error) {
        if (error instanceof SourceUnavailableError) offline = true;
        else this.opts.logger?.debug({ err: error, sha256 }, 'rehydrate attempt failed');
      }
    }
    return offline ? 'unavailable' : 'expired';
  }

  /** 上游暂时不在线（例如 Mac 休眠）：推迟一段时间再试，不消耗重试次数，客户端看到的仍是"下载中"。 */
  private async postpone(ref: PendingRef, reason: string): Promise<void> {
    await this.db.execute(
      sql`update media_refs
             set fetch_state = 'failed', attempts = greatest(attempts - 1, 0), last_error = ${reason.slice(0, 500)},
                 next_attempt_at = now() + make_interval(secs => ${this.opts.offlineRetryMs / 1000})
           where id = ${ref.id}`,
    );
  }

  private async download(
    url: string,
    headers: Record<string, string> | undefined,
    ref: PendingRef,
    maxBytes: number,
  ): Promise<DownloadResult> {
    let response: Response;
    try {
      response = await fetch(url, { headers: headers ?? {}, signal: AbortSignal.timeout(this.opts.httpTimeoutMs) });
    } catch (error) {
      return { kind: 'error', error: error instanceof Error ? error.message : String(error) };
    }
    if (GONE_STATUSES.has(response.status)) {
      await response.body?.cancel();
      return { kind: 'gone', status: response.status };
    }
    if (!response.ok || !response.body) {
      await response.body?.cancel();
      return { kind: 'error', error: `HTTP ${response.status}` };
    }
    const declared = Number(response.headers.get('content-length') ?? NaN);
    if (Number.isFinite(declared) && declared > maxBytes) {
      await response.body.cancel();
      return { kind: 'too_large' };
    }
    const mime = (response.headers.get('content-type') ?? '').split(';')[0]?.trim() || ref.mime || null;
    try {
      const blob = await this.media.storeBlob(Readable.fromWeb(response.body as import('node:stream/web').ReadableStream<Uint8Array>), {
        kind: ref.kind,
        ...(mime ? { mime } : {}),
        maxBytes,
      });
      return { kind: 'stored', sha256: blob.sha256, size: blob.size, mime: blob.mime };
    } catch (error) {
      if (error instanceof TooLargeError) return { kind: 'too_large' };
      return { kind: 'error', error: error instanceof Error ? error.message : String(error) };
    }
  }

  /** 下载地址：QQ 缩略图引用把原图链接换成缩略图档。 */
  private async target(ref: PendingRef, forceRefresh: boolean): Promise<FetchTarget | null> {
    const t = await this.source.resolve(ref, forceRefresh);
    if (!t || ref.role !== QQ_THUMB_ROLE) return t;
    const url = qqThumbUrl(t.url);
    return url ? { ...t, url } : null;
  }

  /** 生成（或复用）派生版本，再把引用标记为已存储。QQ 缩略图直接用，不再处理。 */
  private async complete(ref: PendingRef, stored: { sha256: string; size: number; mime: string | null }): Promise<void> {
    if (ref.role === QQ_THUMB_ROLE) {
      await this.ingest.thumbStored(ref.id, stored);
      return;
    }
    const extra = this.processor ? await this.processor.process(stored.sha256, ref.kind) : {};
    await this.ingest.mediaStored(ref.id, stored, extra);
  }

  private async retryLater(ref: PendingRef, error: string): Promise<void> {
    if (ref.attempts >= this.opts.maxAttempts) {
      await this.ingest.mediaUnavailable(ref.id, 'failed', `gave up after ${ref.attempts} attempts: ${error}`);
      return;
    }
    const exp = Math.min(this.opts.backoffBaseMs * 2 ** (ref.attempts - 1), this.opts.backoffMaxMs);
    const delayMs = Math.round(exp * (0.8 + Math.random() * 0.4));
    await this.db.execute(
      sql`update media_refs
             set fetch_state = 'failed', last_error = ${error.slice(0, 500)},
                 next_attempt_at = now() + make_interval(secs => ${delayMs / 1000})
           where id = ${ref.id}`,
    );
  }

  /** 自动下载大小上限：会话 > 会话类型 > 全局 > 默认。 */
  private async maxBytesFor(chatId: number): Promise<number> {
    const chat = await maybeOne<{ scene: Scene; account_id: number }>(
      this.db,
      sql`select c.scene, q.account_id from chats c join qq_accounts q on q.id = c.qq_account_id where c.id = ${chatId}`,
    );
    if (!chat) return this.opts.defaultMaxBytes;
    const policies = await rows<{ scope: PolicyRecord['scope']; scene: Scene | null; chat_id: number | null; auto_fetch_max_bytes: number | null }>(
      this.db,
      sql`select scope, scene, chat_id, auto_fetch_max_bytes from storage_policies
           where account_id = ${chat.account_id} and auto_fetch_max_bytes is not null`,
    );
    const limit = resolveScoped(
      policies.map((p) => ({ scope: p.scope, scene: p.scene, chatId: p.chat_id, value: p.auto_fetch_max_bytes! })),
      { chatId, scene: chat.scene },
    );
    return limit ?? this.opts.defaultMaxBytes;
  }
}

const REF_COLUMNS =
  'id, chat_id, kind, role, url, url_expires_at, size, name, mime, qq_md5, qq_file_uuid, qq_resource_id, qq_file_id, locator, attempts';

function toPendingRef(r: Record<string, unknown>): PendingRef {
  return {
    id: r.id as number,
    chatId: r.chat_id as number,
    kind: r.kind as string,
    role: r.role as string,
    url: (r.url as string | null) ?? null,
    urlExpiresAt: toDate(r.url_expires_at),
    size: (r.size as number | null) ?? null,
    name: (r.name as string | null) ?? null,
    mime: (r.mime as string | null) ?? null,
    qqMd5: (r.qq_md5 as string | null) ?? null,
    qqFileUuid: (r.qq_file_uuid as string | null) ?? null,
    qqResourceId: (r.qq_resource_id as string | null) ?? null,
    qqFileId: (r.qq_file_id as string | null) ?? null,
    locator: (r.locator as Record<string, unknown> | null) ?? null,
    attempts: r.attempts as number,
  };
}
