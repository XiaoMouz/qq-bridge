// 收件箱处理（docs/design.md 4.3 / 4.5）：按到达顺序把上游原始事件映射成领域动作并入库。
// - 每条事件单独入库（单写者里一个小事务），实时消息不会被大批积压挡住太久；
// - 映射失败记为 failed、暂不支持的事件记为 ignored，原文都保留，修好映射后可以 reprocess 重新处理；
// - 记录每条实时消息的传输与入库耗时。
import type { PluginCallState } from '../calls/service.ts';
import type { PeerProfile } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, rows, toDate, type Db } from '../db/client.ts';
import type { IngestService } from '../ingest/service.ts';
import { LatencyStats } from './metrics.ts';
import { mapNapcatEvent, type UpstreamAction } from './napcat/map.ts';
import type { NapcatEvent } from './napcat/types.ts';

export interface InboxOptions {
  batchSize?: number;
  logger?: Logger;
  /** 新消息带了待下载的媒体：通知下载任务立即开始，不用等轮询。 */
  onMediaQueued?: () => void;
  /** 通话桥状态变化（CallService.onPluginState）；没配置通话时为空，事件记为 ignored。 */
  onCall?: (qqAccountId: number, state: PluginCallState) => Promise<boolean>;
  /** 群员资料可能变了（ContactService.refreshMember）。 */
  onMemberChanged?: (qqAccountId: number, groupId: number, userId: number) => void;
}

export type Outcome = { state: 'done' } | { state: 'ignored'; reason: string } | { state: 'failed'; error: string };

export class InboxProcessor {
  readonly latency = new LatencyStats();
  private readonly running = new Map<number, Promise<void>>();
  private readonly rerun = new Set<number>();
  /** 最近一次写入的资料，避免每条消息都做一次无变化的资料更新。 */
  private readonly peerCache = new Map<string, string>();
  private readonly selfUins = new Map<number, number>();

  constructor(
    private readonly db: Db,
    private readonly ingest: IngestService,
    private readonly opts: InboxOptions = {},
  ) {}

  /** 有新事件：若该 QQ 号的处理循环已在跑，跑完后再来一轮；否则立即开始。 */
  poke(qqAccountId: number): void {
    if (this.running.has(qqAccountId)) {
      this.rerun.add(qqAccountId);
      return;
    }
    const run = (async () => {
      try {
        do {
          this.rerun.delete(qqAccountId);
          while ((await this.processBatch(qqAccountId)) > 0) {
            // 继续处理下一批
          }
        } while (this.rerun.has(qqAccountId));
      } catch (error) {
        this.opts.logger?.error({ err: error, qqAccountId }, 'inbox processing failed');
      } finally {
        this.running.delete(qqAccountId);
      }
    })();
    this.running.set(qqAccountId, run);
  }

  /** 等当前的处理循环结束（测试与关停用）。 */
  async idle(): Promise<void> {
    while (this.running.size > 0) await Promise.all([...this.running.values()]);
  }

  /** 把 failed / ignored 的事件重新放回待处理（映射修好或新支持了某类事件之后）。 */
  async reprocess(state: 'failed' | 'ignored', qqAccountId?: number): Promise<number> {
    const res = await this.db.execute(
      sql`update upstream_events set state = 'pending', error = null, processed_at = null
           where state = ${state} ${qqAccountId === undefined ? sql`` : sql`and qq_account_id = ${qqAccountId}`}`,
    );
    const accounts = await rows<{ qq_account_id: number }>(
      this.db,
      sql`select distinct qq_account_id from upstream_events where state = 'pending'`,
    );
    for (const a of accounts) this.poke(a.qq_account_id);
    return res.rowCount ?? 0;
  }

  /** 清理早已入库的原始事件（消息本身的 raw 已经存在 messages 表里）。 */
  async prune(retentionDays: number): Promise<number> {
    const res = await this.db.execute(
      sql`delete from upstream_events
           where state in ('done', 'ignored') and processed_at < now() - make_interval(days => ${retentionDays})`,
    );
    return res.rowCount ?? 0;
  }

  private async processBatch(qqAccountId: number): Promise<number> {
    const events = await rows<{ id: number; payload: NapcatEvent; enqueued_at: unknown; received_at: unknown }>(
      this.db,
      sql`select id, payload, enqueued_at, received_at from upstream_events
           where qq_account_id = ${qqAccountId} and state = 'pending'
           order by id limit ${this.opts.batchSize ?? 100}`,
    );
    if (events.length === 0) return 0;
    const selfUin = await this.selfUin(qqAccountId);
    for (const event of events) {
      const outcome = await this.apply(qqAccountId, selfUin, event.payload, event.id);
      await this.db.execute(
        sql`update upstream_events
               set state = ${outcome.state},
                   error = ${outcome.state === 'done' ? null : outcome.state === 'ignored' ? outcome.reason : outcome.error},
                   processed_at = now()
             where id = ${event.id}`,
      );
      if (outcome.state === 'failed') this.opts.logger?.warn({ eventId: event.id, error: outcome.error }, 'upstream event failed');
      const receivedAt = toDate(event.received_at)?.getTime();
      const enqueuedAt = toDate(event.enqueued_at)?.getTime();
      if (outcome.state === 'done' && receivedAt && enqueuedAt && isMessage(event.payload)) {
        this.latency.record({ transportMs: Math.max(0, receivedAt - enqueuedAt), ingestMs: Math.max(0, Date.now() - receivedAt) });
      }
    }
    return events.length;
  }

  private async apply(qqAccountId: number, selfUin: number, payload: NapcatEvent, eventId: number): Promise<Outcome> {
    if (payload.self_id !== undefined && Number(payload.self_id) !== selfUin) {
      return { state: 'ignored', reason: `event belongs to QQ ${payload.self_id}, not ${selfUin}` };
    }
    let action: UpstreamAction;
    try {
      action = mapNapcatEvent(await this.withTargetSeq(qqAccountId, payload), selfUin);
    } catch (error) {
      return { state: 'failed', error: `map: ${errorText(error)}` };
    }
    return this.applyAction(qqAccountId, action, eventId);
  }

  /**
   * 撤回、设精华、表情回应里的 message_id 只是 NapCat 的短 id。插件没附上真实 seq 时，
   * 在收件箱里找带这个短 id 的消息事件，取它原始消息里的 seq（只对连上之后收到过的消息有效）。
   */
  private async withTargetSeq(qqAccountId: number, payload: NapcatEvent): Promise<NapcatEvent> {
    const needs = payload.post_type === 'notice' && TARGETED_NOTICES.has(String(payload.notice_type));
    if (!needs || payload.qqbridge?.message?.msgSeq || payload.qqbridge?.recalled?.msgSeq || payload.message_id === undefined) {
      return payload;
    }
    const found = await maybeOne<{ seq: string | null }>(
      this.db,
      sql`select payload->'raw'->>'msgSeq' as seq from upstream_events
           where qq_account_id = ${qqAccountId} and payload->>'message_id' = ${String(payload.message_id)} and payload ? 'raw'
           order by id desc limit 1`,
    );
    return found?.seq ? { ...payload, qqbridge: { ...payload.qqbridge, message: { msgSeq: found.seq } } } : payload;
  }

  /** 执行一个映射好的动作（收件箱与对账回填共用）。sourceEventId：收件箱事件 id，用于服务事件去重。 */
  async applyAction(qqAccountId: number, action: UpstreamAction, sourceEventId?: number): Promise<Outcome> {
    try {
      switch (action.type) {
        case 'ignore':
          return { state: 'ignored', reason: action.reason };
        case 'message': {
          await this.ingest.ingestMessage(qqAccountId, action.message);
          await this.upsertPeers(qqAccountId, action.peers);
          if (action.message.media.length > 0) this.opts.onMediaQueued?.();
          return { state: 'done' };
        }
        case 'recall': {
          const changed = await this.ingest.recall(qqAccountId, action.scene, action.peerId, action.seq, action.operatorId, action.time);
          return changed ? { state: 'done' } : { state: 'ignored', reason: 'recalled message is not archived' };
        }
        case 'chatEvent':
          await this.ingest.addChatEvent(qqAccountId, action.event, sourceEventId);
          return { state: 'done' };
        case 'reaction': {
          const changed = await this.ingest.applyReaction(qqAccountId, action.scene, action.peerId, action.seq, action.change);
          return changed ? { state: 'done' } : { state: 'ignored', reason: 'reacted message is not archived' };
        }
        case 'call': {
          if (!this.opts.onCall) return { state: 'ignored', reason: 'calls are not configured on the server' };
          const handled = await this.opts.onCall(qqAccountId, action.state);
          return handled ? { state: 'done' } : { state: 'ignored', reason: 'idle or incomplete call state' };
        }
        case 'memberChanged':
          if (!this.opts.onMemberChanged) return { state: 'ignored', reason: 'member refresh is not configured' };
          this.opts.onMemberChanged(qqAccountId, action.groupId, action.userId);
          return { state: 'done' };
        case 'typing': {
          const pushed = await this.ingest.typing(qqAccountId, action.scene, action.peerId, action.userId, action.text);
          return pushed ? { state: 'done' } : { state: 'ignored', reason: 'typing in a chat that is not archived' };
        }
      }
    } catch (error) {
      return { state: 'failed', error: errorText(error) };
    }
  }

  private async upsertPeers(qqAccountId: number, peers: PeerProfile[]): Promise<void> {
    for (const peer of peers) {
      const key = `${qqAccountId}:${peer.kind}:${peer.peerId}`;
      const value = JSON.stringify(peer);
      if (this.peerCache.get(key) === value) continue;
      await this.ingest.upsertPeer(qqAccountId, peer);
      this.peerCache.set(key, value);
      if (this.peerCache.size > 20_000) this.peerCache.delete(this.peerCache.keys().next().value!);
    }
  }

  private async selfUin(qqAccountId: number): Promise<number> {
    const cached = this.selfUins.get(qqAccountId);
    if (cached) return cached;
    const row = await maybeOne<{ uin: number }>(this.db, sql`select uin from qq_accounts where id = ${qqAccountId}`);
    if (!row) throw new Error(`qq account ${qqAccountId} not found`);
    this.selfUins.set(qqAccountId, row.uin);
    return row.uin;
  }
}

const TARGETED_NOTICES = new Set(['group_recall', 'friend_recall', 'essence', 'group_msg_emoji_like']);

function isMessage(event: NapcatEvent): boolean {
  return event.post_type === 'message' || event.post_type === 'message_sent';
}

/** 数据库错误被 Drizzle 包成 "Failed query: <整段 SQL>"，真正的原因在 cause 里，放在最前面。 */
function errorText(error: unknown): string {
  if (!(error instanceof Error)) return String(error).slice(0, 500);
  const cause = error.cause instanceof Error ? error.cause.message : '';
  const message = cause ? `${cause} | ${error.message.split('\n')[0]}` : error.message;
  return message.slice(0, 500);
}
