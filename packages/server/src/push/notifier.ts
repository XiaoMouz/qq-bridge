// 新消息推送：决定一条消息要不要推、推给哪些设备、通知里写什么，再交给 APNs。
// 规则（与 App 里的通知设置一致）：
// - 自己发的、补历史拉回来的、太旧的（QQ 重新上线时补收的离线消息超过 10 分钟）不推。
// - 免打扰、收进群助手的会话不推。
// - "只提醒 @我和回复我"：只推 @我、回复我，以及打开了"@全体成员 提醒"时的 @全体成员。
// - 其余（默认 / 全部提醒）都推。
// 角标 = 会提醒的会话的未读数，加上其他会话（免打扰、群助手、只提醒 @我）里的 @我 和回复我；@全体成员 不单独算。
import { MessageFlag, plainText, type Segment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, one, rows, type Db } from '../db/client.ts';
import type { ApnsEnv, PushSender } from './apns.ts';

const { mentionsMe: MENTION_ME, mentionAll: MENTION_ALL, replyToMe: REPLY_TO_ME } = MessageFlag;
const QUIET_POLICIES = ['muted', 'archived'];
const MAX_AGE_SEC = 10 * 60;
const MAX_BODY = 180;

export interface NewMessageEvent {
  accountId: number;
  chatId: number;
  seq: number;
}

interface MessageInfo {
  scene: string;
  peer_id: number;
  qq_account_id: number;
  notify_policy: string;
  mention_all_notify: boolean;
  uin: number;
  sender_uin: number;
  sender_name: string | null;
  segments: Segment[];
  flags: number;
  time: Date | string;
  source: string;
  state: string;
  title: string | null;
}

export interface Notification {
  title: string;
  body: string;
  badge: number;
  chatId: number;
  seq: number;
}

export class PushNotifier {
  constructor(
    private readonly db: Db,
    private readonly sender: PushSender,
    private readonly opts: {
      /** false：通知里不写消息内容，只写"新消息"（内容不经过 Apple）。 */
      showPreview?: boolean;
      logger?: Logger;
      now?: () => number;
    } = {},
  ) {}

  /** 入库后调用；出错只记日志，不影响入库。 */
  onNewMessage(event: NewMessageEvent): void {
    void this.notify(event).catch((error: unknown) => this.opts.logger?.warn({ err: error, ...event }, 'push failed'));
  }

  async notify(event: NewMessageEvent): Promise<number> {
    const n = await this.build(event);
    if (!n) return 0;
    const devices = await rows<{ id: number; apns_token: string; apns_env: string | null }>(
      this.db,
      sql`select id, apns_token, apns_env from devices
           where account_id = ${event.accountId} and revoked_at is null and apns_token is not null`,
    );
    let sent = 0;
    for (const d of devices) {
      const env: ApnsEnv = d.apns_env === 'sandbox' ? 'sandbox' : 'production';
      const result = await this.sender.send({
        token: d.apns_token,
        env,
        ttlSec: 24 * 3600,
        payload: {
          aps: {
            alert: { title: n.title, body: n.body },
            sound: 'default',
            badge: n.badge,
            'thread-id': `chat-${n.chatId}`,
            'mutable-content': 1,
          },
          chatId: n.chatId,
          seq: n.seq,
        },
      });
      if (result.ok) sent++;
      else if (result.invalidToken) {
        await this.db.execute(sql`update devices set apns_token = null where id = ${d.id} and apns_token = ${d.apns_token}`);
      }
    }
    return sent;
  }

  /** 这条消息的通知内容；不该推时返回 null。 */
  async build(event: NewMessageEvent): Promise<Notification | null> {
    const m = await maybeOne<MessageInfo>(
      this.db,
      sql`select c.scene, c.peer_id, c.qq_account_id, c.notify_policy, c.mention_all_notify, q.uin,
                 m.sender_uin, m.sender_name, m.segments, m.flags, m.time, m.source, m.state,
                 coalesce(nullif(p.remark, ''), nullif(p.name, '')) as title
            from messages m
            join chats c on c.id = m.chat_id
            join qq_accounts q on q.id = c.qq_account_id
            left join peers p on p.qq_account_id = c.qq_account_id and p.peer_id = c.peer_id
                             and p.kind = case when c.scene = 'group' then 'group' else 'user' end
           where m.chat_id = ${event.chatId} and m.seq = ${event.seq} and q.account_id = ${event.accountId}`,
    );
    if (!m) return null;
    if (m.sender_uin === m.uin || m.source !== 'realtime' || m.state !== 'normal') return null;
    const now = this.opts.now?.() ?? Date.now();
    if (now - new Date(m.time).getTime() > MAX_AGE_SEC * 1000) return null;

    const mentionMe = (m.flags & MENTION_ME) !== 0;
    const replyMe = (m.flags & REPLY_TO_ME) !== 0;
    const mentionAll = (m.flags & MENTION_ALL) !== 0 && m.mention_all_notify;
    if (QUIET_POLICIES.includes(m.notify_policy)) return null;
    if (m.notify_policy === 'mentions' && !mentionMe && !replyMe && !mentionAll) return null;

    const group = m.scene === 'group';
    const sender = group ? await this.memberName(m) : null;
    const title = m.title ?? String(m.peer_id);
    let body = this.opts.showPreview === false ? '新消息' : plainText(m.segments).replace(/\s+/g, ' ').trim() || '[消息]';
    if (body.length > MAX_BODY) body = `${body.slice(0, MAX_BODY)}…`;
    if (sender) body = `${sender}: ${body}`;
    const tag = replyMe ? '[有人回复我] ' : mentionMe ? '[有人@我] ' : mentionAll ? '[@全体成员] ' : '';
    return { title, body: tag + body, badge: await this.badge(event.accountId), chatId: event.chatId, seq: event.seq };
  }

  /** 群名片 > 消息里带的名字 > 昵称 > 号码。 */
  private async memberName(m: MessageInfo): Promise<string> {
    const member = await maybeOne<{ card: string | null; nickname: string | null }>(
      this.db,
      sql`select card, nickname from group_members where qq_account_id = ${m.qq_account_id} and group_id = ${m.peer_id} and user_id = ${m.sender_uin}`,
    );
    return member?.card || m.sender_name || member?.nickname || String(m.sender_uin);
  }

  private async badge(accountId: number): Promise<number> {
    const row = await one<{ n: number }>(
      this.db,
      sql`select coalesce(sum(case when c.notify_policy in ('muted', 'archived', 'mentions')
                                    then c.unread_mentions + c.unread_replies else c.unread_count end), 0)::int as n
            from chats c join qq_accounts q on q.id = c.qq_account_id
           where q.account_id = ${accountId}`,
    );
    return row.n;
  }
}
