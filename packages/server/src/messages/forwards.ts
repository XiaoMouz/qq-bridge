// 展开合并转发（MessageService.GetForward）：第一次打开时经插件向 QQ 拉取（x.forward → getMultiMsg），
// 映射成规范化消息段后缓存进 forward_bundles，节点里的媒体照常去重、下载；之后直接读缓存。
// 嵌套的合并转发按 path 逐层展开：上一层第 i 个节点的 msgId 就是下一层的 parentMsgId，rootMsgId 始终是会话里那条消息。
import type { Segment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { maybeOne, type Db } from '../db/client.ts';
import type { ForwardBundleRow, ForwardNodeInput, IngestService } from '../ingest/service.ts';
import type { UpstreamHub } from '../upstream/hub.ts';
import { mapRawMessage } from '../upstream/napcat/map.ts';
import type { NtRawMessage } from '../upstream/napcat/types.ts';
import { InteractionError } from './interactions.ts';

/** 拉不到的合并转发多久之后再试一次。 */
const UNAVAILABLE_RETRY_MS = 24 * 3600_000;

export class ForwardService {
  constructor(
    private readonly db: Db,
    private readonly ingest: Pick<IngestService, 'storeForward'>,
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
    const fresh = cached && (cached.state === 'ready' || Date.now() - new Date(cached.fetched_at).getTime() < UNAVAILABLE_RETRY_MS);
    if (cached && fresh) return { id: cached.id, state: cached.state, nodes: cached.nodes };

    let parentMsgId = message.qq_msg_id;
    if (path.length > 0) {
      const parent = await this.level(message, chatId, seq, path.slice(0, -1));
      const node = parent.nodes[path[path.length - 1]!];
      if (!node || !node.segments.some((s) => s.type === 'forward')) throw new InteractionError('not_found', `no nested forward at ${key}`);
      parentMsgId = node.msgId;
    }
    if (!message.qq_msg_id || !parentMsgId) throw new InteractionError('unsupported', 'message has no QQ id');

    const hub = this.upstream();
    if (!hub?.isConnected(message.qq_account_id)) {
      if (cached) return { id: cached.id, state: cached.state, nodes: cached.nodes };
      throw new InteractionError('offline', 'QQ is offline');
    }
    const res = await hub.call<{ result?: number; messages?: NtRawMessage[] }>(message.qq_account_id, 'x.forward', {
      chatType: message.scene === 'group' ? 2 : 1,
      peerUin: String(message.peer_id),
      ...(message.peer_uid ? { peerUid: message.peer_uid } : {}),
      rootMsgId: message.qq_msg_id,
      parentMsgId,
    });
    const raws = res?.result ? [] : (res?.messages ?? []);
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
    return this.ingest.storeForward(message.qq_account_id, chatId, seq, key, nodes.length ? nodes : null);
  }
}
