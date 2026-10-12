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
  | { type: 'file'; sha256: string; name: string }
  /** 合并转发（打包）：每个节点带原发送者的 QQ 号和昵称，QQ 里显示成"聊天记录"。必须单独成条。 */
  | { type: 'forward'; nodes: ForwardNode[] };

export interface ForwardNode {
  userId: number;
  nickname: string;
  /** 节点内容：可以再套一层合并转发（要单独成一个节点，最多套 MAX_FORWARD_DEPTH 层）。 */
  segments: OutgoingSegment[];
}

export const MAX_FORWARD_NODES = 100;
export const MAX_FORWARD_DEPTH = 4;

export interface OutgoingMessage {
  segments: OutgoingSegment[];
  /** 回复的消息（同一会话内的 seq）。 */
  replyToSeq?: number;
}

/** QQ 要求单独成条的内容：语音、视频、文件。 */
const STANDALONE = new Set<OutgoingSegment['type']>(['record', 'video', 'file', 'forward']);
const SHA256 = /^[0-9a-f]{64}$/;
export const MAX_OUTGOING_TEXT = 5000;
export const MAX_OUTGOING_SEGMENTS = 50;

/** 校验一条外发消息；合法返回 null，否则返回原因。 */
export function validateOutgoing(msg: OutgoingMessage, depth = 1): string | null {
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
      case 'forward': {
        if (seg.nodes.length === 0 || seg.nodes.length > MAX_FORWARD_NODES) return `forward needs 1–${MAX_FORWARD_NODES} nodes`;
        if (depth > MAX_FORWARD_DEPTH) return 'forward nested too deep';
        for (const node of seg.nodes) {
          if (!Number.isSafeInteger(node.userId) || node.userId <= 0) return 'invalid forward node sender';
          const inner = validateOutgoing({ segments: node.segments }, depth + 1);
          if (inner) return `forward node: ${inner}`;
        }
        break;
      }
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
  for (const seg of segments) {
    if ('sha256' in seg) shas.push(seg.sha256);
    if (seg.type === 'forward') for (const node of seg.nodes) shas.push(...outgoingMedia(node.segments));
  }
  return [...new Set(shas)];
}
