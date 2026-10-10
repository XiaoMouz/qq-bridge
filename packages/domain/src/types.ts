// 领域模型：与 Milky 的语义对齐（会话 = scene + peerId，消息主键 = 会话内 seq）。
// 上游适配器（NapCat / Milky）把各自的事件转换成这里的类型，服务端其余部分只认这些类型。

export type Scene = 'friend' | 'group' | 'temp';

export type MediaKind = 'image' | 'video' | 'audio' | 'file' | 'sticker';

/** 媒体在什么场景下出现。 */
export type MediaRole = 'attachment' | 'sticker' | 'group_file' | 'avatar' | 'upload';

/** purged：原件已按存储策略清理，缩略图 / 预览图仍在。 */
export type MediaState = 'pending' | 'stored' | 'failed' | 'expired' | 'skipped' | 'purged' | 'on_demand';

/**
 * 消息段里携带的媒体信息（对客户端可见的部分）。
 * 上游标识（md5、fileUuid、临时链接等）只存在 media_refs 表里，不放进消息段。
 */
export interface MediaInfo {
  /** 消息内的媒体序号，对应 media_refs.ordinal。 */
  ord: number;
  state: MediaState;
  sha256?: string;
  size?: number;
  mime?: string;
  /** 极小的模糊占位图（base64），收到消息就能先画出轮廓。 */
  thumbhash?: string;
  /** 派生版本的 sha256：客户端按需换签名链接，本地只缓存这些小文件（docs/design.md 6.3）。 */
  thumbSha256?: string;
  previewSha256?: string;
  width?: number;
  height?: number;
  /** 客户端能直接播放的版本（语音：AAC m4a；原件本身能播放时等于原件）。 */
  playableSha256?: string;
  /** 语音波形（base64，64 个 0–255 的振幅）。 */
  waveform?: string;
}

/** 规范化消息段，与 Milky IncomingSegment 一一对应；未知类型保留原文，绝不丢弃。 */
export type Segment =
  | { type: 'text'; text: string }
  | { type: 'mention'; userId: number; name?: string }
  | { type: 'mention_all' }
  /** name：QQ 给的表情名（如「微笑」），客户端本地没有这个表情时用来显示。 */
  | { type: 'face'; faceId: string; isLarge?: boolean; name?: string }
  | { type: 'reply'; seq: number; senderId?: number }
  | { type: 'image'; media: MediaInfo; width?: number; height?: number; summary?: string; subType?: 'normal' | 'sticker' }
  | { type: 'record'; media: MediaInfo; durationSec?: number }
  | { type: 'video'; media: MediaInfo; width?: number; height?: number; durationSec?: number }
  | { type: 'file'; media: MediaInfo; name: string; size?: number }
  | { type: 'forward'; forwardId: string; title?: string; preview?: string[]; summary?: string }
  | { type: 'market_face'; emojiId: string; packageId?: number; key?: string; summary?: string; media?: MediaInfo }
  | { type: 'light_app'; appName: string; json: string }
  | { type: 'xml'; serviceId?: number; xml: string }
  | { type: 'markdown'; content: string }
  | { type: 'unknown'; original: string; data?: unknown };

/** 消息里出现的一个媒体在上游的定位信息，入库时写进 media_refs。 */
export interface IncomingMedia {
  ord: number;
  kind: MediaKind;
  role: MediaRole;
  qqMd5?: string;
  /** true 表示 qqMd5 只是前 10MB 的 md5（大文件），去重时必须同时比对大小。 */
  qqMd5Partial?: boolean;
  qqFileUuid?: string;
  qqResourceId?: string;
  qqFileId?: string;
  url?: string;
  /** 临时链接过期时间（unix 秒）。 */
  urlExpiresAt?: number;
  size?: number;
  name?: string;
  mime?: string;
  /** 上游定位信息（例如 NapCat 的 msgId + elementId），换新下载链接时原样交还给上游。 */
  locator?: Record<string, unknown>;
}

/** 上游适配器产出的一条消息。 */
export interface IncomingMessage {
  scene: Scene;
  peerId: number;
  seq: number;
  senderId: number;
  /** unix 秒。 */
  time: number;
  qqMsgId?: string;
  random?: number;
  segments: Segment[];
  media: IncomingMedia[];
  /** 本 QQ 号自己发出的（含在手机等其他设备上发出的）。 */
  self: boolean;
  source: 'realtime' | 'backfill' | 'self';
  raw?: unknown;
}

export interface PeerProfile {
  kind: 'user' | 'group';
  peerId: number;
  uid?: string;
  name?: string;
  remark?: string;
  isFriend?: boolean;
  memberCount?: number;
  /** 个性签名（好友）/ 群简介。 */
  sign?: string;
  avatarSha256?: string;
}
