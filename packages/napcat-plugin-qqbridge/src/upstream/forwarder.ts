// 把 OneBot 事件放进上游队列。
// - 心跳、生命周期等元事件不转发。
// - 撤回、设精华、表情回应通知里的 message_id 只是 NapCat 的短 id，服务端无法对应到消息；这里补上真实 seq
//   （qqbridge.message）：优先查最近见过的消息，查不到再调 get_msg。
import type { NapCatPluginContext, OB11Event, PluginLogger } from '../napcat.js';
import { callAction } from './actions.js';
import type { UpstreamLink } from './link.js';
import type { UpstreamQueue } from './queue.js';

export interface RecalledKey {
  msgSeq: string;
  msgId?: string;
  chatType?: number;
  peerUin?: string;
  peerUid?: string;
}

const TARGETED_NOTICES = new Set(['group_recall', 'friend_recall', 'essence', 'group_msg_emoji_like']);

export class EventForwarder {
  private readonly keys = new Map<number, RecalledKey>();

  constructor(
    private readonly ctx: NapCatPluginContext,
    private readonly queue: UpstreamQueue,
    private readonly link: Pick<UpstreamLink, 'notify'> | null,
    private readonly logger: PluginLogger,
    private readonly maxKeys = 50_000,
    private readonly getMsgTimeoutMs = 3000,
  ) {}

  /** 最近见过的消息：OneBot 短 id → 真实 seq 等（发送后对应 seq 也用它）。 */
  lookup(shortId: number): RecalledKey | undefined {
    return this.keys.get(shortId);
  }

  onEvent(event: OB11Event): void {
    if (event.post_type === 'meta_event') return;
    if (event.post_type === 'message' || event.post_type === 'message_sent') this.remember(event);
    if (event.post_type === 'notice' && TARGETED_NOTICES.has(String(event.notice_type))) {
      void this.enrichTarget(event).then((enriched) => this.enqueue(enriched));
      return;
    }
    this.enqueue(event);
  }

  private enqueue(event: OB11Event): void {
    try {
      this.queue.append(event);
      this.link?.notify();
    } catch (error) {
      this.logger.error('[qqbridge] upstream queue append failed:', error);
    }
  }

  private remember(event: OB11Event): void {
    const id = Number(event.message_id);
    const raw = event.raw as Record<string, unknown> | undefined;
    if (!Number.isFinite(id) || !raw?.msgSeq) return;
    this.keys.delete(id);
    this.keys.set(id, {
      msgSeq: String(raw.msgSeq),
      msgId: String(raw.msgId ?? ''),
      chatType: Number(raw.chatType),
      peerUin: String(raw.peerUin ?? ''),
      peerUid: String(raw.peerUid ?? ''),
    });
    if (this.keys.size > this.maxKeys) this.keys.delete(this.keys.keys().next().value!);
  }

  private async enrichTarget(event: OB11Event): Promise<OB11Event> {
    const id = Number(event.message_id);
    const key = this.keys.get(id) ?? (await this.resolveViaGetMsg(id));
    return key ? { ...event, qqbridge: { message: key } } : event;
  }

  private async resolveViaGetMsg(id: number): Promise<RecalledKey | undefined> {
    if (!Number.isFinite(id)) return undefined;
    let timer: NodeJS.Timeout | undefined;
    try {
      const msg = (await Promise.race([
        callAction(this.ctx, 'get_msg', { message_id: id }),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('get_msg timed out')), this.getMsgTimeoutMs);
        }),
      ])) as Record<string, unknown> | null;
      const seq = msg?.real_seq;
      if (seq === undefined || seq === null || seq === '') return undefined;
      return { msgSeq: String(seq) };
    } catch (error) {
      this.logger.warn('[qqbridge] cannot resolve recalled message', id, error instanceof Error ? error.message : error);
      return undefined;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
}
