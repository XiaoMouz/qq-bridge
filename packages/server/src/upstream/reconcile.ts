// 重连对账与主动预热（docs/design.md 4.5 第 3 条）：上游连上后，拿 QQ 的最近会话列表与服务端比较——
// - 服务端没见过的会话：预热最新约 warmMessages 条，用户点开之前服务端就已经有记录；
// - 服务端落后的会话：补齐断线期间漏掉的消息（每个会话最多 maxGapFill 条，更早的交给深度归档 / 懒回填）。
// 请求按 UPSTREAM_BACKFILL_INTERVAL_MS（加随机抖动）限速，防风控；每条消息单独入库，实时消息可以随时插队。
// 拉取与"已核对区间"的记录由 HoleFiller.fetchOlder 负责（见 history.ts）。
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, one, type Db } from '../db/client.ts';
import type { UpstreamHub } from './hub.ts';
import type { HoleFiller } from './history.ts';
import type { InboxProcessor } from './inbox.ts';
import { int, mapRawMessage } from './napcat/map.ts';
import { NtChatType, type NtRawMessage } from './napcat/types.ts';

export interface ReconcileOptions {
  recentCount?: number;
  warmMessages?: number;
  maxGapFill?: number;
  /** 连上后等一会儿再开始，先让插件积压的实时事件处理完。 */
  startDelayMs?: number;
  /** 一轮对账结束（成功或失败）后调用：接着补缺口。 */
  onFinished?: (qqAccountId: number) => void;
  logger?: Logger;
  sleep?: (ms: number) => Promise<void>;
}

export interface ReconcileReport {
  contacts: number;
  warmedChats: number;
  gapFilledChats: number;
  messages: number;
  errors: number;
}

interface RecentContact {
  chatType: number;
  peerUid: string;
  peerUin: string;
  latest: NtRawMessage | null;
}

export class Reconciler {
  private readonly running = new Map<number, Promise<ReconcileReport>>();
  private readonly o: Required<Omit<ReconcileOptions, 'logger' | 'onFinished'>> & Pick<ReconcileOptions, 'logger' | 'onFinished'>;

  constructor(
    private readonly db: Db,
    private readonly hub: Pick<UpstreamHub, 'call'>,
    private readonly inbox: Pick<InboxProcessor, 'applyAction'>,
    private readonly history: Pick<HoleFiller, 'chat' | 'fetchOlder'>,
    opts: ReconcileOptions = {},
  ) {
    this.o = {
      recentCount: 100,
      warmMessages: 200,
      maxGapFill: 1000,
      startDelayMs: 3000,
      sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
      ...opts,
    };
  }

  /** 安排一次对账（同一个 QQ 号同时只跑一个）。 */
  schedule(qqAccountId: number): void {
    if (this.running.has(qqAccountId)) return;
    const run = (async () => {
      await this.o.sleep(this.o.startDelayMs);
      return this.run(qqAccountId);
    })()
      .then((report) => {
        this.o.logger?.info({ qqAccountId, ...report }, 'upstream reconcile finished');
        return report;
      })
      .catch((error: unknown) => {
        this.o.logger?.warn({ err: error, qqAccountId }, 'upstream reconcile failed');
        return { contacts: 0, warmedChats: 0, gapFilledChats: 0, messages: 0, errors: 1 };
      })
      .finally(() => {
        this.running.delete(qqAccountId);
        this.o.onFinished?.(qqAccountId);
      });
    this.running.set(qqAccountId, run);
  }

  async idle(): Promise<void> {
    await Promise.all([...this.running.values()]);
  }

  async run(qqAccountId: number): Promise<ReconcileReport> {
    const { uin: selfUin } = await one<{ uin: number }>(this.db, sql`select uin from qq_accounts where id = ${qqAccountId}`);
    const contacts = await this.hub.call<RecentContact[]>(qqAccountId, 'x.recent_contacts', { count: this.o.recentCount });
    const report: ReconcileReport = { contacts: contacts.length, warmedChats: 0, gapFilledChats: 0, messages: 0, errors: 0 };
    for (const contact of contacts) {
      try {
        const result = await this.reconcileChat(qqAccountId, selfUin, contact);
        if (!result) continue;
        report.messages += result.messages;
        if (result.kind === 'warmed') report.warmedChats += 1;
        else report.gapFilledChats += 1;
      } catch (error) {
        report.errors += 1;
        this.o.logger?.warn({ err: error, peer: contact.peerUin }, 'reconcile chat failed');
      }
    }
    return report;
  }

  private async reconcileChat(
    qqAccountId: number,
    selfUin: number,
    contact: RecentContact,
  ): Promise<{ kind: 'warmed' | 'filled'; messages: number } | null> {
    const scene = contact.chatType === NtChatType.group ? 'group' : contact.chatType === NtChatType.friend ? 'friend' : null;
    const peerId = int(contact.peerUin);
    const latestSeq = int(contact.latest?.msgSeq);
    if (!scene || !peerId || !latestSeq || !contact.latest) return null;

    const chat = await maybeOne<{ top_seq: number | null }>(
      this.db,
      sql`select top_seq from chats where qq_account_id = ${qqAccountId} and scene = ${scene} and peer_id = ${peerId}`,
    );
    const known = chat?.top_seq ?? null;
    if (known !== null && known >= latestSeq) return null;
    const kind = known === null ? 'warmed' : 'filled';
    const stopAt = known ?? 0;
    const budget = known === null ? this.o.warmMessages : Math.min(latestSeq - known, this.o.maxGapFill);

    // 最新一条在会话快照里已经有了，先入库（新会话以它为已读位置，旧消息不算未读）。
    await this.ingest(qqAccountId, selfUin, contact.latest);
    const stored = await maybeOne<{ id: number }>(
      this.db,
      sql`select id from chats where qq_account_id = ${qqAccountId} and scene = ${scene} and peer_id = ${peerId}`,
    );
    const target = stored ? await this.history.chat(stored.id) : null;
    if (!target) return { kind, messages: 1 };
    // 超出 maxGapFill 的部分会留下缺口，由缺口补齐（HoleFiller）接着补。
    const result = await this.history.fetchOlder(target, latestSeq - 1, stopAt, budget - 1);
    const fetched = 1 + result.messages;
    return { kind, messages: fetched };
  }

  private async ingest(qqAccountId: number, selfUin: number, raw: NtRawMessage): Promise<void> {
    // 最新一条入库失败时整个会话这次就不补了（会话可能都还没建起来），下次对账再试。
    const action = mapRawMessage(raw, { selfUin, source: 'backfill' });
    const outcome = await this.inbox.applyAction(qqAccountId, action);
    if (outcome.state === 'failed') throw new Error(outcome.error);
  }
}
