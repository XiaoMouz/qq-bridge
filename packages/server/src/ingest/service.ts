// 入库服务：把上游适配器产出的领域事件写进数据库，分配同步序号，并发布给在线客户端。
// 所有写操作都经过账号的单写者（sync/writer.ts）。未读数的增量规则与 recomputeUnread 的全量定义一致：
//   未读 = 会话里 seq > 已读位置、发送者不是本人、未被撤回的消息数。
import {
  applyReactionChange,
  MessageFlag,
  messageFlags,
  plainText,
  updateMediaInfo,
  type IncomingMedia,
  type IncomingMessage,
  type IncomingChatEvent,
  type MediaInfo,
  type PeerProfile,
  type Reaction,
  type ReactionChange,
  type Scene,
  type Segment,
} from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import type { CallRecord } from '../calls/service.ts';
import { maybeOne, one, rows, type Db, type Tx } from '../db/client.ts';
import { pgJson, stripNul } from '../db/nul.ts';
import { addUsage, findReusableBlob, reusedMediaPatch, type ReusableBlob } from '../media/accounting.ts';
import { NotFoundError } from '../sync/difference.ts';
import { CHAT_EVENT_COLUMNS, MESSAGE_COLUMNS, PEER_COLUMNS, toChatEvent, toMessage, toPeer } from '../sync/rows.ts';
import type { WriteContext, WriterRegistry } from '../sync/writer.ts';

// 三种未读互不重复：QQ 的回复会自动带上 "@被回复人"，所以回复我的消息只算"回复我"，不再算 @我；
// 同时 @我和 @全体成员的只算 @我。
const { mentionsMe: MENTION_ME, mentionAll: MENTION_ALL, replyToMe: REPLY_TO_ME } = MessageFlag;

interface QqAccountInfo {
  accountId: number;
  uin: number;
}

interface LockedChat {
  id: number;
  top_seq: number | null;
  read_inbox_max_seq: number;
  notify_policy: string;
}

/**
 * 下载规则：
 * - 图片：原图一律按需（客户端点开看时才从 QQ 拿）；"QQ 缩略图"引用（role = qq_thumb，QQ 的 spec=720，长边约 1280px）
 *   在私聊和常用群聊（正常提醒）里消息到了就下载，免打扰 / 群助手里的群显示到时才要。服务端不自己生成缩略图。
 * - 动画表情：和缩略图一样（要原图才能动）。
 * - 视频、文件：私聊到了就下载；群聊一律按需（点进去看时才要）。
 * - 下载过的原件都留着，不自动清理（不常用的由冷热分层沉到冷存储，需要时手动清理）。
 */
export const ON_DEMAND_POLICIES: readonly string[] = ['muted', 'archived'];
export const ON_DEMAND_KINDS: readonly string[] = ['image', 'video', 'file'];
export const QQ_THUMB_ROLE = 'qq_thumb';

/** 照片（不含动画表情：表情要原图才能动，QQ 的缩略档只有第一帧）。 */
const isPhoto = (m: { kind: string; role: string }) => m.kind === 'image' && m.role !== 'sticker';

/** 入库时这个媒体（的原件）是不是按需。见上面的下载规则。 */
function onDemandAtIngest(m: { kind: string; role: string; locator?: unknown }, groupChat: boolean, quietGroup: boolean): boolean {
  // 照片原图一律按需；没有定位信息的（以后换不了新链接）只能立刻下原图。
  if (isPhoto(m)) return Boolean(m.locator);
  if (m.kind === 'image') return quietGroup; // 动画表情
  if (m.kind === 'video' || m.kind === 'file') return groupChat;
  return false;
}

export interface ForwardNodeInput {
  senderId: number;
  senderName: string;
  /** unix 秒。 */
  time: number;
  /** NT msgId：展开这个节点里嵌套的合并转发时要用。 */
  msgId: string;
  segments: Segment[];
  media: IncomingMedia[];
}

export type StoredForwardNode = Omit<ForwardNodeInput, 'media'>;

export interface ForwardBundleRow {
  id: number;
  state: 'ready' | 'unavailable';
  nodes: StoredForwardNode[];
}

export class IngestService {
  private readonly qqAccounts = new Map<number, QqAccountInfo>();
  /** 新消息入库（提交）之后调用，用于推送；只在消息是别人发的时候调用。 */
  onNewMessage: ((event: { accountId: number; chatId: number; seq: number }) => void) | null = null;

  constructor(
    private readonly db: Db,
    private readonly writers: WriterRegistry,
  ) {}

  /** 登记（或更新昵称）一个 QQ 号，返回 qq_account_id。 */
  async registerQqAccount(accountId: number, uin: number, nickname?: string): Promise<number> {
    const row = await one<{ id: number; account_id: number }>(
      this.db,
      sql`insert into qq_accounts (account_id, uin, nickname) values (${accountId}, ${uin}, ${nickname ?? null})
          on conflict (uin) do update set nickname = coalesce(excluded.nickname, qq_accounts.nickname)
          returning id, account_id`,
    );
    if (row.account_id !== accountId) throw new Error(`QQ ${uin} is bound to another account`);
    this.qqAccounts.set(row.id, { accountId, uin });
    return row.id;
  }

  private async qqAccount(qqAccountId: number): Promise<QqAccountInfo> {
    const cached = this.qqAccounts.get(qqAccountId);
    if (cached) return cached;
    const row = await maybeOne<{ account_id: number; uin: number }>(
      this.db,
      sql`select account_id, uin from qq_accounts where id = ${qqAccountId}`,
    );
    if (!row) throw new NotFoundError(`qq account ${qqAccountId} not found`);
    const info = { accountId: row.account_id, uin: row.uin };
    this.qqAccounts.set(qqAccountId, info);
    return info;
  }

  async ingestMessage(qqAccountId: number, incoming: IncomingMessage): Promise<{ chatId: number; inserted: boolean }> {
    const msg = stripNul(incoming);
    const qq = await this.qqAccount(qqAccountId);
    const result = await this.writers.forAccount(qq.accountId).run(async (w) => {
      const chat = await lockOrCreateChat(w.tx, qqAccountId, msg.scene, msg.peerId, initialReadMarker(msg, qq.uin));
      const existing = await maybeOne(w.tx, sql`select 1 as x from messages where chat_id = ${chat.id} and seq = ${msg.seq}`);
      if (existing) return { chatId: chat.id, inserted: false };

      // 下载前去重：QQ 给了 md5 且已有同样内容，直接复用，不再下载。
      let segments: Segment[] = msg.segments;
      const reused = new Map<number, ReusableBlob>();
      for (const media of msg.media) {
        if (!media.qqMd5) continue;
        const hit = await findReusableBlob(w.tx, media.qqMd5, media.size, Boolean(media.qqMd5Partial));
        if (!hit) continue;
        reused.set(media.ord, hit);
        segments = updateMediaInfo(segments, media.ord, reusedMediaPatch(hit));
      }
      const groupChat = msg.scene === 'group';
      const quietGroup = groupChat && ON_DEMAND_POLICIES.includes(chat.notify_policy);
      const onDemand = new Set(
        msg.media
          .filter((m) => !reused.has(m.ord) && onDemandAtIngest(m, groupChat, quietGroup))
          .map((m) => m.ord),
      );
      for (const ord of onDemand) segments = updateMediaInfo(segments, ord, { state: 'on_demand' });

      const flags = messageFlags(segments, qq.uin);
      const reply = segments.find((s): s is Extract<Segment, { type: 'reply' }> => s.type === 'reply');
      const time = new Date(msg.time * 1000).toISOString();
      const chatPts = await w.allocChatPts(chat.id);
      const message = toMessage(
        await one(
          w.tx,
          sql`insert into messages (chat_id, seq, qq_msg_id, random, sender_uin, sender_name, time, kind, segments, text, reply_to_seq, flags, version, source, raw)
              values (${chat.id}, ${msg.seq}, ${msg.qqMsgId ?? null}, ${msg.random ?? null}, ${msg.senderId}, ${msg.senderName ? stripNul(msg.senderName) : null}, ${time}, 'normal',
                      ${pgJson(segments)}::jsonb, ${plainText(segments)}, ${reply?.seq ?? null}, ${flags}, ${chatPts},
                      ${msg.source}, ${msg.raw === undefined ? null : pgJson(msg.raw)}::jsonb)
              returning ${MESSAGE_COLUMNS}`,
        ),
      );

      for (const media of msg.media) {
        const hit = reused.get(media.ord);
        await w.tx.execute(
          sql`insert into media_refs (chat_id, message_seq, ordinal, role, kind, sha256, qq_md5, qq_md5_partial, qq_file_uuid,
                                      qq_resource_id, qq_file_id, url, url_expires_at, size, name, mime, fetch_state, thumbhash,
                                      locator, sender_uin, time)
              values (${chat.id}, ${msg.seq}, ${media.ord}, ${media.role}, ${media.kind}, ${hit?.sha256 ?? null},
                      ${media.qqMd5?.toLowerCase() ?? null}, ${Boolean(media.qqMd5Partial)}, ${media.qqFileUuid ?? null},
                      ${media.qqResourceId ?? null}, ${media.qqFileId ?? null}, ${media.url ?? null},
                      ${media.urlExpiresAt ? new Date(media.urlExpiresAt * 1000).toISOString() : null},
                      ${media.size ?? null}, ${media.name ?? null}, ${media.mime ?? null},
                      ${hit ? 'stored' : onDemand.has(media.ord) ? 'on_demand' : 'pending'}, ${hit?.thumbhash ?? null},
                      ${media.locator ? pgJson(media.locator) : null}::jsonb, ${msg.senderId}, ${time})`,
        );
        if (hit) await addUsage(w.tx, chat.id, hit.sha256);
        if (isPhoto(media) && !hit?.thumbSha256 && media.locator) {
          await w.tx.execute(
            sql`insert into media_refs (chat_id, message_seq, ordinal, role, kind, qq_md5, qq_md5_partial, qq_file_uuid,
                                        qq_resource_id, qq_file_id, url, url_expires_at, fetch_state, locator, sender_uin, time)
                values (${chat.id}, ${msg.seq}, ${media.ord}, ${QQ_THUMB_ROLE}, 'image', ${media.qqMd5?.toLowerCase() ?? null},
                        ${Boolean(media.qqMd5Partial)}, ${media.qqFileUuid ?? null}, ${media.qqResourceId ?? null},
                        ${media.qqFileId ?? null}, ${media.url ?? null},
                        ${media.urlExpiresAt ? new Date(media.urlExpiresAt * 1000).toISOString() : null},
                        ${quietGroup ? 'on_demand' : 'pending'}, ${pgJson(media.locator)}::jsonb, ${msg.senderId}, ${time})`,
          );
        }
      }
      w.emit({ type: 'chatMessage', chatId: chat.id, chatPts, message });

      const fromOther = msg.senderId !== qq.uin;
      const countsUnread = fromOther && msg.seq > chat.read_inbox_max_seq;
      await w.tx.execute(
        sql`update chats set
              top_seq = case when top_seq is null or ${msg.seq} >= top_seq then ${msg.seq} else top_seq end,
              top_time = case when top_seq is null or ${msg.seq} >= top_seq then ${time}::timestamptz else top_time end,
              unread_count = unread_count + ${countsUnread ? 1 : 0},
              unread_mentions = unread_mentions + ${countsUnread && (flags & MENTION_ME) !== 0 && (flags & REPLY_TO_ME) === 0 ? 1 : 0},
              unread_mention_all = unread_mention_all + ${countsUnread && (flags & MENTION_ALL) !== 0 && (flags & (MENTION_ME | REPLY_TO_ME)) === 0 ? 1 : 0},
              unread_replies = unread_replies + ${countsUnread && (flags & REPLY_TO_ME) !== 0 ? 1 : 0}
            where id = ${chat.id}`,
      );
      // 本人在其他设备上发言：视为已读到这里（与 Telegram 行为一致）。
      if (!fromOther && msg.source !== 'backfill' && msg.seq > chat.read_inbox_max_seq) {
        await setReadMarker(w.tx, chat.id, msg.seq, qq.uin);
      }
      w.touchDialog(chat.id);
      return { chatId: chat.id, inserted: true };
    });
    if (result.inserted && msg.senderId !== qq.uin) this.onNewMessage?.({ accountId: qq.accountId, chatId: result.chatId, seq: msg.seq });
    return result;
  }

  /** 消息撤回：保留原内容，只标记状态（防撤回）。 */
  async recall(qqAccountId: number, scene: Scene, peerId: number, seq: number, operatorId: number, timeSec: number): Promise<boolean> {
    const qq = await this.qqAccount(qqAccountId);
    return this.writers.forAccount(qq.accountId).run(async (w) => {
      const chat = await maybeOne<LockedChat>(
        w.tx,
        sql`select id, top_seq, read_inbox_max_seq from chats
             where qq_account_id = ${qqAccountId} and scene = ${scene} and peer_id = ${peerId} for update`,
      );
      if (!chat) return false;
      const target = await maybeOne<{ sender_uin: number; state: string }>(
        w.tx,
        sql`select sender_uin, state from messages where chat_id = ${chat.id} and seq = ${seq}`,
      );
      if (!target || target.state === 'recalled') return false;

      const chatPts = await w.allocChatPts(chat.id);
      const message = toMessage(
        await one(
          w.tx,
          sql`update messages set state = 'recalled', recalled_by = ${operatorId},
                     recalled_at = ${new Date(timeSec * 1000).toISOString()}, version = ${chatPts}
               where chat_id = ${chat.id} and seq = ${seq}
               returning ${MESSAGE_COLUMNS}`,
        ),
      );
      w.emit({ type: 'chatMessage', chatId: chat.id, chatPts, message });

      if (target.sender_uin !== qq.uin && seq > chat.read_inbox_max_seq) await recomputeUnread(w.tx, chat.id, qq.uin);
      return true;
    });
  }

  /** 发起会话（联系人页点"发消息"）：会话已有就直接返回，没有就新建（经 pts 推给所有设备）。 */
  async openChat(accountId: number, scene: Scene, peerId: number): Promise<number> {
    const qq = await maybeOne<{ id: number }>(this.db, sql`select id from qq_accounts where account_id = ${accountId} order by id limit 1`);
    if (!qq) throw new NotFoundError('no QQ account is linked');
    const existing = await maybeOne<{ id: number }>(
      this.db,
      sql`select id from chats where qq_account_id = ${qq.id} and scene = ${scene} and peer_id = ${peerId}`,
    );
    if (existing) return existing.id;
    return this.writers.forAccount(accountId).run(async (w) => {
      const chat = await lockOrCreateChat(w.tx, qq.id, scene, peerId, 0);
      w.touchDialog(chat.id);
      return chat.id;
    });
  }

  /** 看过了这些 @我 / 回复我 / @全体成员（聊天页里出现在屏幕上，或从"有人@我"跳过去）：不再算未读 @，已读位置不动。 */
  async markMentionsSeen(accountId: number, chatId: number, seqs: readonly number[]): Promise<boolean> {
    if (seqs.length === 0) return false;
    return this.writers.forAccount(accountId).run(async (w) => {
      const chat = await maybeOne<{ id: number; uin: number }>(
        w.tx,
        sql`select c.id, q.uin from chats c join qq_accounts q on q.id = c.qq_account_id
             where c.id = ${chatId} and q.account_id = ${accountId} for update of c`,
      );
      if (!chat) throw new NotFoundError(`chat ${chatId} not found`);
      const list = sql.join(seqs.slice(0, 500).map((s) => sql`${s}`), sql`, `);
      const changed = await rows(
        w.tx,
        sql`update messages set mention_seen = true
             where chat_id = ${chatId} and seq in (${list}) and not mention_seen
               and (flags & ${MENTION_ME | MENTION_ALL | REPLY_TO_ME}) <> 0
         returning seq`,
      );
      if (changed.length === 0) return false;
      await recomputeUnread(w.tx, chat.id, chat.uin);
      w.touchDialog(chat.id);
      return true;
    });
  }

  /** 客户端标记已读到 maxSeq。 */
  async markRead(accountId: number, chatId: number, maxSeq: number): Promise<boolean> {
    return this.writers.forAccount(accountId).run(async (w) => {
      const chat = await maybeOne<LockedChat & { uin: number }>(
        w.tx,
        sql`select c.id, c.top_seq, c.read_inbox_max_seq, q.uin from chats c join qq_accounts q on q.id = c.qq_account_id
             where c.id = ${chatId} and q.account_id = ${accountId} for update of c`,
      );
      if (!chat) throw new NotFoundError(`chat ${chatId} not found`);
      if (maxSeq <= chat.read_inbox_max_seq) return false;
      await setReadMarker(w.tx, chat.id, maxSeq, chat.uin);
      w.touchDialog(chat.id);
      return true;
    });
  }

  /** 更新联系人或群资料；内容没变就不产生更新。 */
  async upsertPeer(qqAccountId: number, profile: PeerProfile): Promise<boolean> {
    const qq = await this.qqAccount(qqAccountId);
    return this.writers.forAccount(qq.accountId).run(async (w) => {
      const current = await maybeOne(
        w.tx,
        sql`select ${PEER_COLUMNS} from peers
             where qq_account_id = ${qqAccountId} and kind = ${profile.kind} and peer_id = ${profile.peerId} for update`,
      );
      const prev = current ? toPeer(current) : null;
      const next = {
        uid: profile.uid ?? prev?.uid ?? null,
        name: profile.name ?? prev?.name ?? null,
        remark: profile.remark ?? prev?.remark ?? null,
        isFriend: profile.isFriend ?? prev?.isFriend ?? false,
        memberCount: profile.memberCount ?? prev?.memberCount ?? null,
        sign: profile.sign ?? prev?.sign ?? null,
        avatarSha256: profile.avatarSha256 ?? prev?.avatarSha256 ?? null,
      };
      if (
        prev &&
        prev.uid === next.uid &&
        prev.name === next.name &&
        prev.remark === next.remark &&
        prev.isFriend === next.isFriend &&
        prev.memberCount === next.memberCount &&
        prev.sign === next.sign &&
        prev.avatarSha256 === next.avatarSha256
      ) {
        return false;
      }
      const pts = await w.allocPts();
      const peer = toPeer(
        await one(
          w.tx,
          sql`insert into peers (qq_account_id, kind, peer_id, uid, name, remark, is_friend, member_count, sign, avatar_sha256, pts)
              values (${qqAccountId}, ${profile.kind}, ${profile.peerId}, ${next.uid}, ${next.name}, ${next.remark},
                      ${next.isFriend}, ${next.memberCount}, ${next.sign}, ${next.avatarSha256}, ${pts})
              on conflict (qq_account_id, kind, peer_id) do update
                 set uid = excluded.uid, name = excluded.name, remark = excluded.remark, is_friend = excluded.is_friend,
                     member_count = excluded.member_count, sign = excluded.sign, avatar_sha256 = excluded.avatar_sha256,
                     pts = excluded.pts, updated_at = now()
              returning ${PEER_COLUMNS}`,
        ),
      );
      w.emit({ type: 'peer', pts, peer });
      return true;
    });
  }

  /**
   * 媒体下载完成：引用指向 blob，计入会话占用，并更新消息里的媒体状态（客户端经 chat_pts 收到）。
   * extra 带上缩略图 / 预览图 / thumbhash / 尺寸等派生信息。
   */
  async mediaStored(
    refId: number,
    blob: { sha256: string; size: number; mime?: string | null },
    extra: Partial<Pick<MediaInfo, 'thumbhash' | 'thumbSha256' | 'previewSha256' | 'width' | 'height' | 'playableSha256' | 'waveform'>> = {},
  ): Promise<boolean> {
    const accountId = await this.accountOfRef(refId);
    return this.writers.forAccount(accountId).run(async (w) => {
      const locked = await one<MediaRefTarget & { sha256: string | null }>(
        w.tx,
        sql`select chat_id, message_seq, chat_event_id, forward_bundle_id, node_path, ordinal, sha256 from media_refs where id = ${refId} for update`,
      );
      if (locked.sha256) return false;
      await w.tx.execute(
        sql`update media_refs set sha256 = ${blob.sha256}, fetch_state = 'stored', last_error = null,
                                  next_attempt_at = null, thumbhash = ${extra.thumbhash ?? null}
             where id = ${refId}`,
      );
      await addUsage(w.tx, locked.chat_id, blob.sha256);
      await updateMessageMedia(w, locked, {
        state: 'stored',
        sha256: blob.sha256,
        size: blob.size,
        ...(blob.mime ? { mime: blob.mime } : {}),
        ...extra,
      });
      return true;
    });
  }

  /** QQ 缩略图下好了：记进消息的缩略图（原件状态不变）。 */
  async thumbStored(refId: number, blob: { sha256: string; size: number }): Promise<boolean> {
    const accountId = await this.accountOfRef(refId);
    return this.writers.forAccount(accountId).run(async (w) => {
      const locked = await one<MediaRefTarget & { sha256: string | null }>(
        w.tx,
        sql`select chat_id, message_seq, chat_event_id, forward_bundle_id, node_path, ordinal, sha256 from media_refs where id = ${refId} for update`,
      );
      if (locked.sha256) return false;
      await w.tx.execute(
        sql`update media_refs set sha256 = ${blob.sha256}, fetch_state = 'stored', last_error = null, next_attempt_at = null where id = ${refId}`,
      );
      await addUsage(w.tx, locked.chat_id, blob.sha256);
      await updateMessageMedia(w, locked, { thumbSha256: blob.sha256 });
      return true;
    });
  }

  /** 媒体拿不到了（链接过期、超过大小上限、多次重试后放弃）：记录原因，并把消息里的媒体状态告诉客户端。 */
  async mediaUnavailable(refId: number, state: 'expired' | 'skipped' | 'failed', reason: string): Promise<boolean> {
    const accountId = await this.accountOfRef(refId);
    return this.writers.forAccount(accountId).run(async (w) => {
      const locked = await one<MediaRefTarget & { sha256: string | null; role: string }>(
        w.tx,
        sql`select chat_id, message_seq, chat_event_id, forward_bundle_id, node_path, ordinal, sha256, role from media_refs where id = ${refId} for update`,
      );
      if (locked.sha256) return false;
      await w.tx.execute(
        sql`update media_refs set fetch_state = ${state}, last_error = ${reason.slice(0, 500)}, next_attempt_at = null
             where id = ${refId}`,
      );
      // QQ 缩略图拿不到不影响原件的状态（客户端没缩略图时显示占位，点开照样拉原图）。
      if (locked.role !== QQ_THUMB_ROLE) await updateMessageMedia(w, locked, { state });
      return true;
    });
  }

  /**
   * 服务事件（入群、禁言、戳一戳、设精华、群文件……）：存进会话时间线，按 chat_pts 同步。
   * sourceEventId 是收件箱里的上游事件 id：重新处理同一事件时不会重复写入。
   */
  async addChatEvent(qqAccountId: number, incoming: IncomingChatEvent, sourceEventId?: number): Promise<{ inserted: boolean; chatId: number }> {
    const event = stripNul(incoming);
    const qq = await this.qqAccount(qqAccountId);
    const result = await this.writers.forAccount(qq.accountId).run(async (w) => {
      const chat = await lockOrCreateChat(w.tx, qqAccountId, event.scene, event.peerId, 0);
      if (sourceEventId !== undefined) {
        const dup = await maybeOne(w.tx, sql`select 1 as x from chat_events where source_event_id = ${sourceEventId}`);
        if (dup) return { inserted: false, chatId: chat.id };
      }
      const chatPts = await w.allocChatPts(chat.id);
      const time = new Date(event.time * 1000).toISOString();
      const data = {
        ...(event.data ?? {}),
        ...(event.media ? { media: { ord: 0, state: 'pending', ...(event.media.size ? { size: event.media.size } : {}) } } : {}),
      };
      const row = toChatEvent(
        await one(
          w.tx,
          sql`insert into chat_events (chat_id, kind, time, actor_id, target_id, ref_seq, data, version, source_event_id)
              values (${chat.id}, ${event.kind}, ${time}, ${event.actorId ?? null}, ${event.targetId ?? null}, ${event.refSeq ?? null},
                      ${pgJson(data)}::jsonb, ${chatPts}, ${sourceEventId ?? null})
              returning ${CHAT_EVENT_COLUMNS}`,
        ),
      );
      if (event.media) {
        const m = event.media;
        await w.tx.execute(
          sql`insert into media_refs (chat_id, chat_event_id, ordinal, role, kind, qq_md5, qq_md5_partial, qq_file_uuid, qq_file_id,
                                      url, size, name, mime, fetch_state, locator, sender_uin, time)
              values (${chat.id}, ${row.id}, 0, ${m.role}, ${m.kind}, ${m.qqMd5?.toLowerCase() ?? null}, ${Boolean(m.qqMd5Partial)},
                      ${m.qqFileUuid ?? null}, ${m.qqFileId ?? null}, ${m.url ?? null}, ${m.size ?? null}, ${m.name ?? null},
                      ${m.mime ?? null}, 'pending', ${m.locator ? pgJson(m.locator) : null}::jsonb, ${event.actorId ?? null}, ${time})`,
        );
      }
      w.emit({ type: 'chatEvent', chatId: chat.id, chatPts, event: row });
      return { inserted: true, chatId: chat.id };
    });
    if (result.inserted) for (const peer of event.peers ?? []) await this.upsertPeer(qqAccountId, peer);
    return result;
  }

  /** 表情回应变化：合并进消息的 reactions，作为一次消息变更推送。消息没存档时返回 false。 */
  async applyReaction(qqAccountId: number, scene: Scene, peerId: number, seq: number, change: ReactionChange): Promise<boolean> {
    const qq = await this.qqAccount(qqAccountId);
    return this.writers.forAccount(qq.accountId).run(async (w) => {
      const chat = await maybeOne<{ id: number }>(
        w.tx,
        sql`select id from chats where qq_account_id = ${qqAccountId} and scene = ${scene} and peer_id = ${peerId} for update`,
      );
      if (!chat) return false;
      const current = await maybeOne<{ reactions: Reaction[] | null }>(
        w.tx,
        sql`select reactions from messages where chat_id = ${chat.id} and seq = ${seq} for update`,
      );
      if (!current) return false;
      const reactions = applyReactionChange(Array.isArray(current.reactions) ? current.reactions : [], change);
      const chatPts = await w.allocChatPts(chat.id);
      const message = toMessage(
        await one(
          w.tx,
          sql`update messages set reactions = ${pgJson(reactions)}::jsonb, version = ${chatPts}
               where chat_id = ${chat.id} and seq = ${seq} returning ${MESSAGE_COLUMNS}`,
        ),
      );
      w.emit({ type: 'chatMessage', chatId: chat.id, chatPts, message });
      return true;
    });
  }

  /** "对方正在输入"：只推给在线客户端，不写库。会话还不存在时忽略。 */
  async typing(qqAccountId: number, scene: Scene, peerId: number, userId: number, text: string): Promise<boolean> {
    const qq = await this.qqAccount(qqAccountId);
    const chat = await maybeOne<{ id: number }>(
      this.db,
      sql`select id from chats where qq_account_id = ${qqAccountId} and scene = ${scene} and peer_id = ${peerId}`,
    );
    if (!chat) return false;
    this.writers.publishEphemeral(qq.accountId, { type: 'typing', chatId: chat.id, userId, text });
    return true;
  }

  /** 通话状态变化：只推给在线设备（临时事件，通话本身记在 calls 表里）。 */
  publishCall(qqAccountId: number, call: CallRecord): void {
    void this.qqAccount(qqAccountId).then((qq) => this.writers.publishEphemeral(qq.accountId, { type: 'call', call }));
  }

  /**
   * 原件被清理（present = false）或重新下载回来：把引用它的所有消息里的媒体状态改成 purged / stored，
   * 客户端经 chat_pts 收到（例如提示"原图已清理"）。返回更新的消息数。
   */
  mediaPresenceChanged(sha256: string, present: boolean): Promise<number> {
    return this.patchMediaBySha(sha256, { state: present ? 'stored' : 'purged' });
  }

  /**
   * 更新引用这份内容的所有消息里的媒体信息（例如后补的缩略图、可播放版本、波形），经 chat_pts 推送。
   * 返回更新的消息数。
   */
  /**
   * 缓存一层合并转发的内容。节点里的媒体登记进 media_refs（forward_bundle_id = 这层的 id，node_path = [节点下标]），
   * 照常去重、下载、计入会话占用；下载完成后直接改这层缓存里的媒体信息（合并转发不经 chat_pts 同步，客户端打开时读取）。
   * 同一层已经缓存过就原样返回。nodes 为 null 表示 QQ 那边已经拉不到。
   */
  async storeForward(
    qqAccountId: number,
    chatId: number,
    messageSeq: number,
    path: string,
    incoming: ForwardNodeInput[] | null,
  ): Promise<ForwardBundleRow> {
    const nodes = incoming === null ? null : stripNul(incoming);
    const qq = await this.qqAccount(qqAccountId);
    return this.writers.forAccount(qq.accountId).run(async (w) => {
      const existing = await maybeOne<ForwardBundleRow>(
        w.tx,
        sql`select id, state, nodes from forward_bundles where chat_id = ${chatId} and message_seq = ${messageSeq} and path = ${path}`,
      );
      if (existing && existing.state === 'ready') return existing;
      const stored: StoredForwardNode[] = [];
      const reusedByNode: Map<number, ReusableBlob>[] = [];
      for (const node of nodes ?? []) {
        let segments = node.segments;
        const reused = new Map<number, ReusableBlob>();
        for (const media of node.media) {
          if (!media.qqMd5) continue;
          const hit = await findReusableBlob(w.tx, media.qqMd5, media.size, Boolean(media.qqMd5Partial));
          if (!hit) continue;
          reused.set(media.ord, hit);
          segments = updateMediaInfo(segments, media.ord, reusedMediaPatch(hit));
        }
        reusedByNode.push(reused);
        stored.push({ senderId: node.senderId, senderName: node.senderName, time: node.time, msgId: node.msgId, segments });
      }
      const bundle = await one<ForwardBundleRow>(
        w.tx,
        sql`insert into forward_bundles (chat_id, message_seq, path, state, nodes)
            values (${chatId}, ${messageSeq}, ${path}, ${nodes === null ? 'unavailable' : 'ready'}, ${pgJson(stored)}::jsonb)
            on conflict (chat_id, message_seq, path) do update set state = excluded.state, nodes = excluded.nodes, fetched_at = now()
            returning id, state, nodes`,
      );
      for (const [index, node] of (nodes ?? []).entries()) {
        for (const media of node.media) {
          const hit = reusedByNode[index]!.get(media.ord);
          await w.tx.execute(
            sql`insert into media_refs (chat_id, ordinal, forward_bundle_id, node_path, role, kind, sha256, qq_md5, qq_md5_partial,
                                        qq_file_uuid, qq_resource_id, qq_file_id, url, url_expires_at, size, name, mime, fetch_state,
                                        thumbhash, locator, sender_uin, time)
                values (${chatId}, ${media.ord}, ${String(bundle.id)}, ${sql.raw(`ARRAY[${index}]::int[]`)}, ${media.role}, ${media.kind},
                        ${hit?.sha256 ?? null}, ${media.qqMd5?.toLowerCase() ?? null}, ${Boolean(media.qqMd5Partial)},
                        ${media.qqFileUuid ?? null}, ${media.qqResourceId ?? null}, ${media.qqFileId ?? null}, ${media.url ?? null},
                        ${media.urlExpiresAt ? new Date(media.urlExpiresAt * 1000).toISOString() : null},
                        ${media.size ?? null}, ${media.name ?? null}, ${media.mime ?? null}, ${hit ? 'stored' : 'pending'},
                        ${hit?.thumbhash ?? null}, ${media.locator ? pgJson(media.locator) : null}::jsonb, ${node.senderId},
                        ${new Date(node.time * 1000).toISOString()})`,
          );
          if (hit) await addUsage(w.tx, chatId, hit.sha256);
        }
      }
      return bundle;
    });
  }

  /**
   * 客户端要媒体（RequestMedia）。只认这个账号自己会话里的消息。
   * - thumb：图片排 QQ 缩略图（以前的数据没有缩略图引用时补建一条）；视频、文件排整个文件。
   * - original：排原件。
   * 返回排进队列的引用 id（已在下载 / 已存好的不算）。
   */
  async requestMedia(
    accountId: number,
    refs: readonly { chatId: number; seq: number; ord: number }[],
    what: 'thumb' | 'original' = 'thumb',
  ): Promise<number[]> {
    if (refs.length === 0) return [];
    return this.writers.forAccount(accountId).run(async (w) => {
      const queued: number[] = [];
      for (const r of refs) {
        const original = await maybeOne<MediaRefTarget & { id: number; kind: string; role: string; fetch_state: string; locator: unknown }>(
          w.tx,
          sql`select m.id, m.kind, m.role, m.fetch_state, m.locator, m.chat_id, m.message_seq, m.chat_event_id, m.forward_bundle_id, m.node_path, m.ordinal
                from media_refs m join chats c on c.id = m.chat_id join qq_accounts q on q.id = c.qq_account_id
               where q.account_id = ${accountId} and m.chat_id = ${r.chatId} and m.message_seq = ${r.seq} and m.ordinal = ${r.ord}
                 and m.role <> ${QQ_THUMB_ROLE}
               order by m.id limit 1`,
        );
        if (!original) continue;
        if (what === 'thumb' && original.kind === 'image' && original.role !== 'sticker') {
          const thumb = await maybeOne<{ id: number }>(
            w.tx,
            // 按需的、以前失败或过期的都重新要（链接换新后多半能拿到）。
            sql`update media_refs set fetch_state = 'pending', attempts = 0, next_attempt_at = null, last_error = null, requested_at = now()
                 where chat_id = ${r.chatId} and message_seq = ${r.seq} and ordinal = ${r.ord} and role = ${QQ_THUMB_ROLE}
                   and fetch_state in ('on_demand', 'failed', 'expired')
             returning id`,
          );
          if (thumb) {
            queued.push(thumb.id);
            continue;
          }
          const existing = await maybeOne(
            w.tx,
            sql`select 1 as x from media_refs where chat_id = ${r.chatId} and message_seq = ${r.seq} and ordinal = ${r.ord} and role = ${QQ_THUMB_ROLE}`,
          );
          if (existing || !original.locator) continue;
          // 以前入库的图片没有 QQ 缩略图引用：照原件那条补一条。
          const added = await one<{ id: number }>(
            w.tx,
            sql`insert into media_refs (chat_id, message_seq, ordinal, role, kind, qq_md5, qq_md5_partial, qq_file_uuid,
                                        qq_resource_id, qq_file_id, url, url_expires_at, fetch_state, locator, sender_uin, time)
                select chat_id, message_seq, ordinal, ${QQ_THUMB_ROLE}, 'image', qq_md5, qq_md5_partial, qq_file_uuid,
                       qq_resource_id, qq_file_id, url, url_expires_at, 'pending', locator, sender_uin, time
                  from media_refs where id = ${original.id}
             returning id`,
          );
          queued.push(added.id);
          continue;
        }
        if (!['on_demand', 'failed', 'expired', 'skipped'].includes(original.fetch_state)) continue;
        await w.tx.execute(
          sql`update media_refs set fetch_state = 'pending', attempts = 0, next_attempt_at = null, last_error = null, requested_at = now()
               where id = ${original.id}`,
        );
        await updateMessageMedia(w, original, { state: 'pending' });
        queued.push(original.id);
      }
      return queued;
    });
  }

  /** 消息里某个媒体的当前信息（RequestMedia 拉原图后返回给客户端）。 */
  async messageMedia(chatId: number, seq: number, ord: number): Promise<MediaInfo | null> {
    const row = await maybeOne<{ segments: Segment[] }>(this.db, sql`select segments from messages where chat_id = ${chatId} and seq = ${seq}`);
    for (const seg of row?.segments ?? []) {
      const media = (seg as { media?: MediaInfo }).media;
      if (media && media.ord === ord) return media;
    }
    return null;
  }

  /**
   * 把已有数据按下载规则整理一遍（`cli media:apply-on-demand`）：
   * 1. 不再自动清理原件：去掉以前打的"不需要原件"标记；
   * 2. 还没下载的媒体按规则改为按需（照片原图、群聊视频文件、免打扰群的缩略图和动画表情），
   *    或者排进下载队列（私聊和常用群聊的缩略图、动画表情，私聊视频文件）；
   * 3. 还没下载原图、也没有 QQ 缩略图引用的照片补一条。
   */
  async applyOnDemandToExisting(): Promise<{ unmarked: number; deferred: number; queued: number; thumbs: number }> {
    const quiet = sql`(${sql.join(ON_DEMAND_POLICIES.map((p) => sql`${p}`), sql`, `)})`;
    const unmarked = await this.db.execute(sql`update media_refs set keep_original = null where keep_original = false`);
    // 原件（非 QQ 缩略图）应不应该按需。
    const wantOnDemand = sql`(
      (r.kind = 'image' and r.role <> 'sticker' and r.locator is not null)
      or (r.kind = 'image' and r.role = 'sticker' and c.scene = 'group' and c.notify_policy in ${quiet})
      or (r.kind in ('video', 'file') and c.scene = 'group'))`;
    const targets = await rows<MediaRefTarget & { account_id: number; want: boolean }>(
      this.db,
      sql`select r.chat_id, r.message_seq, r.chat_event_id, r.forward_bundle_id, r.node_path, r.ordinal, q.account_id,
                 ${wantOnDemand} as want
            from media_refs r join chats c on c.id = r.chat_id join qq_accounts q on q.id = c.qq_account_id
           where r.role <> ${QQ_THUMB_ROLE} and r.message_seq is not null and r.kind in ('image', 'video', 'file')
             and ((r.fetch_state in ('pending', 'failed') and ${wantOnDemand}) or (r.fetch_state = 'on_demand' and not ${wantOnDemand}))
           order by q.account_id, r.chat_id, r.message_seq`,
    );
    const byAccount = new Map<number, typeof targets>();
    for (const t of targets) byAccount.set(t.account_id, [...(byAccount.get(t.account_id) ?? []), t]);
    for (const [accountId, list] of byAccount) {
      for (let i = 0; i < list.length; i += 200) {
        await this.writers.forAccount(accountId).run(async (w) => {
          for (const ref of list.slice(i, i + 200)) {
            const state = ref.want ? 'on_demand' : 'pending';
            await w.tx.execute(
              sql`update media_refs set fetch_state = ${state}, attempts = 0, next_attempt_at = null
                   where chat_id = ${ref.chat_id} and message_seq = ${ref.message_seq} and ordinal = ${ref.ordinal}
                     and role <> ${QQ_THUMB_ROLE} and sha256 is null`,
            );
            await updateMessageMedia(w, ref, { state });
          }
        });
      }
    }
    // QQ 缩略图（状态不写进消息）：免打扰群按需，其余排队。
    await this.db.execute(
      sql`update media_refs r set fetch_state = case when c.scene = 'group' and c.notify_policy in ${quiet} then 'on_demand' else 'pending' end,
                 attempts = 0, next_attempt_at = null
            from chats c
           where r.chat_id = c.id and r.role = ${QQ_THUMB_ROLE} and r.sha256 is null and r.fetch_state in ('pending', 'failed', 'on_demand')`,
    );
    const thumbs = await this.db.execute(
      sql`insert into media_refs (chat_id, message_seq, ordinal, role, kind, qq_md5, qq_md5_partial, qq_file_uuid,
                                  qq_resource_id, qq_file_id, url, url_expires_at, fetch_state, locator, sender_uin, time)
          select r.chat_id, r.message_seq, r.ordinal, ${QQ_THUMB_ROLE}, 'image', r.qq_md5, r.qq_md5_partial, r.qq_file_uuid,
                 r.qq_resource_id, r.qq_file_id, r.url, r.url_expires_at,
                 case when c.scene = 'group' and c.notify_policy in ${quiet} then 'on_demand' else 'pending' end, r.locator, r.sender_uin, r.time
            from media_refs r join chats c on c.id = r.chat_id
           where r.kind = 'image' and r.role not in (${QQ_THUMB_ROLE}, 'sticker') and r.message_seq is not null and r.locator is not null
             and r.fetch_state = 'on_demand'
             and not exists (select 1 from media_refs t where t.chat_id = r.chat_id and t.message_seq = r.message_seq
                               and t.ordinal = r.ordinal and t.role = ${QQ_THUMB_ROLE})`,
    );
    const queued = targets.filter((t) => !t.want).length;
    return { unmarked: unmarked.rowCount ?? 0, deferred: targets.length - queued, queued, thumbs: thumbs.rowCount ?? 0 };
  }

  async patchMediaBySha(sha256: string, patch: Partial<Omit<MediaInfo, 'ord'>>): Promise<number> {
    const refs = await rows<MediaRefTarget & { account_id: number }>(
      this.db,
      sql`select r.chat_id, r.message_seq, r.chat_event_id, r.forward_bundle_id, r.node_path, r.ordinal, q.account_id
            from media_refs r join chats c on c.id = r.chat_id join qq_accounts q on q.id = c.qq_account_id
           where r.sha256 = ${sha256} and (r.message_seq is not null or r.chat_event_id is not null or r.forward_bundle_id is not null)
           order by q.account_id, r.chat_id, r.message_seq`,
    );
    if (patch.thumbhash) await this.db.execute(sql`update media_refs set thumbhash = ${patch.thumbhash} where sha256 = ${sha256}`);
    const byAccount = new Map<number, typeof refs>();
    for (const ref of refs) byAccount.set(ref.account_id, [...(byAccount.get(ref.account_id) ?? []), ref]);
    for (const [accountId, list] of byAccount) {
      await this.writers.forAccount(accountId).run(async (w) => {
        for (const ref of list) await updateMessageMedia(w, ref, patch);
      });
    }
    return refs.length;
  }

  private async accountOfRef(refId: number): Promise<number> {
    const ref = await maybeOne<{ account_id: number }>(
      this.db,
      sql`select q.account_id from media_refs r join chats c on c.id = r.chat_id join qq_accounts q on q.id = c.qq_account_id
           where r.id = ${refId}`,
    );
    if (!ref) throw new NotFoundError(`media ref ${refId} not found`);
    return ref.account_id;
  }
}

/**
 * 新会话的初始已读位置：
 * - 实时收到的第一条：之前的历史都算已读，只有这一条未读；
 * - 历史回填或本人发出：全部算已读（导入历史不应该产生未读）。
 */
function initialReadMarker(msg: IncomingMessage, selfUin: number): number {
  if (msg.senderId === selfUin || msg.source === 'backfill') return msg.seq;
  return msg.seq - 1;
}

async function lockOrCreateChat(tx: Tx, qqAccountId: number, scene: Scene, peerId: number, initialRead: number): Promise<LockedChat> {
  await tx.execute(
    sql`insert into chats (qq_account_id, scene, peer_id, dialog_pts, read_inbox_max_seq)
        values (${qqAccountId}, ${scene}, ${peerId}, 0, ${Math.max(0, initialRead)})
        on conflict (qq_account_id, scene, peer_id) do nothing`,
  );
  return one<LockedChat>(
    tx,
    sql`select id, top_seq, read_inbox_max_seq, notify_policy from chats
         where qq_account_id = ${qqAccountId} and scene = ${scene} and peer_id = ${peerId} for update`,
  );
}

async function setReadMarker(tx: Tx, chatId: number, seq: number, selfUin: number): Promise<void> {
  await tx.execute(sql`update chats set read_inbox_max_seq = greatest(read_inbox_max_seq, ${seq}) where id = ${chatId}`);
  await recomputeUnread(tx, chatId, selfUin);
}

/** 更新消息（或服务事件，例如群文件）里媒体的信息，并作为一次会话内变更推送。 */
/** 一个媒体引用出现在哪里：消息、服务事件，或者合并转发缓存里的某个节点。 */
interface MediaRefTarget {
  chat_id: number;
  message_seq: number | null;
  chat_event_id?: number | null;
  forward_bundle_id?: string | null;
  node_path?: number[] | null;
  ordinal: number;
}

async function updateMessageMedia(w: WriteContext, ref: MediaRefTarget, patch: Partial<Omit<MediaInfo, 'ord'>>): Promise<void> {
  if (ref.forward_bundle_id) {
    await updateForwardMedia(w, Number(ref.forward_bundle_id), ref.node_path?.[0] ?? 0, ref.ordinal, patch);
    return;
  }
  if (ref.message_seq === null) {
    if (ref.chat_event_id) await updateEventMedia(w, ref.chat_id, ref.chat_event_id, patch);
    return;
  }
  const chatPts = await w.allocChatPts(ref.chat_id);
  const current = await one<{ segments: Segment[] }>(
    w.tx,
    sql`select segments from messages where chat_id = ${ref.chat_id} and seq = ${ref.message_seq} for update`,
  );
  const segments = updateMediaInfo(current.segments, ref.ordinal, patch);
  const message = toMessage(
    await one(
      w.tx,
      sql`update messages set segments = ${pgJson(segments)}::jsonb, version = ${chatPts}
           where chat_id = ${ref.chat_id} and seq = ${ref.message_seq}
           returning ${MESSAGE_COLUMNS}`,
    ),
  );
  w.emit({ type: 'chatMessage', chatId: ref.chat_id, chatPts, message });
}

/** 合并转发缓存里的媒体：只改缓存，不分配 chat_pts（客户端打开合并转发时重新读取）。 */
async function updateForwardMedia(w: WriteContext, bundleId: number, nodeIndex: number, ord: number, patch: Partial<Omit<MediaInfo, 'ord'>>): Promise<void> {
  const current = await maybeOne<{ nodes: StoredForwardNode[] }>(w.tx, sql`select nodes from forward_bundles where id = ${bundleId} for update`);
  const node = current?.nodes[nodeIndex];
  if (!current || !node) return;
  const nodes = current.nodes.map((n, i) => (i === nodeIndex ? { ...n, segments: updateMediaInfo(n.segments, ord, patch) } : n));
  await w.tx.execute(sql`update forward_bundles set nodes = ${pgJson(nodes)}::jsonb where id = ${bundleId}`);
}

async function updateEventMedia(w: WriteContext, chatId: number, eventId: number, patch: Partial<Omit<MediaInfo, 'ord'>>): Promise<void> {
  const chatPts = await w.allocChatPts(chatId);
  const current = await one<{ data: Record<string, unknown> }>(w.tx, sql`select data from chat_events where id = ${eventId} for update`);
  const media = { ord: 0, state: 'pending', ...((current.data.media as object | undefined) ?? {}), ...patch };
  const event = toChatEvent(
    await one(
      w.tx,
      sql`update chat_events set data = ${pgJson({ ...current.data, media })}::jsonb, version = ${chatPts}
           where id = ${eventId} returning ${CHAT_EVENT_COLUMNS}`,
    ),
  );
  w.emit({ type: 'chatEvent', chatId, chatPts, event });
}

/** 未读数的全量定义（增量规则必须与它保持一致，属性测试会校验）。 */
export async function recomputeUnread(tx: Tx | Db, chatId: number, selfUin: number): Promise<void> {
  await tx.execute(
    sql`update chats c set
          unread_count = (select count(*)::int from messages m
                           where m.chat_id = c.id and m.seq > c.read_inbox_max_seq
                             and m.sender_uin <> ${selfUin} and m.state = 'normal'),
          unread_mentions = (select count(*)::int from messages m
                              where m.chat_id = c.id and m.seq > c.read_inbox_max_seq
                                and m.sender_uin <> ${selfUin} and m.state = 'normal'
                                and (m.flags & ${MENTION_ME}) <> 0 and (m.flags & ${REPLY_TO_ME}) = 0 and not m.mention_seen),
          unread_mention_all = (select count(*)::int from messages m
                              where m.chat_id = c.id and m.seq > c.read_inbox_max_seq
                                and m.sender_uin <> ${selfUin} and m.state = 'normal'
                                and (m.flags & ${MENTION_ALL}) <> 0 and (m.flags & ${MENTION_ME | REPLY_TO_ME}) = 0 and not m.mention_seen),
          unread_replies = (select count(*)::int from messages m
                              where m.chat_id = c.id and m.seq > c.read_inbox_max_seq
                                and m.sender_uin <> ${selfUin} and m.state = 'normal' and (m.flags & ${REPLY_TO_ME}) <> 0 and not m.mention_seen)
        where c.id = ${chatId}`,
  );
}

/**
 * 群的通知策略变了：从免打扰 / 群助手变回正常提醒时，之前按需的 QQ 缩略图和动画表情排进下载队列；
 * 反过来不动（已下的留着）。视频、文件在群里一直按需，原件保留也不受影响。
 */
export async function applyOnDemandPolicy(w: WriteContext, chatId: number, before: string, after: string): Promise<void> {
  const wasQuiet = ON_DEMAND_POLICIES.includes(before);
  const nowQuiet = ON_DEMAND_POLICIES.includes(after);
  if (!wasQuiet || nowQuiet) return;
  const queued = await rows<MediaRefTarget & { role: string }>(
    w.tx,
    sql`update media_refs set fetch_state = 'pending', attempts = 0, next_attempt_at = null
         where chat_id = ${chatId} and fetch_state = 'on_demand' and (role = ${QQ_THUMB_ROLE} or (kind = 'image' and role = 'sticker'))
     returning chat_id, message_seq, chat_event_id, forward_bundle_id, node_path, ordinal, role`,
  );
  for (const ref of queued) if (ref.role !== QQ_THUMB_ROLE) await updateMessageMedia(w, ref, { state: 'pending' });
}
