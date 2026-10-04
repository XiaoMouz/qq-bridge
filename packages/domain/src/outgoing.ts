// 外发消息（docs/design.md 4.7"发送幂等"）：客户端先把媒体传到服务端（按 sha256 去重 / 秒传），
// 消息里只引用 sha256；服务端放进发件箱，再经上游发往 QQ。
export type OutgoingSegment =
  | { type: 'text'; text: string }
  | { type: 'mention'; userId: number }
  | { type: 'mention_all' }
  | { type: 'face'; faceId: string }
  | { type: 'image'; sha256: string; summary?: string; sticker?: boolean }
  | { type: 'record'; sha256: string; durationSec?: number }
  | { type: 'video'; sha256: string }
  | { type: 'file'; sha256: string; name: string };

export interface OutgoingMessage {
  segments: OutgoingSegment[];
  /** 回复的消息（同一会话内的 seq）。 */
  replyToSeq?: number;
}

/** QQ 要求单独成条的内容：语音、视频、文件。 */
const STANDALONE = new Set<OutgoingSegment['type']>(['record', 'video', 'file']);
const SHA256 = /^[0-9a-f]{64}$/;
export const MAX_OUTGOING_TEXT = 5000;
export const MAX_OUTGOING_SEGMENTS = 50;

/** 校验一条外发消息；合法返回 null，否则返回原因。 */
export function validateOutgoing(msg: OutgoingMessage): string | null {
  const { segments } = msg;
  if (segments.length === 0) return 'message is empty';
  if (segments.length > MAX_OUTGOING_SEGMENTS) return `too many segments (max ${MAX_OUTGOING_SEGMENTS})`;
  let textLength = 0;
  for (const seg of segments) {
    switch (seg.type) {
      case 'text':
        if (seg.text.length === 0) return 'empty text segment';
        textLength += seg.text.length;
        break;
      case 'mention':
        if (!Number.isSafeInteger(seg.userId) || seg.userId <= 0) return 'invalid mention';
        break;
      case 'mention_all':
        break;
      case 'face':
        if (!/^\d{1,6}$/.test(seg.faceId)) return 'invalid face id';
        break;
      case 'image':
      case 'record':
      case 'video':
        if (!SHA256.test(seg.sha256)) return `invalid ${seg.type} sha256`;
        break;
      case 'file':
        if (!SHA256.test(seg.sha256)) return 'invalid file sha256';
        if (!seg.name.trim() || seg.name.length > 255 || /[/\\\0]/.test(seg.name)) return 'invalid file name';
        break;
      default:
        return 'unknown segment';
    }
  }
  if (textLength > MAX_OUTGOING_TEXT) return `text too long (max ${MAX_OUTGOING_TEXT})`;
  const standalone = segments.filter((s) => STANDALONE.has(s.type));
  if (standalone.length > 0 && segments.length > 1) return `${standalone[0]!.type} must be sent on its own`;
  if (standalone.length > 0 && msg.replyToSeq !== undefined) return `${standalone[0]!.type} cannot reply to a message`;
  if (msg.replyToSeq !== undefined && (!Number.isSafeInteger(msg.replyToSeq) || msg.replyToSeq <= 0)) return 'invalid reply seq';
  return null;
}

/** 消息里引用到的媒体（发送前要确认服务端都已有这些内容）。 */
export function outgoingMedia(segments: readonly OutgoingSegment[]): string[] {
  const shas: string[] = [];
  for (const seg of segments) if ('sha256' in seg) shas.push(seg.sha256);
  return [...new Set(shas)];
}
