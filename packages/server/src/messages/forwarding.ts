// 转发（MessageService.ForwardMessages）：把存档里的消息变成外发消息，逐条发，或打包成 QQ 的"聊天记录"（合并转发）。
// 媒体用服务端已有的内容（按 sha256 引用，不重新上传）；原图还没下载的先当场从 QQ 拉，拉不到用缩略图，再不行换成文字。
import { randomInt } from 'node:crypto';
import { markdownText, type ForwardNode, type MediaInfo, type OutgoingSegment, type Segment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { maybeOne, rows, type Db } from '../db/client.ts';
import type { IngestService } from '../ingest/service.ts';
import type { OutboxService } from '../outbox/service.ts';
import { sqlList, type OutboxRow } from '../sync/rows.ts';

export const MAX_FORWARD_MESSAGES = 100;

export class ForwardError extends Error {
  constructor(
    readonly code: 'invalid' | 'not_found',
    message: string,
  ) {
    super(message);
  }
}

interface SourceMessage {
  seq: number;
  sender_uin: number;
  segments: Segment[];
}

export class MessageForwarder {
  constructor(
    private readonly db: Db,
    private readonly ingest: IngestService,
    private readonly outbox: OutboxService,
    /** 马上下载某个媒体引用（看大图那条路径）；没有下载器时为 null。 */
    private readonly fetchNow: () => ((refId: number) => Promise<void>) | null,
  ) {}

  async forward(
    accountId: number,
    deviceId: number | null,
    req: { fromChatId: number; seqs: number[]; toChatIds: number[]; bundle: boolean },
  ): Promise<OutboxRow[]> {
    const seqs = [...new Set(req.seqs)].sort((a, b) => a - b);
    const targets = [...new Set(req.toChatIds)];
    if (seqs.length === 0 || seqs.length > MAX_FORWARD_MESSAGES) throw new ForwardError('invalid', `forward 1–${MAX_FORWARD_MESSAGES} messages`);
    if (targets.length === 0 || targets.length > 20) throw new ForwardError('invalid', 'forward to 1–20 chats');
    const chat = await maybeOne<{ scene: string; peer_id: number; qq_account_id: number }>(
      this.db,
      sql`select c.scene, c.peer_id, c.qq_account_id from chats c join qq_accounts q on q.id = c.qq_account_id
           where c.id = ${req.fromChatId} and q.account_id = ${accountId}`,
    );
    if (!chat) throw new ForwardError('not_found', `chat ${req.fromChatId} not found`);
    const messages = await rows<SourceMessage>(
      this.db,
      sql`select seq, sender_uin, segments from messages
           where chat_id = ${req.fromChatId} and seq in ${sqlList(seqs)} and state = 'normal' order by seq`,
    );
    if (messages.length === 0) throw new ForwardError('not_found', 'no messages to forward');

    // 先把每条消息转成外发消息段（媒体在这里准备好，所有目标共用）。
    const converted: { msg: SourceMessage; parts: OutgoingSegment[][] }[] = [];
    for (const msg of messages) {
      converted.push({ msg, parts: await this.convert(accountId, req.fromChatId, msg) });
    }

    const batches: OutgoingSegment[][] = [];
    if (req.bundle) {
      const names = await this.senderNames(chat, messages);
      const nodes: ForwardNode[] = [];
      for (const { msg, parts } of converted) {
        for (const segments of parts) {
          if (segments.length === 0) continue;
          nodes.push({ userId: msg.sender_uin, nickname: names.get(msg.sender_uin) ?? String(msg.sender_uin), segments: forNode(segments) });
        }
      }
      if (nodes.length === 0) throw new ForwardError('invalid', 'nothing to forward');
      batches.push([{ type: 'forward', nodes }]);
    } else {
      for (const { parts } of converted) for (const segments of parts) if (segments.length > 0) batches.push(segments);
    }

    const entries: OutboxRow[] = [];
    for (const chatId of targets) {
      for (const segments of batches) {
        entries.push(
          await this.outbox.enqueue(accountId, deviceId, { chatId, clientRandomId: randomInt(1, 2 ** 47), message: { segments } }),
        );
      }
    }
    return entries;
  }

  /** 一条存档消息 → 一条或几条外发消息（语音、视频、文件要单独成条）。 */
  private async convert(accountId: number, chatId: number, msg: SourceMessage): Promise<OutgoingSegment[][]> {
    const out: OutgoingSegment[][] = [];
    let current: OutgoingSegment[] = [];
    const text = (t: string) => {
      if (!t) return;
      const last = current[current.length - 1];
      if (last?.type === 'text') last.text += t;
      else current.push({ type: 'text', text: t });
    };
    const alone = (seg: OutgoingSegment) => {
      if (current.length > 0) out.push(current);
      out.push([seg]);
      current = [];
    };
    for (const seg of msg.segments) {
      switch (seg.type) {
        case 'text':
          text(seg.text);
          break;
        // 转发出去的 @ 只当文字，不会再提醒到人。
        case 'mention':
          text(`@${seg.name ?? seg.userId} `);
          break;
        case 'mention_all':
          text('@全体成员 ');
          break;
        case 'face':
          current.push({ type: 'face', faceId: seg.faceId });
          break;
        case 'reply':
          break;
        case 'image': {
          const sha = await this.mediaSha(accountId, chatId, msg.seq, seg.media, true);
          if (sha) current.push({ type: 'image', sha256: sha, ...(seg.subType === 'sticker' ? { sticker: true } : {}), ...(seg.summary ? { summary: seg.summary } : {}) });
          else text(seg.subType === 'sticker' ? '[动画表情]' : '[图片]');
          break;
        }
        case 'market_face': {
          const sha = seg.media ? await this.mediaSha(accountId, chatId, msg.seq, seg.media, true) : null;
          if (sha) current.push({ type: 'image', sha256: sha, sticker: true, ...(seg.summary ? { summary: seg.summary } : {}) });
          else text(seg.summary ?? '[表情]');
          break;
        }
        case 'record': {
          const sha = await this.mediaSha(accountId, chatId, msg.seq, seg.media, false);
          if (sha) alone({ type: 'record', sha256: sha, ...(seg.durationSec ? { durationSec: seg.durationSec } : {}) });
          else text('[语音]');
          break;
        }
        case 'video': {
          const sha = await this.mediaSha(accountId, chatId, msg.seq, seg.media, false);
          if (sha) alone({ type: 'video', sha256: sha });
          else text('[视频]');
          break;
        }
        case 'file': {
          const sha = await this.mediaSha(accountId, chatId, msg.seq, seg.media, false);
          if (sha) alone({ type: 'file', sha256: sha, name: seg.name });
          else text(`[文件] ${seg.name}`);
          break;
        }
        case 'forward':
          text(`[聊天记录] ${seg.title ?? ''}`.trim());
          break;
        case 'light_app':
          text(`[卡片] ${seg.appName}`);
          break;
        case 'xml':
          text('[卡片]');
          break;
        case 'markdown':
          text(markdownText(seg.content));
          break;
        case 'unknown':
          break;
      }
    }
    if (current.length > 0) out.push(current);
    return out;
  }

  /**
   * 转发用的媒体 sha256：服务端已有原件就用原件；按需 / 已清理的先当场从 QQ 拉；
   * 拉不到时图片退回缩略图（canUseThumb），其余返回 null。
   */
  private async mediaSha(accountId: number, chatId: number, seq: number, media: MediaInfo, canUseThumb: boolean): Promise<string | null> {
    if (media.sha256 && (await this.present(media.sha256))) return media.sha256;
    const fetchNow = this.fetchNow();
    if (fetchNow) {
      const queued = await this.ingest.requestMedia(accountId, [{ chatId, seq, ord: media.ord }], 'original');
      await Promise.all(queued.map((id) => fetchNow(id)));
      if (media.sha256 && (await this.present(media.sha256))) return media.sha256; // 已清理的原件拉回来了
      const fresh = await this.ingest.messageMedia(chatId, seq, media.ord);
      if (fresh?.sha256 && fresh.state === 'stored' && (await this.present(fresh.sha256))) return fresh.sha256;
      if (canUseThumb && fresh?.thumbSha256 && (await this.present(fresh.thumbSha256))) return fresh.thumbSha256;
    }
    if (canUseThumb && media.thumbSha256 && (await this.present(media.thumbSha256))) return media.thumbSha256;
    return null;
  }

  private async present(sha256: string): Promise<boolean> {
    const row = await maybeOne(this.db, sql`select 1 as x from blobs where sha256 = ${sha256} and state = 'present'`);
    return row !== null;
  }

  /** 打包转发里显示的名字：群里用群名片 > 昵称，其余用备注 > 昵称；自己用自己的昵称。 */
  private async senderNames(chat: { scene: string; peer_id: number; qq_account_id: number }, messages: SourceMessage[]): Promise<Map<number, string>> {
    const uins = [...new Set(messages.map((m) => m.sender_uin))];
    const names = new Map<number, string>();
    for (const p of await rows<{ peer_id: number; name: string | null; remark: string | null }>(
      this.db,
      sql`select peer_id, name, remark from peers where qq_account_id = ${chat.qq_account_id} and kind = 'user' and peer_id in ${sqlList(uins)}`,
    )) {
      const n = p.remark || p.name;
      if (n) names.set(p.peer_id, n);
    }
    if (chat.scene === 'group') {
      for (const m of await rows<{ user_id: number; card: string | null; nickname: string | null }>(
        this.db,
        sql`select user_id, card, nickname from group_members
             where qq_account_id = ${chat.qq_account_id} and group_id = ${chat.peer_id} and user_id in ${sqlList(uins)}`,
      )) {
        const n = m.card || m.nickname;
        if (n) names.set(m.user_id, n);
      }
    }
    const self = await maybeOne<{ uin: number; nickname: string | null }>(this.db, sql`select uin, nickname from qq_accounts where id = ${chat.qq_account_id}`);
    if (self?.nickname) names.set(self.uin, self.nickname);
    return names;
  }
}

/** 合并转发的节点里不放语音（QQ 的聊天记录里放不了语音），换成文字。 */
function forNode(segments: OutgoingSegment[]): OutgoingSegment[] {
  return segments.map((s) => (s.type === 'record' ? { type: 'text', text: '[语音]' } : s));
}
