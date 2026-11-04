// 展开合并转发（MessageService.GetForward）：第一次打开时经插件向 QQ 拉取（x.forward → getMultiMsg），
// 映射成规范化消息段后缓存进 forward_bundles，节点里的媒体照常去重、下载；之后直接读缓存。
// 嵌套的合并转发按 path 逐层展开：上一层第 i 个节点的 msgId 就是下一层的 parentMsgId，rootMsgId 始终是会话里那条消息。
import type { Segment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { maybeOne, type Db } from '../db/client.ts';
import type { ForwardBundleRow, ForwardNodeInput, IngestService, StoredForwardNode } from '../ingest/service.ts';
import type { UpstreamHub } from '../upstream/hub.ts';
import { mapRawMessage } from '../upstream/napcat/map.ts';
import type { NtRawMessage } from '../upstream/napcat/types.ts';
import { InteractionError } from './interactions.ts';

/** 拉不到的合并转发多久之后再试一次。 */
const UNAVAILABLE_RETRY_MS = 24 * 3600_000;
/** 从手机备份导入、节点图片拿不到的：多久向 QQ 再要一次（拉到了就换成 QQ 的，图片可以下载）。 */
const BACKUP_RETRY_MS = 6 * 3600_000;

/**
 * 从手机备份导入的一层（imports/apply.ts）：节点没有 NT msgId；手机备份里大多没存节点图片，媒体是 expired。
 * 2026-11-04 实测：QQ 按 resid 还能拉到约三个月内的合并转发（带下载链接），更早的拉不到（FetchForwardMsg 报 unexpected end of file）。
 * 所以这种缓存不当成「已就绪」挡住向 QQ 拉取。
 */
function backupWithMissingMedia(nodes: StoredForwardNode[]): boolean {
  return nodes.length > 0 && nodes.every((n) => !n.msgId)
    && nodes.some((n) => n.segments.some((s) => 'media' in s && (s as { media?: { state?: string } }).media?.state === 'expired'));
}

export class ForwardService {
  constructor(
    private readonly db: Db,
    private readonly ingest: Pick<IngestService, 'storeForward' | 'touchForward'>,
    private readonly upstream: () => Pick<UpstreamHub, 'call' | 'isConnected'> | null,
  ) {}

  async get(accountId: number, chatId: number, seq: number, path: number[]): Promise<ForwardBundleRow> {
    const message = await maybeOne<{
      qq_account_id: number;
      uin: number;
      scene: string;
      peer_id: number;
      peer_uid: string | null;
      qq_msg_id: string | null;
      segments: Segment[];
    }>(
      this.db,
      sql`select c.qq_account_id, q.uin, c.scene, c.peer_id, m.raw->>'peerUid' as peer_uid, m.qq_msg_id, m.segments
            from messages m join chats c on c.id = m.chat_id join qq_accounts q on q.id = c.qq_account_id
           where c.id = ${chatId} and m.seq = ${seq} and q.account_id = ${accountId}`,
    );
    if (!message) throw new InteractionError('not_found', `message ${chatId}/${seq} not found`);
    if (!message.segments.some((s) => s.type === 'forward')) throw new InteractionError('unsupported', 'message has no forward');
    return this.level(message, chatId, seq, path);
  }

  private async level(
    message: { qq_account_id: number; uin: number; scene: string; peer_id: number; peer_uid: string | null; qq_msg_id: string | null },
    chatId: number,
    seq: number,
    path: number[],
  ): Promise<ForwardBundleRow> {
    const key = path.join('.');
    const cached = await maybeOne<ForwardBundleRow & { fetched_at: Date | string }>(
      this.db,
      sql`select id, state, nodes, fetched_at from forward_bundles where chat_id = ${chatId} and message_seq = ${seq} and path = ${key}`,
    );
    const age = cached ? Date.now() - new Date(cached.fetched_at).getTime() : Infinity;
    const fromBackup = cached?.state === 'ready' && backupWithMissingMedia(cached.nodes);
    const fresh = cached && (fromBackup ? age < BACKUP_RETRY_MS : cached.state === 'ready' || age < UNAVAILABLE_RETRY_MS);
    if (cached && fresh) return { id: cached.id, state: cached.state, nodes: cached.nodes };

    let parentMsgId = message.qq_msg_id;
    let resId: string | undefined;
    if (path.length > 0) {
      const parent = await this.level(message, chatId, seq, path.slice(0, -1));
      const node = parent.nodes[path[path.length - 1]!];
      const nested = node?.segments.find((s): s is Extract<Segment, { type: 'forward' }> => s.type === 'forward');
      if (!node || !nested) throw new InteractionError('not_found', `no nested forward at ${key}`);
      parentMsgId = node.msgId;
      resId = nested.forwardId;
    } else {
      const row = await maybeOne<{ segments: Segment[] }>(this.db, sql`select segments from messages where chat_id = ${chatId} and seq = ${seq}`);
      resId = row?.segments.find((s): s is Extract<Segment, { type: 'forward' }> => s.type === 'forward')?.forwardId;
    }
    if ((!message.qq_msg_id || !parentMsgId) && !resId) throw new InteractionError('unsupported', 'message has no QQ id');

    const hub = this.upstream();
    if (!hub?.isConnected(message.qq_account_id)) {
      if (cached) return { id: cached.id, state: cached.state, nodes: cached.nodes };
      throw new InteractionError('offline', 'QQ is offline');
    }
    let raws: NtRawMessage[] = [];
    if (message.qq_msg_id && parentMsgId) {
      const res = await hub
        .call<{ result?: number; messages?: NtRawMessage[] }>(message.qq_account_id, 'x.forward', {
          chatType: message.scene === 'group' ? 2 : 1,
          peerUin: String(message.peer_id),
          ...(message.peer_uid ? { peerUid: message.peer_uid } : {}),
          rootMsgId: message.qq_msg_id,
          parentMsgId,
        })
        .catch(() => null);
      raws = res?.result ? [] : (res?.messages ?? []);
    }
    // 卡片形式的聊天记录（com.tencent.multimsg）和拉不到的嵌套记录：按 resid 直接拉。
    if (raws.length === 0 && resId) {
      const res = await hub.call<{ messages?: NtRawMessage[] }>(message.qq_account_id, 'x.forward_by_resid', { resId }).catch(() => null);
      raws = res?.messages ?? [];
    }
    const nodes: ForwardNodeInput[] = [];
    for (const raw of raws) {
      const action = mapRawMessage(raw, { selfUin: message.uin, source: 'backfill' });
      if (action.type !== 'message') continue;
      const r = raw as NtRawMessage & { sendMemberName?: string; sendNickName?: string; sendRemarkName?: string };
      nodes.push({
        senderId: action.message.senderId,
        senderName: r.sendMemberName || r.sendRemarkName || r.sendNickName || String(action.message.senderId),
        time: action.message.time,
        msgId: String(raw.msgId ?? ''),
        segments: action.message.segments,
        media: action.message.media,
      });
    }
    if (fromBackup) {
      // QQ 也拉不到：留着备份里的内容（文字都在），记下这次尝试的时间。
      if (!nodes.length) return this.ingest.touchForward(cached!.id);
      return this.ingest.storeForward(message.qq_account_id, chatId, seq, key, nodes, { replace: true });
    }
    return this.ingest.storeForward(message.qq_account_id, chatId, seq, key, nodes.length ? nodes : null);
  }
}
