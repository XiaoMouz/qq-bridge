// 外发消息 → NapCat 的 OneBot 11 消息段。媒体给 NapCat 一个带签名、带文件名的下载链接，NapCat 下载后再传给 QQ。
import type { OutgoingMessage } from '@qqbridge/domain';

export interface Ob11Segment {
  type: string;
  data: Record<string, unknown>;
}

/** sha256 + 文件名 → 插件能访问到的下载链接。 */
export type MediaUrl = (sha256: string, name: string) => string;

const EXTENSIONS: Record<string, string> = {
  'image/jpeg': '.jpg',
  'image/png': '.png',
  'image/gif': '.gif',
  'image/webp': '.webp',
  'image/heic': '.heic',
  'video/mp4': '.mp4',
  'video/quicktime': '.mov',
  'audio/mp4': '.m4a',
  'audio/x-m4a': '.m4a',
  'audio/aac': '.aac',
  'audio/mpeg': '.mp3',
  'audio/ogg': '.ogg',
  'audio/wav': '.wav',
  'audio/amr': '.amr',
  'audio/silk': '.silk',
};

/** 没有原始文件名时，用 sha256 前缀 + 按类型推断的扩展名（NapCat 靠扩展名决定怎么处理语音、视频）。 */
export function mediaFileName(sha256: string, mime: string | null | undefined): string {
  return `${sha256.slice(0, 16)}${(mime && EXTENSIONS[mime]) || ''}`;
}

export function toOb11(msg: OutgoingMessage, url: MediaUrl, mimes: ReadonlyMap<string, string | null>): Ob11Segment[] {
  const out: Ob11Segment[] = [];
  // NapCat 的 reply 段支持直接用真实 seq（无需 OneBot 短 id）。
  if (msg.replyToSeq) out.push({ type: 'reply', data: { seq: msg.replyToSeq } });
  for (const seg of msg.segments) {
    switch (seg.type) {
      case 'text':
        out.push({ type: 'text', data: { text: seg.text } });
        break;
      case 'mention':
        out.push({ type: 'at', data: { qq: String(seg.userId) } });
        break;
      case 'mention_all':
        out.push({ type: 'at', data: { qq: 'all' } });
        break;
      case 'face':
        out.push({ type: 'face', data: { id: seg.faceId } });
        break;
      case 'image':
        out.push({
          type: 'image',
          data: {
            file: url(seg.sha256, mediaFileName(seg.sha256, mimes.get(seg.sha256))),
            ...(seg.sticker ? { sub_type: 1 } : {}),
            ...(seg.summary ? { summary: seg.summary } : {}),
          },
        });
        break;
      case 'record':
        out.push({ type: 'record', data: { file: url(seg.sha256, mediaFileName(seg.sha256, mimes.get(seg.sha256))) } });
        break;
      case 'video':
        out.push({ type: 'video', data: { file: url(seg.sha256, mediaFileName(seg.sha256, mimes.get(seg.sha256))) } });
        break;
      case 'file':
        out.push({ type: 'file', data: { file: url(seg.sha256, seg.name), name: seg.name } });
        break;
    }
  }
  return out;
}
