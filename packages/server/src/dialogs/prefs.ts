// 会话偏好：置顶、通知策略（含 @全体成员 是否提醒）、草稿。改动经单写者分配 dialog_pts，所有设备都会收到会话更新。
// 置顶和通知策略最初从 QQ 同步（QqSettingsSync）；在本 App 里改过之后记 *_local，之后以这里为准，QQ 的设置不再覆盖。
// NapCat 没有改 QQ 置顶 / 群消息设置的接口，所以这里的改动不回写 QQ。
import { validateOutgoing, type OutgoingSegment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { maybeOne } from '../db/client.ts';
import type { WriterRegistry } from '../sync/writer.ts';

/** archived = 收进群助手（不提醒，会话列表里收进"群助手"）。 */
export const NOTIFY_POLICIES = ['default', 'all', 'mentions', 'muted', 'archived'] as const;
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

  setMentionAllNotify(accountId: number, chatId: number, enabled: boolean): Promise<boolean> {
    return this.change(accountId, chatId, 'mention_all_notify', enabled);
  }

  /**
   * 从 QQ 同步来的置顶与通知设置：用户在本 App 里改过的那一项不覆盖。返回是否有变化。
   * pinnedAt 为 QQ 的置顶时间（没有就用现在）。
   */
  applyFromQq(
    accountId: number,
    chatId: number,
    settings: { pinned?: boolean; pinnedAt?: Date | null; notifyPolicy?: NotifyPolicy },
  ): Promise<boolean> {
    return this.writers.forAccount(accountId).run(async (w) => {
      const chat = await maybeOne<{ pinned: boolean; pinned_at: Date | string | null; notify_policy: string; pinned_local: boolean; notify_local: boolean }>(
        w.tx,
        sql`select pinned, pinned_at, notify_policy, pinned_local, notify_local from chats where id = ${chatId} for update`,
      );
      if (!chat) return false;
      let changed = false;
      if (settings.pinned !== undefined && !chat.pinned_local) {
        const at = settings.pinned ? (settings.pinnedAt ?? (chat.pinned_at ? new Date(chat.pinned_at) : new Date())) : null;
        const sameAt = (at?.getTime() ?? null) === (chat.pinned_at ? new Date(chat.pinned_at).getTime() : null);
        if (chat.pinned !== settings.pinned || !sameAt) {
          await w.tx.execute(sql`update chats set pinned = ${settings.pinned}, pinned_at = ${at} where id = ${chatId}`);
          changed = true;
        }
      }
      if (settings.notifyPolicy !== undefined && !chat.notify_local && chat.notify_policy !== settings.notifyPolicy) {
        await w.tx.execute(sql`update chats set notify_policy = ${settings.notifyPolicy} where id = ${chatId}`);
        changed = true;
      }
      if (changed) w.touchDialog(chatId);
      return changed;
    });
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

  private change(
    accountId: number,
    chatId: number,
    column: 'pinned' | 'notify_policy' | 'mention_all_notify' | 'draft',
    value: unknown,
  ): Promise<boolean> {
    return this.writers.forAccount(accountId).run(async (w) => {
      const chat = await maybeOne<{ pinned: boolean; notify_policy: string; mention_all_notify: boolean; draft: Draft | null }>(
        w.tx,
        sql`select c.pinned, c.notify_policy, c.mention_all_notify, c.draft from chats c join qq_accounts q on q.id = c.qq_account_id
             where c.id = ${chatId} and q.account_id = ${accountId} for update of c`,
      );
      if (!chat) throw new DialogPrefsError('not_found', `chat ${chatId} not found`);
      const current = column === 'draft' ? chat.draft : chat[column];
      if (column === 'draft' ? sameDraft(current as Draft | null, value as Draft | null) : current === value) return false;
      if (column === 'draft') {
        await w.tx.execute(sql`update chats set draft = ${value === null ? null : JSON.stringify(value)}::jsonb where id = ${chatId}`);
      } else if (column === 'pinned') {
        // 本地改过置顶：之后 QQ 的置顶不再覆盖。
        await w.tx.execute(sql`update chats set pinned = ${value as boolean}, pinned_at = ${value ? new Date() : null}, pinned_local = true where id = ${chatId}`);
      } else if (column === 'notify_policy') {
        await w.tx.execute(sql`update chats set notify_policy = ${value as string}, notify_local = true where id = ${chatId}`);
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
