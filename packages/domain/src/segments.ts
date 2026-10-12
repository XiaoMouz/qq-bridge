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
  /** 回复了我发的消息。 */
  replyToMe: 1 << 8,
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
      case 'reply':
        if (seg.senderId === selfUin) flags |= MessageFlag.replyToMe;
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

/**
 * 机器人 markdown → 纯文本（预览和检索用，正文仍按 markdown 渲染）：
 * 图片记为 [图片]，链接只留文字，去掉标题、加粗、代码等标记。
 */
export function markdownText(md: string): string {
  return md
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '[图片]')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/^[ \t]{0,3}#{1,6}[ \t]+/gm, '')
    .replace(/^[ \t]{0,3}>[ \t]?/gm, '')
    .replace(/(\*\*|__|~~|`)/g, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
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
          return seg.name ? `[${seg.name}]` : '[表情]';
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
          return cardText(seg.json);
        case 'xml':
          return '[卡片]';
        case 'markdown':
          return markdownText(seg.content);
        case 'unknown':
          return seg.original === 'keyboard' ? '' : `[${seg.original}]`;
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

/**
 * 卡片（小程序、分享、群相册……）的一句话：卡片自带的提示（「[QQ小程序]标题」「群相册《xx》」），
 * 没有就用里面的标题 / 简介；都没有才是「[卡片]」（不显示 com.tencent.xxx 这种内部名字）。
 */
export function cardText(json: string): string {
  try {
    const obj = JSON.parse(json) as { prompt?: unknown; meta?: Record<string, unknown> };
    if (typeof obj.prompt === 'string' && obj.prompt.trim()) return obj.prompt.trim();
    for (const v of Object.values(obj.meta ?? {})) {
      const d = v as { title?: unknown; desc?: unknown };
      const title = typeof d?.title === 'string' && d.title.trim() ? d.title.trim() : typeof d?.desc === 'string' ? d.desc.trim() : '';
      if (title) return `[卡片] ${title}`;
    }
  } catch {
    // 不是 JSON：只显示「[卡片]」。
  }
  return '[卡片]';
}
