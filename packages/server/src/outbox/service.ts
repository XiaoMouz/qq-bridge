// 发件箱（docs/design.md 4.7"发送幂等"）：发送请求先落库再异步发往 QQ。
// - (账号, client_random_id) 唯一：客户端重试同一条消息只会返回同一个条目；失败的条目重提交即重试；
// - 每次状态变化都分配全局 pts 并推送，所有设备都能看到"发送中 / 已发送 / 失败"。
import { outgoingMedia, validateOutgoing, type OutgoingMessage } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { maybeOne, one, rows, type Db } from '../db/client.ts';
import { OUTBOX_COLUMNS, sqlList, toOutbox, type OutboxRow, type OutboxState } from '../sync/rows.ts';
import type { WriterRegistry } from '../sync/writer.ts';

export class OutboxError extends Error {
  constructor(
    readonly code: 'invalid' | 'not_found' | 'media_missing',
    message: string,
  ) {
    super(message);
  }
}

export interface OutboxPatch {
  state: OutboxState;
  resultSeq?: number | null;
  qqMsgId?: string | null;
  error?: string | null;
  attempts?: number;
  nextAttemptAt?: Date | null;
}

export class OutboxService {
  /** 有新的待发送条目（唤醒发送任务）。 */
  onEnqueued: (() => void) | null = null;

  constructor(
    private readonly db: Db,
    private readonly writers: WriterRegistry,
  ) {}

  async enqueue(
    accountId: number,
    deviceId: number | null,
    req: { chatId: number; clientRandomId: number; message: OutgoingMessage },
  ): Promise<OutboxRow> {
    if (!Number.isSafeInteger(req.clientRandomId) || req.clientRandomId === 0) {
      throw new OutboxError('invalid', 'client_random_id is required');
    }
    const problem = validateOutgoing(req.message);
    if (problem) throw new OutboxError('invalid', problem);
    const chat = await maybeOne(
      this.db,
      sql`select c.id from chats c join qq_accounts q on q.id = c.qq_account_id where c.id = ${req.chatId} and q.account_id = ${accountId}`,
    );
    if (!chat) throw new OutboxError('not_found', `chat ${req.chatId} not found`);
    const shas = outgoingMedia(req.message.segments);
    if (shas.length > 0) {
      const present = await rows<{ sha256: string }>(
        this.db,
        sql`select sha256 from blobs where sha256 in ${sqlList(shas)} and state = 'present'`,
      );
      const missing = shas.filter((s) => !present.some((p) => p.sha256 === s));
      if (missing.length > 0) throw new OutboxError('media_missing', `media not uploaded: ${missing.join(', ')}`);
    }

    const content = { segments: req.message.segments, ...(req.message.replyToSeq ? { replyToSeq: req.message.replyToSeq } : {}) };
    const entry = await this.writers.forAccount(accountId).run(async (w) => {
      const existing = await maybeOne(
        w.tx,
        sql`select ${OUTBOX_COLUMNS} from outbox where account_id = ${accountId} and client_random_id = ${req.clientRandomId} for update`,
      );
      if (existing && existing.state !== 'failed') return { entry: toOutbox(existing), changed: false };
      const pts = await w.allocPts();
      const row = existing
        ? await one(
            w.tx,
            sql`update outbox set state = 'pending', error = null, attempts = 0, next_attempt_at = null, pts = ${pts}, updated_at = now()
                 where id = ${existing.id as number} returning ${OUTBOX_COLUMNS}`,
          )
        : await one(
            w.tx,
            sql`insert into outbox (account_id, chat_id, device_id, client_random_id, content, state, pts)
                values (${accountId}, ${req.chatId}, ${deviceId}, ${req.clientRandomId}, ${JSON.stringify(content)}::jsonb, 'pending', ${pts})
                returning ${OUTBOX_COLUMNS}`,
          );
      const updated = toOutbox(row);
      w.emit({ type: 'outbox', pts, entry: updated });
      return { entry: updated, changed: true };
    });
    if (entry.changed) this.onEnqueued?.();
    return entry.entry;
  }

  /**
   * 状态变化（发送任务用）：分配新的 pts 并推送。给了 expectState 时只在当前状态符合时才更新
   * （用于"认领"：pending → sending），不符合返回 null。
   */
  async update(accountId: number, id: number, patch: OutboxPatch, expectState?: OutboxState): Promise<OutboxRow | null> {
    return this.writers.forAccount(accountId).run(async (w) => {
      if (expectState) {
        const current = await maybeOne<{ state: string }>(w.tx, sql`select state from outbox where id = ${id} for update`);
        if (current?.state !== expectState) return null;
      }
      const pts = await w.allocPts();
      const set = [
        sql`state = ${patch.state}`,
        sql`pts = ${pts}`,
        sql`updated_at = now()`,
        ...(patch.resultSeq !== undefined ? [sql`result_seq = ${patch.resultSeq}`] : []),
        ...(patch.qqMsgId !== undefined ? [sql`qq_msg_id = ${patch.qqMsgId}`] : []),
        ...(patch.error !== undefined ? [sql`error = ${patch.error === null ? null : patch.error.slice(0, 500)}`] : []),
        ...(patch.attempts !== undefined ? [sql`attempts = ${patch.attempts}`] : []),
        ...(patch.nextAttemptAt !== undefined
          ? [sql`next_attempt_at = ${patch.nextAttemptAt ? patch.nextAttemptAt.toISOString() : null}::timestamptz`]
          : []),
      ];
      const entry = toOutbox(
        await one(w.tx, sql`update outbox set ${sql.join(set, sql`, `)} where id = ${id} returning ${OUTBOX_COLUMNS}`),
      );
      w.emit({ type: 'outbox', pts, entry });
      return entry;
    });
  }
}
