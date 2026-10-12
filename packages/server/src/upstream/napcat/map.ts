// NapCat 事件 → 领域模型（docs/design.md 4.3：映射放在服务端，插件保持很薄）。
// 以 NT 原始消息（raw）为准：真实 seq、md5、尺寸、文件 uuid 都在里面；OneBot 消息段只用来
// 借用现成的下载链接和 @ 的 QQ 号。历史消息（x.history）没有 OneBot 段，同样能映射，下载链接按需换取。
import type { PluginCallState } from '../../calls/service.ts';
import type {
  ChatEventKind,
  IncomingChatEvent,
  IncomingMedia,
  IncomingMessage,
  MediaInfo,
  PeerProfile,
  ReactionChange,
  Scene,
  Segment,
} from '@qqbridge/domain';
import { NtChatType, NtElementType, type NapcatEvent, type NtElement, type NtRawMessage, type Ob11Segment } from './types.ts';

export type UpstreamAction =
  | { type: 'message'; message: IncomingMessage; peers: PeerProfile[] }
  | { type: 'recall'; scene: Scene; peerId: number; seq: number; operatorId: number; time: number }
  | { type: 'chatEvent'; event: IncomingChatEvent }
  | { type: 'reaction'; scene: Scene; peerId: number; seq: number; change: ReactionChange }
  | { type: 'typing'; scene: Scene; peerId: number; userId: number; text: string }
  | { type: 'call'; state: PluginCallState }
  | { type: 'ignore'; reason: string };

/** 收件箱里的事件分类，便于排查和以后按类型重新处理。 */
export function eventKind(event: NapcatEvent): string {
  const sub = event.message_type ?? event.notice_type ?? (event.request_type as string | undefined) ?? (event.meta_event_type as string | undefined);
  return sub ? `${event.post_type ?? 'unknown'}.${sub}` : String(event.post_type ?? 'unknown');
}

export function mapNapcatEvent(event: NapcatEvent, selfUin: number): UpstreamAction {
  switch (event.post_type) {
    case 'qqbridge_call': {
      // 插件通话桥的状态快照（见插件 index.ts）。
      const state = (event as { call?: PluginCallState }).call;
      return state && typeof state === 'object' ? { type: 'call', state } : ignore('call event without state');
    }
    case 'message':
    case 'message_sent': {
      if (!event.raw) return ignore('message event without raw (is the plugin adapter in debug mode?)');
      const segments = Array.isArray(event.message) ? event.message : undefined;
      return mapRawMessage(event.raw, {
        selfUin,
        source: 'realtime',
        ...(segments ? { ob11: segments } : {}),
        fallback: {
          peerId: int(event.group_id) || int(event.target_id) || int(event.user_id),
          senderId: int(event.sender?.user_id) || int(event.user_id),
          time: int(event.time),
          senderName: event.sender?.nickname,
        },
      });
    }
    case 'notice':
      if (event.notice_type === 'group_recall' || event.notice_type === 'friend_recall') return mapRecall(event);
      return mapNotice(event, selfUin);
    default:
      return ignore(`${eventKind(event)} is not handled yet`);
  }
}

/** 消息相关通知（撤回、设精华、表情回应）里被操作的那条消息的真实 seq：插件或服务端由 OneBot 短 id 查出来后附上。 */
function targetSeq(event: NapcatEvent): number {
  return int(event.qqbridge?.message?.msgSeq) || int(event.qqbridge?.recalled?.msgSeq);
}

/** 除撤回外的各种通知 → 服务事件 / 表情回应 / 正在输入（字段取自 NapCat 4.18 的 OneBot 通知类）。 */
function mapNotice(event: NapcatEvent, selfUin: number): UpstreamAction {
  const time = int(event.time);
  const groupId = int(event.group_id);
  const userId = int(event.user_id);
  const operatorId = int(event.operator_id);
  const group = (kind: ChatEventKind, rest: Omit<IncomingChatEvent, 'scene' | 'peerId' | 'kind' | 'time'> = {}): UpstreamAction =>
    groupId
      ? { type: 'chatEvent', event: { scene: 'group', peerId: groupId, kind, time, ...rest } }
      : ignore(`${event.notice_type} without group_id`);
  const opt = (n: number) => (n ? n : undefined);
  switch (event.notice_type) {
    case 'group_increase':
      return group('member_join', compactEvent({ actorId: opt(operatorId), targetId: opt(userId), data: { via: event.sub_type ?? 'approve' } }));
    case 'group_decrease':
      return group('member_leave', compactEvent({ actorId: opt(operatorId), targetId: opt(userId), data: { how: event.sub_type ?? 'leave' } }));
    case 'group_admin':
      return group(event.sub_type === 'unset' ? 'admin_unset' : 'admin_set', compactEvent({ targetId: opt(userId) }));
    case 'group_ban': {
      const lift = event.sub_type === 'lift_ban';
      // user_id 为 0 表示全员禁言。
      return group(lift ? 'unmute' : 'mute', compactEvent({ actorId: opt(operatorId), targetId: opt(userId), data: { duration: int(event.duration), all: !userId } }));
    }
    case 'group_card':
      // NapCat 会把群里「某某邀请某某进群，点击欢迎…」这类灰条误报成自己的群名片变化（新旧名片一个是空、一个是灰条文字）；
      // 自己改群名片本来就知道，不记。
      if (userId === selfUin) return ignore('own group card change');
      if ((event.card_new ?? '') === (event.card_old ?? '')) return ignore('group card unchanged');
      return group('card_change', compactEvent({ targetId: opt(userId), data: { cardNew: event.card_new ?? '', cardOld: event.card_old ?? '' } }));
    case 'group_upload': {
      // 文件本身随群里的文件消息正常存档；这里只记"谁上传了什么"。
      const file = (event.file ?? {}) as { id?: string; name?: string; size?: number; busid?: number };
      return group('group_file', compactEvent({ actorId: opt(userId), data: { name: file.name ?? '', size: int(file.size), fileId: file.id ?? '', busid: int(file.busid) } }));
    }
    case 'essence': {
      const seq = targetSeq(event);
      return group(
        event.sub_type === 'delete' ? 'essence_remove' : 'essence_add',
        compactEvent({ actorId: opt(operatorId), targetId: opt(int(event.sender_id)), refSeq: opt(seq), data: seq ? {} : { messageId: event.message_id } }),
      );
    }
    case 'group_msg_emoji_like': {
      const seq = targetSeq(event);
      if (!groupId || !seq) return ignore('emoji like on a message whose seq cannot be resolved');
      const likes = (Array.isArray(event.likes) ? event.likes : []) as { emoji_id?: unknown; count?: unknown }[];
      return {
        type: 'reaction',
        scene: 'group',
        peerId: groupId,
        seq,
        change: {
          likes: likes.map((l) => ({ emojiId: String(l.emoji_id ?? ''), count: Number(l.count ?? 0) })).filter((l) => l.emojiId),
          byMe: userId === selfUin,
          isAdd: event.is_add !== false,
        },
      };
    }
    case 'friend_add':
      if (!userId) return ignore('friend_add without user_id');
      return {
        type: 'chatEvent',
        event: { scene: 'friend', peerId: userId, kind: 'friend_add', time, targetId: userId, peers: [{ kind: 'user', peerId: userId, isFriend: true }] },
      };
    case 'notify':
      return mapNotify(event, selfUin, time, groupId, userId, group);
    default:
      return ignore(`notice ${event.notice_type} is not handled yet`);
  }
}

function mapNotify(
  event: NapcatEvent,
  selfUin: number,
  time: number,
  groupId: number,
  userId: number,
  group: (kind: ChatEventKind, rest?: Omit<IncomingChatEvent, 'scene' | 'peerId' | 'kind' | 'time'>) => UpstreamAction,
): UpstreamAction {
  switch (event.sub_type) {
    case 'poke': {
      const targetId = int(event.target_id);
      const data = { rawInfo: event.raw_info ?? null };
      if (groupId) return group('poke', compactEvent({ actorId: userId || undefined, targetId: targetId || undefined, data }));
      // 私聊里的戳一戳：会话是"对方"。
      const peerId = userId === selfUin ? targetId : userId;
      if (!peerId) return ignore('poke without peer');
      return { type: 'chatEvent', event: compactEvent({ scene: 'friend', peerId, kind: 'poke', time, actorId: userId || undefined, targetId: targetId || undefined, data }) };
    }
    case 'input_status':
      if (!userId) return ignore('input_status without user_id');
      return { type: 'typing', scene: 'friend', peerId: userId, userId, text: String(event.status_text ?? '') };
    case 'title':
      return group('title', compactEvent({ targetId: userId || undefined, data: { title: event.title ?? '' } }));
    case 'group_name': {
      const name = String(event.name_new ?? '');
      const action = group('group_name', compactEvent({ actorId: userId || undefined, data: { name } }));
      if (action.type === 'chatEvent' && name) action.event.peers = [{ kind: 'group', peerId: groupId, name }];
      return action;
    }
    case 'gray_tip':
      return group('gray_tip', compactEvent({ actorId: userId || undefined, data: { content: event.content ?? '', busiId: event.busi_id ?? null } }));
    default:
      return ignore(`notify ${event.sub_type} is not handled yet`);
  }
}

function compactEvent<T extends object>(value: T): T {
  return Object.fromEntries(Object.entries(value).filter(([, v]) => v !== undefined)) as T;
}

function mapRecall(event: NapcatEvent): UpstreamAction {
  const recalled = event.qqbridge?.message ?? event.qqbridge?.recalled;
  const seq = int(recalled?.msgSeq);
  if (!seq) return ignore('recall notice without a resolvable seq');
  const time = int(event.time);
  if (event.notice_type === 'group_recall') {
    const groupId = int(event.group_id);
    if (!groupId) return ignore('group recall without group_id');
    return { type: 'recall', scene: 'group', peerId: groupId, seq, operatorId: int(event.operator_id) || int(event.user_id), time };
  }
  const peerId = int(recalled?.peerUin) || int(event.user_id);
  if (!peerId) return ignore('friend recall without peer');
  return { type: 'recall', scene: 'friend', peerId, seq, operatorId: int(event.operator_id) || int(event.user_id), time };
}

export interface MapRawOptions {
  selfUin: number;
  source: IncomingMessage['source'];
  /** 实时事件里的 OneBot 消息段：借用下载链接和 @ 的 QQ 号。 */
  ob11?: Ob11Segment[];
  /** raw 里缺字段时的兜底（来自 OneBot 事件本身）。 */
  fallback?: { peerId?: number; senderId?: number; time?: number; senderName?: string | undefined };
}

export function mapRawMessage(raw: NtRawMessage, opts: MapRawOptions): UpstreamAction {
  const scene = sceneOf(raw.chatType);
  if (!scene) return ignore(`unsupported chatType ${raw.chatType}`);
  const seq = int(raw.msgSeq);
  if (!seq) return ignore('message without msgSeq');
  const peerId = int(raw.peerUin) || opts.fallback?.peerId || 0;
  if (!peerId) return ignore('message without peer');
  const senderId = int(raw.senderUin) || opts.fallback?.senderId || 0;
  const time = int(raw.msgTime) || opts.fallback?.time || 0;

  const hints = new Ob11Hints(opts.ob11 ?? []);
  const segments: Segment[] = [];
  const media: IncomingMedia[] = [];
  const locatorBase = { chatType: raw.chatType, peerUid: raw.peerUid ?? '', msgId: raw.msgId ?? '' };

  for (const original of raw.elements ?? []) {
    const el = withElementType(original);
    const locator = { ...locatorBase, elementId: el.elementId, elementType: el.elementType };
    const ord = media.length;
    switch (el.elementType) {
      case NtElementType.TEXT: {
        const t = el.textElement ?? {};
        const atType = t.atType ?? 0;
        if (atType === 1) segments.push({ type: 'mention_all' });
        else if (atType === 2) {
          const userId = int(t.atUid) || hints.nextAt();
          const name = (t.content ?? '').replace(/^@/, '');
          if (userId) segments.push({ type: 'mention', userId, ...(name ? { name } : {}) });
          else segments.push({ type: 'text', text: t.content ?? '' });
        } else if (t.content) segments.push({ type: 'text', text: t.content });
        break;
      }
      case NtElementType.FACE: {
        const f = el.faceElement ?? {};
        const faceIndex = f.faceIndex ?? 0;
        if ((faceIndex === 358 || faceIndex === 359) && f.resultId) {
          segments.push({ type: 'unknown', original: faceIndex === 358 ? 'dice' : 'rps', data: { faceIndex, result: f.resultId } });
        } else {
          const name = typeof f.faceText === 'string' ? f.faceText.replace(/^\//, '') : '';
          segments.push({ type: 'face', faceId: String(faceIndex), ...(f.faceType === 3 || f.faceType === 4 ? { isLarge: true } : {}), ...(name ? { name } : {}) });
        }
        break;
      }
      case NtElementType.REPLY: {
        const r = el.replyElement ?? {};
        const replySeq = int(r.replayMsgSeq);
        // 被回复的人：QQ 把号码放在 senderUid 里（不是 uid 字符串，那个在 senderUidStr），senderUin 通常是空的。
        const replyTo = int(r.senderUin) || int(r.senderUid);
        if (replySeq) segments.push({ type: 'reply', seq: replySeq, ...(replyTo ? { senderId: replyTo } : {}) });
        break;
      }
      case NtElementType.PIC: {
        const p = el.picElement ?? {};
        const sticker = p.picSubType === 1;
        const width = positive(p.picWidth);
        const height = positive(p.picHeight);
        const info: MediaInfo = { ord, state: 'pending', ...(width ? { width } : {}), ...(height ? { height } : {}) };
        segments.push({
          type: 'image',
          media: info,
          ...(width ? { width } : {}),
          ...(height ? { height } : {}),
          ...(p.summary ? { summary: p.summary } : {}),
          subType: sticker ? 'sticker' : 'normal',
        });
        media.push(
          compact<IncomingMedia>({
            ord,
            kind: 'image',
            role: sticker ? 'sticker' : 'attachment',
            qqMd5: md5(p.md5HexStr),
            qqFileUuid: p.fileUuid,
            size: positive(p.fileSize),
            name: p.fileName,
            url: hints.imageUrl(p.fileName),
            locator: compactLocator({ ...locator, originImageUrl: p.originImageUrl, md5HexStr: p.md5HexStr }),
          }),
        );
        break;
      }
      case NtElementType.PTT: {
        const a = el.pttElement ?? {};
        segments.push({ type: 'record', media: { ord, state: 'pending' }, ...(positive(a.duration) ? { durationSec: a.duration! } : {}) });
        media.push(
          compact<IncomingMedia>({
            ord,
            kind: 'audio',
            role: 'attachment',
            qqMd5: md5(a.md5HexStr),
            qqFileUuid: a.fileUuid,
            size: positive(a.fileSize),
            name: a.fileName,
            url: hints.next('record'),
            locator: compactLocator({ ...locator, fileUuid: a.fileUuid }),
          }),
        );
        break;
      }
      case NtElementType.VIDEO: {
        const v = el.videoElement ?? {};
        const width = positive(v.thumbWidth);
        const height = positive(v.thumbHeight);
        segments.push({
          type: 'video',
          media: { ord, state: 'pending', ...(width ? { width } : {}), ...(height ? { height } : {}) },
          ...(width ? { width } : {}),
          ...(height ? { height } : {}),
          ...(positive(v.fileTime) ? { durationSec: v.fileTime! } : {}),
        });
        media.push(
          compact<IncomingMedia>({
            ord,
            kind: 'video',
            role: 'attachment',
            qqMd5: md5(v.videoMd5),
            qqFileUuid: v.fileUuid,
            size: positive(v.fileSize),
            name: v.fileName,
            url: hints.next('video'),
            locator: compactLocator({ ...locator, fileUuid: v.fileUuid }),
          }),
        );
        break;
      }
      case NtElementType.FILE: {
        const f = el.fileElement ?? {};
        const size = int(f.fileSize);
        const full = md5(f.fileMd5);
        const head = md5(f.file10MMd5);
        segments.push({ type: 'file', media: { ord, state: 'pending' }, name: f.fileName ?? '', ...(size ? { size } : {}) });
        media.push(
          compact<IncomingMedia>({
            ord,
            kind: 'file',
            role: 'attachment',
            qqMd5: full ?? head,
            qqMd5Partial: !full && head ? true : undefined,
            qqFileUuid: f.fileUuid,
            size: positive(size),
            name: f.fileName,
            url: hints.next('file'),
            locator: compactLocator({ ...locator, fileUuid: f.fileUuid, file10MMd5: f.file10MMd5 }),
          }),
        );
        break;
      }
      case NtElementType.MFACE: {
        const m = el.marketFaceElement ?? {};
        const emojiId = m.emojiId ?? '';
        const url = /^[0-9a-f]{32}$/i.test(emojiId)
          ? `https://gxh.vip.qq.com/club/item/parcel/item/${emojiId.slice(0, 2)}/${emojiId}/raw300.gif`
          : undefined;
        segments.push({
          type: 'market_face',
          emojiId,
          ...(m.emojiPackageId ? { packageId: m.emojiPackageId } : {}),
          ...(m.key ? { key: m.key } : {}),
          ...(m.faceName ? { summary: m.faceName } : {}),
          ...(url ? { media: { ord, state: 'pending' } } : {}),
        });
        if (url) media.push({ ord, kind: 'sticker', role: 'sticker', url, name: `${emojiId}.gif` });
        break;
      }
      case NtElementType.MULTIFORWARD: {
        const fwd = el.multiForwardMsgElement ?? {};
        const parsed = parseForwardXml(fwd.xmlContent ?? '');
        segments.push({ type: 'forward', forwardId: fwd.resId ?? '', ...parsed });
        break;
      }
      case NtElementType.ARK: {
        const json = el.arkElement?.bytesData ?? '';
        const multi = multiMsgArk(json);
        // 用卡片发出的合并转发（例如自己从这里打包转发出去的）：和普通的聊天记录一样能点开。
        segments.push(multi ?? { type: 'light_app', appName: arkAppName(json), json });
        break;
      }
      case NtElementType.MARKDOWN:
        // 机器人 markdown 开头常带一个空链接 "[](%7B...%7D)" 当元数据，不是正文。
        segments.push({ type: 'markdown', content: (el.markdownElement?.content ?? '').replace(/^\[\]\([^)]*\)\s*/, '') });
        break;
      case NtElementType.INLINE_KEYBOARD:
        // 按钮只在 QQ 里能点，存档保留原文，预览和正文里不显示。
        segments.push({ type: 'unknown', original: 'keyboard', data: el });
        break;
      default:
        // 未知类型保留原文，绝不丢弃（以后支持了可以从 raw 重新映射）。
        segments.push({ type: 'unknown', original: `nt:${el.elementType}`, data: el });
    }
  }

  const message: IncomingMessage = {
    scene,
    peerId,
    seq,
    senderId,
    ...((raw.sendMemberName || raw.sendNickName) ? { senderName: raw.sendMemberName || raw.sendNickName } : {}),
    time,
    ...(raw.msgId ? { qqMsgId: raw.msgId } : {}),
    ...(int(raw.msgRandom) ? { random: int(raw.msgRandom) } : {}),
    segments,
    media,
    self: senderId === opts.selfUin,
    source: opts.source,
    raw,
  };
  return { type: 'message', message, peers: peersOf(raw, scene, peerId, senderId, opts.fallback?.senderName) };
}

function peersOf(raw: NtRawMessage, scene: Scene, peerId: number, senderId: number, senderName?: string): PeerProfile[] {
  const peers: PeerProfile[] = [];
  if (scene === 'group' && raw.peerName) peers.push({ kind: 'group', peerId, name: raw.peerName });
  const name = senderName || raw.sendNickName;
  if (senderId && (name || raw.senderUid)) {
    peers.push({
      kind: 'user',
      peerId: senderId,
      ...(raw.senderUid ? { uid: raw.senderUid } : {}),
      ...(name ? { name } : {}),
      ...(scene === 'friend' && raw.sendRemarkName ? { remark: raw.sendRemarkName } : {}),
    });
  }
  return peers;
}

/** OneBot 段里的现成信息：图片按文件名对应，其余媒体按同类型的出现顺序对应。只接受 http(s) 链接。 */
class Ob11Hints {
  private readonly imagesByName = new Map<string, string>();
  private readonly queues = new Map<string, Ob11Segment[]>();
  private readonly ats: number[] = [];

  constructor(segments: Ob11Segment[]) {
    for (const seg of segments) {
      if (seg.type === 'image' && typeof seg.data?.file === 'string' && httpUrl(seg.data.url)) {
        this.imagesByName.set(seg.data.file, seg.data.url as string);
      }
      if (seg.type === 'at') {
        const qq = int(seg.data?.qq);
        if (qq) this.ats.push(qq);
      }
      const list = this.queues.get(seg.type) ?? [];
      list.push(seg);
      this.queues.set(seg.type, list);
    }
  }

  imageUrl(fileName: string | undefined): string | undefined {
    return fileName ? this.imagesByName.get(fileName) : undefined;
  }

  next(type: string): string | undefined {
    const seg = this.queues.get(type)?.shift();
    return httpUrl(seg?.data?.url) ? (seg!.data!.url as string) : undefined;
  }

  nextAt(): number {
    return this.ats.shift() ?? 0;
  }
}

export function parseForwardXml(xml: string): { title?: string; preview?: string[]; summary?: string } {
  const titles = [...xml.matchAll(/<title[^>]*>([^<]*)<\/title>/g)].map((m) => decodeEntities(m[1]!));
  const summary = /<summary[^>]*>([^<]*)<\/summary>/.exec(xml)?.[1];
  return {
    ...(titles[0] ? { title: titles[0] } : {}),
    ...(titles.length > 1 ? { preview: titles.slice(1) } : {}),
    ...(summary ? { summary: decodeEntities(summary) } : {}),
  };
}

function arkAppName(json: string): string {
  try {
    const app = (JSON.parse(json) as { app?: unknown }).app;
    return typeof app === 'string' ? app : '';
  } catch {
    return '';
  }
}

function decodeEntities(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, n: string) => String.fromCodePoint(Number(n)))
    .replace(/&amp;/g, '&');
}

function sceneOf(chatType: number | undefined): Scene | null {
  switch (chatType) {
    case NtChatType.friend:
      return 'friend';
    case NtChatType.group:
      return 'group';
    case NtChatType.temp:
      return 'temp';
    default:
      return null;
  }
}

/** 解析正整数（QQ 的数字字段常以字符串出现）；无效时返回 0。 */
export function int(value: unknown): number {
  const n = typeof value === 'string' ? (/^\d+$/.test(value) ? Number(value) : NaN) : Number(value);
  return Number.isSafeInteger(n) && n > 0 ? n : 0;
}

function positive(value: unknown): number | undefined {
  const n = int(value);
  return n > 0 ? n : undefined;
}

function md5(value: string | undefined): string | undefined {
  return value && /^[0-9a-f]{32}$/i.test(value) ? value.toLowerCase() : undefined;
}

function httpUrl(value: unknown): value is string {
  return typeof value === 'string' && /^https?:\/\//.test(value);
}

/** 去掉值为 undefined 的字段（exactOptionalPropertyTypes 下可选字段不能显式为 undefined）。 */
function compact<T extends object>(value: { [K in keyof T]: T[K] | undefined }): T {
  return Object.fromEntries(Object.entries(value).filter(([, v]) => v !== undefined && v !== '')) as T;
}

function compactLocator(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(value).filter(([, v]) => v !== undefined && v !== null && v !== ''));
}

function ignore(reason: string): UpstreamAction {
  return { type: 'ignore', reason };
}

export type { NtElement };

/** com.tencent.multimsg 卡片（合并转发）→ 聊天记录段；不是这种卡片或缺 resid 时返回 null。 */
export function multiMsgArk(json: string): Extract<Segment, { type: 'forward' }> | null {
  try {
    const card = JSON.parse(json) as {
      app?: string;
      meta?: { detail?: { resid?: string; source?: string; summary?: string; news?: { text?: string }[] } };
    };
    const detail = card.meta?.detail;
    if (card.app !== 'com.tencent.multimsg' || !detail?.resid) return null;
    const preview = (detail.news ?? []).map((n) => n.text ?? '').filter(Boolean).slice(0, 4);
    return {
      type: 'forward',
      forwardId: detail.resid,
      ...(detail.source ? { title: detail.source } : {}),
      ...(preview.length > 0 ? { preview } : {}),
      ...(detail.summary ? { summary: detail.summary } : {}),
    };
  } catch {
    return null;
  }
}

/** 按 resid 拉回的合并转发（NapCat 自己解析的包）元素类型都是 0：按带了哪种内容补上类型。 */
const ELEMENT_FIELDS: [keyof NtElement, number][] = [
  ['textElement', NtElementType.TEXT],
  ['picElement', NtElementType.PIC],
  ['fileElement', NtElementType.FILE],
  ['pttElement', NtElementType.PTT],
  ['videoElement', NtElementType.VIDEO],
  ['faceElement', NtElementType.FACE],
  ['replyElement', NtElementType.REPLY],
  ['arkElement', NtElementType.ARK],
  ['marketFaceElement', NtElementType.MFACE],
  ['markdownElement', NtElementType.MARKDOWN],
  ['multiForwardMsgElement', NtElementType.MULTIFORWARD],
];

function withElementType(el: NtElement): NtElement {
  if (el.elementType) return el;
  const hit = ELEMENT_FIELDS.find(([field]) => (el as unknown as Record<string, unknown>)[field as string] != null);
  return hit ? { ...el, elementType: hit[1] } : el;
}
