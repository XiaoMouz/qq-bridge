// 同步与 API 共用的行结构，以及从数据库行（snake_case）到它们的映射。
import type { CallRecord } from '../calls/service.ts';
import type { OutgoingSegment, Segment } from '@qqbridge/domain';
import { sql, type SQL } from 'drizzle-orm';
import { toDate } from '../db/client.ts';

type DbRow = Record<string, any>;

export interface MessageRow {
  chatId: number;
  seq: number;
  qqMsgId: string | null;
  senderUin: number;
  time: Date;
  kind: 'normal' | 'service' | 'call';
  segments: Segment[];
  text: string;
  replyToSeq: number | null;
  flags: number;
  state: 'normal' | 'recalled';
  recalledBy: number | null;
  recalledAt: Date | null;
  reactions: unknown;
  /** 最后一次变更时的 chat_pts。 */
  version: number;
  source: string;
  senderName: string | null;
}

const MESSAGE_COLUMN_NAMES = [
  'chat_id',
  'seq',
  'qq_msg_id',
  'sender_uin',
  'time',
  'kind',
  'segments',
  'text',
  'reply_to_seq',
  'flags',
  'state',
  'recalled_by',
  'recalled_at',
  'reactions',
  'version',
  'source',
  'sender_name',
] as const;

export const MESSAGE_COLUMNS = sql.raw(MESSAGE_COLUMN_NAMES.join(', '));

/** 带表别名的消息列（联表查询用）。 */
export function messageColumns(alias: string): SQL {
  return sql.raw(MESSAGE_COLUMN_NAMES.map((c) => `${alias}.${c}`).join(', '));
}

export function toMessage(r: DbRow): MessageRow {
  return {
    chatId: r.chat_id,
    seq: r.seq,
    qqMsgId: r.qq_msg_id ?? null,
    senderUin: r.sender_uin,
    time: toDate(r.time)!,
    kind: r.kind,
    segments: r.segments as Segment[],
    text: r.text,
    replyToSeq: r.reply_to_seq ?? null,
    flags: r.flags,
    state: r.state,
    recalledBy: r.recalled_by ?? null,
    recalledAt: toDate(r.recalled_at),
    reactions: r.reactions ?? null,
    version: r.version,
    source: r.source,
    senderName: r.sender_name ?? null,
  };
}

export interface DialogRow {
  chatId: number;
  qqAccountId: number;
  scene: 'friend' | 'group' | 'temp';
  peerId: number;
  topSeq: number | null;
  topTime: Date | null;
  unreadCount: number;
  unreadMentions: number;
  unreadMentionAll: number;
  unreadReplies: number;
  readInboxMaxSeq: number;
  pinned: boolean;
  pinnedAt: Date | null;
  notifyPolicy: string;
  mentionAllNotify: boolean;
  draft: unknown;
  /** 会话内消息流已分配到的序号。 */
  chatPts: number;
  /** 会话行最后一次变更时的全局 pts。 */
  dialogPts: number;
  topMessage: MessageRow | null;
}

export const DIALOG_COLUMNS = sql.raw(
  'id, qq_account_id, scene, peer_id, top_seq, top_time, unread_count, unread_mentions, unread_mention_all, unread_replies, read_inbox_max_seq, pinned, pinned_at, notify_policy, mention_all_notify, draft, chat_pts, dialog_pts',
);

export function toDialog(r: DbRow, topMessage: MessageRow | null): DialogRow {
  return {
    chatId: r.id,
    qqAccountId: r.qq_account_id,
    scene: r.scene,
    peerId: r.peer_id,
    topSeq: r.top_seq ?? null,
    topTime: toDate(r.top_time),
    unreadCount: r.unread_count,
    unreadMentions: r.unread_mentions,
    unreadMentionAll: r.unread_mention_all ?? 0,
    unreadReplies: r.unread_replies ?? 0,
    readInboxMaxSeq: r.read_inbox_max_seq,
    pinned: r.pinned,
    pinnedAt: toDate(r.pinned_at),
    notifyPolicy: r.notify_policy,
    mentionAllNotify: r.mention_all_notify ?? true,
    draft: r.draft ?? null,
    chatPts: r.chat_pts,
    dialogPts: r.dialog_pts,
    topMessage,
  };
}

export interface PeerRow {
  qqAccountId: number;
  kind: 'user' | 'group';
  peerId: number;
  uid: string | null;
  name: string | null;
  remark: string | null;
  isFriend: boolean;
  memberCount: number | null;
  avatarSha256: string | null;
  sign: string | null;
  pts: number;
}

export const PEER_COLUMNS = sql.raw(
  'qq_account_id, kind, peer_id, uid, name, remark, is_friend, member_count, avatar_sha256, sign, pts',
);

export function toPeer(r: DbRow): PeerRow {
  return {
    qqAccountId: r.qq_account_id,
    kind: r.kind,
    peerId: r.peer_id,
    uid: r.uid ?? null,
    name: r.name ?? null,
    remark: r.remark ?? null,
    isFriend: r.is_friend,
    memberCount: r.member_count ?? null,
    avatarSha256: r.avatar_sha256 ?? null,
    sign: r.sign ?? null,
    pts: r.pts,
  };
}

export interface TombstoneRow {
  pts: number;
  entity: string;
  key: string;
}

export interface ChatEventRow {
  id: number;
  chatId: number;
  kind: string;
  time: Date;
  actorId: number | null;
  targetId: number | null;
  refSeq: number | null;
  data: Record<string, unknown>;
  version: number;
}

export const CHAT_EVENT_COLUMNS = sql.raw('id, chat_id, kind, time, actor_id, target_id, ref_seq, data, version');

export function toChatEvent(r: DbRow): ChatEventRow {
  return {
    id: r.id,
    chatId: r.chat_id,
    kind: r.kind,
    time: toDate(r.time)!,
    actorId: r.actor_id ?? null,
    targetId: r.target_id ?? null,
    refSeq: r.ref_seq ?? null,
    data: (r.data ?? {}) as Record<string, unknown>,
    version: r.version,
  };
}

export type OutboxState = 'pending' | 'sending' | 'sent' | 'failed';

export interface OutboxRow {
  id: number;
  clientRandomId: number;
  chatId: number;
  state: OutboxState;
  segments: OutgoingSegment[];
  replyToSeq: number | null;
  resultSeq: number | null;
  error: string | null;
  createdAt: Date;
  pts: number;
}

export const OUTBOX_COLUMNS = sql.raw('id, client_random_id, chat_id, state, content, result_seq, error, created_at, pts');

export function toOutbox(r: DbRow): OutboxRow {
  const content = (r.content ?? {}) as { segments?: OutgoingSegment[]; replyToSeq?: number };
  return {
    id: r.id,
    clientRandomId: r.client_random_id,
    chatId: r.chat_id,
    state: r.state,
    segments: content.segments ?? [],
    replyToSeq: content.replyToSeq ?? null,
    resultSeq: r.result_seq ?? null,
    error: r.error ?? null,
    createdAt: toDate(r.created_at)!,
    pts: r.pts,
  };
}

/** 推送给在线客户端的更新。带全局 pts 的三种用于会话列表与资料；chatMessage 带会话内的 chat_pts。 */
export type Update =
  | { type: 'dialog'; pts: number; dialog: DialogRow }
  | { type: 'peer'; pts: number; peer: PeerRow }
  | { type: 'tombstone'; pts: number; tombstone: TombstoneRow }
  | { type: 'chatMessage'; chatId: number; chatPts: number; message: MessageRow }
  | { type: 'outbox'; pts: number; entry: OutboxRow }
  | { type: 'chatEvent'; chatId: number; chatPts: number; event: ChatEventRow }
  /** 临时事件（"对方正在输入"）：不占 pts、不存档。 */
  | { type: 'typing'; chatId: number; userId: number; text: string }
  | { type: 'call'; call: CallRecord };

/** 生成 (a, b, c) 形式的列表；调用方需保证非空。 */
export function sqlList(values: readonly (number | string)[]): SQL {
  if (values.length === 0) throw new Error('sqlList requires at least one value');
  return sql`(${sql.join(
    values.map((v) => sql`${v}`),
    sql`, `,
  )})`;
}
