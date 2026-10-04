// 会话偏好：置顶、通知策略、草稿。都只是服务端与各客户端之间的状态（不改 QQ 里的设置），
// 改动经单写者分配 dialog_pts，所有设备都会收到会话更新。
import { validateOutgoing, type OutgoingSegment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { maybeOne } from '../db/client.ts';
import type { WriterRegistry } from '../sync/writer.ts';

export const NOTIFY_POLICIES = ['default', 'all', 'mentions', 'muted'] as const;
export type NotifyPolicy = (typeof NOTIFY_POLICIES)[number];

export interface Draft {
  segments: OutgoingSegment[];
  replyToSeq?: number;
  /** unix 秒。 */
  updatedAt: number;
}

export class DialogPrefsError extends Error {
  constructor(
    readonly code: 'invalid' | 'not_found',
    message: string,
  ) {
    super(message);
  }
}

const DRAFT_SEGMENTS = new Set<OutgoingSegment['type']>(['text', 'mention', 'mention_all', 'face']);

export class DialogPrefs {
  constructor(private readonly writers: WriterRegistry) {}

  setPinned(accountId: number, chatId: number, pinned: boolean): Promise<boolean> {
    return this.change(accountId, chatId, 'pinned', pinned);
  }

  setNotifyPolicy(accountId: number, chatId: number, policy: string): Promise<boolean> {
    if (!(NOTIFY_POLICIES as readonly string[]).includes(policy)) {
      return Promise.reject(new DialogPrefsError('invalid', `notify policy must be one of ${NOTIFY_POLICIES.join(', ')}`));
    }
    return this.change(accountId, chatId, 'notify_policy', policy);
  }

  /** segments 为空表示清除草稿。 */
  saveDraft(accountId: number, chatId: number, segments: OutgoingSegment[], replyToSeq?: number, nowSec = Math.floor(Date.now() / 1000)) {
    if (segments.length === 0) return this.change(accountId, chatId, 'draft', null);
    if (segments.some((s) => !DRAFT_SEGMENTS.has(s.type))) {
      return Promise.reject(new DialogPrefsError('invalid', 'drafts can only contain text, mentions and faces'));
    }
    const problem = validateOutgoing({ segments, ...(replyToSeq ? { replyToSeq } : {}) });
    if (problem) return Promise.reject(new DialogPrefsError('invalid', problem));
    const draft: Draft = { segments, ...(replyToSeq ? { replyToSeq } : {}), updatedAt: nowSec };
    return this.change(accountId, chatId, 'draft', draft);
  }

  private change(accountId: number, chatId: number, column: 'pinned' | 'notify_policy' | 'draft', value: unknown): Promise<boolean> {
    return this.writers.forAccount(accountId).run(async (w) => {
      const chat = await maybeOne<{ pinned: boolean; notify_policy: string; draft: Draft | null }>(
        w.tx,
        sql`select c.pinned, c.notify_policy, c.draft from chats c join qq_accounts q on q.id = c.qq_account_id
             where c.id = ${chatId} and q.account_id = ${accountId} for update of c`,
      );
      if (!chat) throw new DialogPrefsError('not_found', `chat ${chatId} not found`);
      const current = column === 'pinned' ? chat.pinned : column === 'notify_policy' ? chat.notify_policy : chat.draft;
      if (column === 'draft' ? sameDraft(current as Draft | null, value as Draft | null) : current === value) return false;
      if (column === 'draft') {
        await w.tx.execute(sql`update chats set draft = ${value === null ? null : JSON.stringify(value)}::jsonb where id = ${chatId}`);
      } else {
        await w.tx.execute(sql`update chats set ${sql.raw(column)} = ${value} where id = ${chatId}`);
      }
      w.touchDialog(chatId);
      return true;
    });
  }
}

/** 草稿内容相同（只是保存时间不同）不算变化，避免每次失焦都推一次更新。 */
function sameDraft(a: Draft | null, b: Draft | null): boolean {
  if (!a || !b) return a === b;
  return canonical(a.segments) === canonical(b.segments) && (a.replyToSeq ?? 0) === (b.replyToSeq ?? 0);
}

/** 与键顺序无关的序列化（JSONB 读出来的对象键顺序和写入时不同）。 */
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([x], [y]) => (x < y ? -1 : x > y ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(',')}}`;
  }
  return JSON.stringify(value);
}
