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
import type { MediaService } from '../media/service.ts';
import type { CallRecord } from '../calls/service.ts';
import sharp from 'sharp';

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
  /** 发送者：通知扩展据此做成「通讯通知」（显示发送者头像，右下角是 App 图标）。 */
  senderId: number;
  senderName: string;
  /** 群聊的群名（私聊为空）。 */
  groupName: string;
  qqAccountId: number;
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
      /** 读头像原图（缩成小图放进推送里）；没有时通知不带头像。 */
      media?: Pick<MediaService, 'getBlob' | 'openBlob'>;
      /** 这台设备现在连着 Subscribe（App 在前台）：来电由 App 自己显示，不推。 */
      isOnline?: (deviceId: number) => boolean;
    } = {},
  ) {}

  private readonly avatarCache = new Map<string, string>();

  /** 发送者头像缩成 64px 的 JPEG（base64，约 1–2 KB），通知扩展直接用，不用联网。拿不到返回 null。 */
  private async avatarThumb(qqAccountId: number, userId: number): Promise<string | null> {
    if (!this.opts.media) return null;
    const row = await maybeOne<{ avatar_sha256: string | null }>(
      this.db,
      sql`select avatar_sha256 from peers where qq_account_id = ${qqAccountId} and kind = 'user' and peer_id = ${userId}`,
    );
    const sha = row?.avatar_sha256;
    if (!sha) return null;
    const hit = this.avatarCache.get(sha);
    if (hit) return hit;
    try {
      const blob = await this.opts.media.getBlob(sha);
      if (!blob || blob.state !== 'present') return null;
      const chunks: Buffer[] = [];
      for await (const c of await this.opts.media.openBlob(blob)) chunks.push(c as Buffer);
      const jpeg = await sharp(Buffer.concat(chunks), { animated: false, failOn: 'none' }).resize(64, 64, { fit: 'cover' }).jpeg({ quality: 60 }).toBuffer();
      const b64 = jpeg.toString('base64');
      if (b64.length > 2600) return null; // APNs 负载上限 4 KB
      this.avatarCache.set(sha, b64);
      if (this.avatarCache.size > 500) this.avatarCache.delete(this.avatarCache.keys().next().value!);
      return b64;
    } catch {
      return null;
    }
  }

  /** 已经推过振铃的来电（同一通只推一次）。 */
  private readonly ringingPushed = new Set<string>();

  /** 通话状态变了：来电振铃时推一条（时效性、带铃声）；没接就结束时用同一个 collapse id 换成「未接来电」。 */
  onCall(accountId: number, call: CallRecord): void {
    void this.notifyCall(accountId, call).catch((error: unknown) => this.opts.logger?.warn({ err: error, callId: call.callId }, 'call push failed'));
  }

  async notifyCall(accountId: number, call: CallRecord): Promise<number> {
    if (!call.incoming) return 0;
    const ringing = call.phase === 'ringing';
    // 振铃时等插件认出来电的人（QQ 号、昵称）再推：最早的那次状态里还没有，推出去就没有名字。
    if (ringing && call.peerUin === null) return 0;
    const missed = call.phase === 'ended' && !call.connectedAt && this.ringingPushed.has(call.callId);
    if (!(ringing && !this.ringingPushed.has(call.callId)) && !missed) return 0;
    const kind = call.media === 'video' ? '视频' : '语音';
    const chat = call.groupId !== null
      ? await maybeOne<{ id: number; notify_policy: string; name: string | null }>(
          this.db,
          sql`select c.id, c.notify_policy, p.name from chats c
                left join peers p on p.qq_account_id = c.qq_account_id and p.kind = 'group' and p.peer_id = c.peer_id
               where c.qq_account_id = ${call.qqAccountId} and c.scene = 'group' and c.peer_id = ${call.groupId}`,
        )
      : call.peerUin
        ? await maybeOne<{ id: number; notify_policy: string; name: string | null }>(
            this.db,
            sql`select id, notify_policy, null as name from chats where qq_account_id = ${call.qqAccountId} and scene = 'friend' and peer_id = ${call.peerUin}`,
          )
        : null;
    // 群语音：跟着群的消息设置走——免打扰、收进群助手、只提醒 @我 的群不推（在 App 里手动加入）。
    if (call.groupId !== null && (!chat || [...QUIET_POLICIES, 'mentions'].includes(chat.notify_policy))) return 0;
    if (ringing) {
      this.ringingPushed.add(call.callId);
      if (this.ringingPushed.size > 200) this.ringingPushed.delete(this.ringingPushed.values().next().value!);
    } else {
      this.ringingPushed.delete(call.callId);
    }
    // 来电人的名字：备注 > 昵称 > 插件给的昵称 > 号码。
    const person = call.peerUin
      ? await maybeOne<{ remark: string | null; name: string | null }>(
          this.db,
          sql`select remark, name from peers where qq_account_id = ${call.qqAccountId} and kind = 'user' and peer_id = ${call.peerUin}`,
        )
      : null;
    const callerName = person?.remark || person?.name || call.peerName || (call.peerUin ? String(call.peerUin) : 'QQ');
    const groupName = call.groupId !== null ? (chat?.name || String(call.groupId)) : null;
    const title = groupName ?? callerName;
    const body = ringing
      ? groupName ? `${callerName} 邀请你加入群${kind}通话` : `邀请你${kind}通话`
      : groupName ? `${callerName} 发起的群${kind}通话已结束` : `未接${kind}通话`;
    const devices = await rows<{ id: number; platform: string; apns_token: string | null; apns_voip_token: string | null; apns_env: string | null }>(
      this.db,
      sql`select id, platform, apns_token, apns_voip_token, apns_env from devices
           where account_id = ${accountId} and revoked_at is null and (apns_token is not null or apns_voip_token is not null)`,
    );
    const avatar = devices.length > 0 && call.peerUin ? await this.avatarThumb(call.qqAccountId, call.peerUin) : null;
    let sent = 0;
    for (const d of devices) {
      const env: ApnsEnv = d.apns_env === 'sandbox' ? 'sandbox' : 'production';
      // iOS 在前台才持续 Subscribe；Mac 后台也保持连接，不能据此跳过系统来电。
      if (ringing && d.platform !== 'macos' && this.opts.isOnline?.(d.id)) continue;
      if (ringing && d.apns_voip_token) {
        // VoIP 推送：App 收到后交给 CallKit（系统来电界面，锁屏也能接）。
        const result = await this.sender.send({
          token: d.apns_voip_token,
          platform: d.platform,
          env,
          pushType: 'voip',
          priority: 10,
          ttlSec: 30,
          payload: {
            call: {
              id: call.callId,
              callerName,
              callerUin: call.peerUin,
              media: call.media,
              ...(call.groupId !== null ? { groupId: call.groupId, groupName } : {}),
              ...(chat ? { chatId: chat.id } : {}),
            },
          },
        });
        if (result.ok) {
          sent++;
          continue;
        }
        if (result.invalidToken) {
          await this.db.execute(sql`update devices set apns_voip_token = null where id = ${d.id} and apns_voip_token = ${d.apns_voip_token}`);
        }
      }
      if (!d.apns_token) continue;
      // 普通通知（没有 VoIP 令牌时的来电、未接来电）：带上来电人的头像，通知扩展做成通讯通知。
      const result = await this.sender.send({
        token: d.apns_token,
        platform: d.platform,
        env,
        collapseId: `call-${call.callId}`,
        ttlSec: ringing ? 60 : 24 * 3600,
        payload: {
          aps: {
            alert: { title, body },
            ...(ringing ? { sound: 'default', 'interruption-level': 'time-sensitive' } : {}),
            'thread-id': chat ? `chat-${chat.id}` : 'calls',
            'mutable-content': 1,
          },
          ...(chat ? { chatId: chat.id } : {}),
          callId: call.callId,
          ...(call.peerUin ? { sender: { id: call.peerUin, name: callerName, ...(avatar ? { avatar } : {}) } } : {}),
          ...(groupName ? { group: groupName } : {}),
        },
      });
      if (result.ok) sent++;
      else if (result.invalidToken) {
        await this.db.execute(sql`update devices set apns_token = null where id = ${d.id} and apns_token = ${d.apns_token}`);
      }
    }
    return sent;
  }

  /** 入库后调用；出错只记日志，不影响入库。 */
  onNewMessage(event: NewMessageEvent): void {
    void this.notify(event).catch((error: unknown) => this.opts.logger?.warn({ err: error, ...event }, 'push failed'));
  }

  async notify(event: NewMessageEvent): Promise<number> {
    const n = await this.build(event);
    if (!n) return 0;
    const devices = await rows<{ id: number; platform: string; apns_token: string; apns_env: string | null }>(
      this.db,
      sql`select id, platform, apns_token, apns_env from devices
           where account_id = ${event.accountId} and revoked_at is null and apns_token is not null`,
    );
    const avatar = devices.length > 0 ? await this.avatarThumb(n.qqAccountId, n.senderId) : null;
    let sent = 0;
    for (const d of devices) {
      const env: ApnsEnv = d.apns_env === 'sandbox' ? 'sandbox' : 'production';
      const result = await this.sender.send({
        token: d.apns_token,
        platform: d.platform,
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
          sender: { id: n.senderId, name: n.senderName, ...(avatar ? { avatar } : {}) },
          ...(n.groupName ? { group: n.groupName } : {}),
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
    return {
      title,
      body: tag + body,
      badge: await this.badge(event.accountId),
      chatId: event.chatId,
      seq: event.seq,
      senderId: Number(m.sender_uin),
      senderName: sender ?? title,
      groupName: group ? title : '',
      qqAccountId: Number(m.qq_account_id),
    };
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
