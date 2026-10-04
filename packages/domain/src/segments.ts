import type { Segment } from './types.ts';

/** 消息标志位：用于共享媒体页、"@我"未读、检索过滤。 */
export const MessageFlag = {
  photo: 1 << 0,
  video: 1 << 1,
  voice: 1 << 2,
  file: 1 << 3,
  link: 1 << 4,
  mentionsMe: 1 << 5,
  mentionAll: 1 << 6,
  sticker: 1 << 7,
} as const;

const URL_PATTERN = /https?:\/\/[^\s]+/i;

export function messageFlags(segments: readonly Segment[], selfUin: number): number {
  let flags = 0;
  for (const seg of segments) {
    switch (seg.type) {
      case 'image':
        flags |= seg.subType === 'sticker' ? MessageFlag.sticker : MessageFlag.photo;
        break;
      case 'market_face':
        flags |= MessageFlag.sticker;
        break;
      case 'video':
        flags |= MessageFlag.video;
        break;
      case 'record':
        flags |= MessageFlag.voice;
        break;
      case 'file':
        flags |= MessageFlag.file;
        break;
      case 'mention':
        if (seg.userId === selfUin) flags |= MessageFlag.mentionsMe;
        break;
      case 'mention_all':
        flags |= MessageFlag.mentionAll;
        break;
      case 'text':
        if (URL_PATTERN.test(seg.text)) flags |= MessageFlag.link;
        break;
      case 'light_app':
        flags |= MessageFlag.link;
        break;
      default:
        break;
    }
  }
  return flags;
}

/** 纯文本表示：用于全文检索和会话列表预览。非文本内容用简短占位符。 */
export function plainText(segments: readonly Segment[]): string {
  return segments
    .map((seg) => {
      switch (seg.type) {
        case 'text':
          return seg.text;
        case 'mention':
          return `@${seg.name ?? seg.userId}`;
        case 'mention_all':
          return '@全体成员';
        case 'face':
          return '[表情]';
        case 'reply':
          return '';
        case 'image':
          return seg.subType === 'sticker' ? '[动画表情]' : '[图片]';
        case 'record':
          return '[语音]';
        case 'video':
          return '[视频]';
        case 'file':
          return `[文件] ${seg.name}`;
        case 'forward':
          return `[聊天记录] ${seg.title ?? ''}`.trim();
        case 'market_face':
          return seg.summary ?? '[表情]';
        case 'light_app':
          return `[卡片] ${seg.appName}`;
        case 'xml':
          return '[卡片]';
        case 'markdown':
          return seg.content;
        case 'unknown':
          return `[${seg.original}]`;
      }
    })
    .join('')
    .trim();
}

/** 把媒体段里的 MediaInfo 按 ord 替换（媒体下载完成后更新消息内容用）。 */
export function updateMediaInfo(
  segments: readonly Segment[],
  ord: number,
  patch: Partial<Omit<import('./types.ts').MediaInfo, 'ord'>>,
): Segment[] {
  return segments.map((seg) => {
    if ('media' in seg && seg.media && seg.media.ord === ord) {
      return { ...seg, media: { ...seg.media, ...patch } } as Segment;
    }
    return seg;
  });
}
