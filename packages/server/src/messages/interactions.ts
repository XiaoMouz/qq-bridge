// 消息上的小交互：表情回应、"正在输入"、共享媒体列表（docs/design.md 4.8 MessageService / DialogService）。
import type { MediaKind, Reaction, Segment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { maybeOne, one, rows, type Db } from '../db/client.ts';
import type { IngestService } from '../ingest/service.ts';
import { toMessage, MESSAGE_COLUMNS, type MessageRow } from '../sync/rows.ts';
import type { UpstreamHub } from '../upstream/hub.ts';

export class InteractionError extends Error {
  constructor(
    readonly code: 'not_found' | 'unsupported' | 'offline' | 'upstream',
    message: string,
  ) {
    super(message);
  }
}

interface OwnedChat {
  id: number;
  qq_account_id: number;
  scene: 'friend' | 'group' | 'temp';
  peer_id: number;
  peer_uid: string | null;
}

const TYPING_INTERVAL_MS = 4000;

export class MessageInteractions {
  private readonly lastTyping = new Map<number, number>();

  constructor(
    private readonly db: Db,
    private readonly ingest: Pick<IngestService, 'applyReaction'>,
    private readonly upstream: () => Pick<UpstreamHub, 'call' | 'isConnected'> | null,
  ) {}

  /** 加或取消自己的表情回应。QQ 只支持群聊。 */
  async react(accountId: number, chatId: number, seq: number, emojiId: string, add: boolean): Promise<MessageRow> {
    if (!/^\d{1,10}$/.test(emojiId)) throw new InteractionError('unsupported', `invalid emoji id ${emojiId}`);
    const chat = await this.chat(accountId, chatId);
    if (chat.scene !== 'group') throw new InteractionError('unsupported', 'QQ only supports reactions in group chats');
    const current = await maybeOne<{ reactions: Reaction[] | null }>(
      this.db,
      sql`select reactions from messages where chat_id = ${chatId} and seq = ${seq}`,
    );
    if (!current) throw new InteractionError('not_found', `message ${chatId}/${seq} not found`);
    const hub = this.online(chat.qq_account_id);
    try {
      await hub.call(chat.qq_account_id, 'x.react', { chatType: 2, peerUin: String(chat.peer_id), seq: String(seq), emojiId, add });
    } catch (error) {
      throw new InteractionError('upstream', error instanceof Error ? error.message : String(error));
    }
    // 先按本地状态算出新的总数写进去，客户端马上能看到；QQ 的回应通知随后会用准确的总数覆盖。
    const existing = (current.reactions ?? []).find((r) => r.emojiId === emojiId);
    const mine = existing?.me ?? false;
    const count = (existing?.count ?? 0) + (add && !mine ? 1 : !add && mine ? -1 : 0);
    await this.ingest.applyReaction(chat.qq_account_id, chat.scene, chat.peer_id, seq, {
      likes: [{ emojiId, count }],
      byMe: true,
      isAdd: add,
    });
    return toMessage(await one(this.db, sql`select ${MESSAGE_COLUMNS} from messages where chat_id = ${chatId} and seq = ${seq}`));
  }

  /** 让私聊对方看到"正在输入"。每个会话最多每 4 秒发一次；群聊、离线时返回 false。 */
  async typing(accountId: number, chatId: number): Promise<boolean> {
    const chat = await this.chat(accountId, chatId);
    if (chat.scene !== 'friend') return false;
    const hub = this.upstream();
    if (!hub?.isConnected(chat.qq_account_id)) return false;
    const now = Date.now();
    if (now - (this.lastTyping.get(chatId) ?? 0) < TYPING_INTERVAL_MS) return false;
    this.lastTyping.set(chatId, now);
    if (this.lastTyping.size > 1000) this.lastTyping.delete(this.lastTyping.keys().next().value!);
    await hub.call(chat.qq_account_id, 'ob11', { name: 'set_input_status', params: { user_id: String(chat.peer_id), event_type: 1 } });
    return true;
  }

  /** 会话里的共享媒体，按消息倒序。合并转发里的媒体不算（展开转发时另看）。 */
  async sharedMedia(
    accountId: number,
    chatId: number,
    opts: { kinds: MediaKind[]; beforeSeq?: number; limit: number },
  ): Promise<{ items: SharedMediaItem[]; nextBeforeSeq: number }> {
    await this.chat(accountId, chatId);
    const kinds = opts.kinds.length ? opts.kinds : (['image', 'video', 'audio', 'file'] as MediaKind[]);
    // 表情包不算共享媒体（与 Telegram 一致），明确要 sticker 时才带上。
    const role = kinds.includes('sticker') ? sql`r.role <> 'qq_thumb'` : sql`r.role = 'attachment'`;
    // 按消息分页：先取够 limit 条媒体所在的消息，同一条消息里的多个媒体一起返回，翻页不会切开一条消息。
    const refs = await rows<{ message_seq: number; ordinal: number; kind: MediaKind }>(
      this.db,
      sql`with picked as (
            select distinct r.message_seq from media_refs r
             where r.chat_id = ${chatId} and r.message_seq is not null and r.forward_bundle_id is null and ${role}
               and r.kind in (${sql.join(
                 kinds.map((k) => sql`${k}`),
                 sql`, `,
               )})
               ${opts.beforeSeq ? sql`and r.message_seq < ${opts.beforeSeq}` : sql``}
             order by r.message_seq desc limit ${opts.limit})
          select r.message_seq, r.ordinal, r.kind from media_refs r join picked p on p.message_seq = r.message_seq
           where r.chat_id = ${chatId} and r.forward_bundle_id is null and ${role}
             and r.kind in (${sql.join(
               kinds.map((k) => sql`${k}`),
               sql`, `,
             )})
           order by r.message_seq desc, r.ordinal`,
    );
    if (refs.length === 0) return { items: [], nextBeforeSeq: 0 };
    const seqs = [...new Set(refs.map((r) => Number(r.message_seq)))];
    const messages = new Map(
      (
        await rows<{ seq: number; time: Date | string; sender_uin: number; segments: Segment[]; state: string }>(
          this.db,
          sql`select seq, time, sender_uin, segments, state from messages
               where chat_id = ${chatId} and seq in (${sql.join(
                 seqs.map((s) => sql`${s}`),
                 sql`, `,
               )})`,
        )
      ).map((m) => [Number(m.seq), m]),
    );
    const items: SharedMediaItem[] = [];
    for (const ref of refs) {
      const message = messages.get(Number(ref.message_seq));
      if (!message || message.state === 'recalled') continue;
      const segment = message.segments.find((s) => 'media' in s && s.media?.ord === ref.ordinal);
      if (!segment) continue;
      items.push({
        seq: Number(ref.message_seq),
        time: message.time instanceof Date ? message.time : new Date(message.time),
        senderId: Number(message.sender_uin),
        kind: ref.kind,
        segment,
      });
    }
    return { items, nextBeforeSeq: seqs.length < opts.limit ? 0 : Math.min(...seqs) };
  }

  private online(qqAccountId: number): Pick<UpstreamHub, 'call'> {
    const hub = this.upstream();
    if (!hub?.isConnected(qqAccountId)) throw new InteractionError('offline', 'QQ is offline');
    return hub;
  }

  private async chat(accountId: number, chatId: number): Promise<OwnedChat> {
    const chat = await maybeOne<OwnedChat>(
      this.db,
      sql`select c.id, c.qq_account_id, c.scene, c.peer_id, p.uid as peer_uid
            from chats c join qq_accounts q on q.id = c.qq_account_id
            left join peers p on p.qq_account_id = c.qq_account_id and p.peer_id = c.peer_id
                             and p.kind = case c.scene when 'group' then 'group' else 'user' end
           where c.id = ${chatId} and q.account_id = ${accountId}`,
    );
    if (!chat) throw new InteractionError('not_found', `chat ${chatId} not found`);
    return chat;
  }
}

export interface SharedMediaItem {
  seq: number;
  time: Date;
  senderId: number;
  kind: MediaKind;
  segment: Segment;
}
