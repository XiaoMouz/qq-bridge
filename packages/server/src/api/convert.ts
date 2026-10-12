// 领域行 → Protobuf 消息。int64 一律转 bigint，时间一律转 unix 秒。
import { create, type MessageInitShape } from '@bufbuild/protobuf';
import type {
  MediaInfo as DomainMediaInfo,
  MediaKind as DomainMediaKind,
  OutgoingSegment as DomainOutgoingSegment,
  Reaction as DomainReaction,
  Scene as DomainScene,
  Segment,
} from '@qqbridge/domain';
import {
  CallMedia,
  CallPhase,
  CallSchema,
  ChatEventSchema,
  DialogSchema,
  DifferenceSchema,
  MediaKind,
  MediaState,
  MessageKind,
  MessageSchema,
  MessageState,
  OutboxEntrySchema,
  OutboxState,
  OutgoingSegmentSchema,
  PeerKind,
  PeerSchema,
  Scene,
  SegmentSchema,
  type Call,
  type ChatEvent,
  type Dialog,
  type Difference as ProtoDifference,
  type Message,
  type OutboxEntry,
  type OutgoingSegment,
  type Peer,
} from '@qqbridge/protocol';
import type { CallRecord } from '../calls/service.ts';
import type { Difference } from '../sync/difference.ts';
import type { ChatEventRow, DialogRow, MessageRow, OutboxRow, PeerRow } from '../sync/rows.ts';

const big = (n: number | null | undefined): bigint => BigInt(n ?? 0);
const unix = (d: Date | null | undefined): bigint => (d ? BigInt(Math.floor(d.getTime() / 1000)) : 0n);

export function sceneToProto(scene: DomainScene): Scene {
  return scene === 'friend' ? Scene.FRIEND : scene === 'group' ? Scene.GROUP : Scene.TEMP;
}

export function mediaKindToProto(kind: string): MediaKind {
  switch (kind as DomainMediaKind) {
    case 'image':
      return MediaKind.IMAGE;
    case 'video':
      return MediaKind.VIDEO;
    case 'audio':
      return MediaKind.AUDIO;
    case 'file':
      return MediaKind.FILE;
    case 'sticker':
      return MediaKind.STICKER;
    default:
      return MediaKind.UNSPECIFIED;
  }
}

export function mediaKindFromProto(kind: MediaKind): DomainMediaKind | null {
  switch (kind) {
    case MediaKind.IMAGE:
      return 'image';
    case MediaKind.VIDEO:
      return 'video';
    case MediaKind.AUDIO:
      return 'audio';
    case MediaKind.FILE:
      return 'file';
    case MediaKind.STICKER:
      return 'sticker';
    default:
      return null;
  }
}

const MEDIA_STATES: Record<DomainMediaInfo['state'], MediaState> = {
  pending: MediaState.PENDING,
  stored: MediaState.STORED,
  failed: MediaState.FAILED,
  expired: MediaState.EXPIRED,
  skipped: MediaState.SKIPPED,
  purged: MediaState.PURGED,
  on_demand: MediaState.ON_DEMAND,
};

export function mediaInfo(m: DomainMediaInfo) {
  return {
    ord: m.ord,
    state: MEDIA_STATES[m.state] ?? MediaState.UNSPECIFIED,
    sha256: m.sha256 ?? '',
    size: big(m.size),
    mime: m.mime ?? '',
    thumbhash: m.thumbhash ?? '',
    thumbSha256: m.thumbSha256 ?? '',
    previewSha256: m.previewSha256 ?? '',
    width: m.width ?? 0,
    height: m.height ?? 0,
    playableSha256: m.playableSha256 ?? '',
    waveform: m.waveform ? Buffer.from(m.waveform, 'base64') : new Uint8Array(),
  };
}

export function segmentToProto(seg: Segment): MessageInitShape<typeof SegmentSchema> {
  switch (seg.type) {
    case 'text':
      return { kind: { case: 'text', value: { text: seg.text } } };
    case 'mention':
      return { kind: { case: 'mention', value: { userId: big(seg.userId), name: seg.name ?? '' } } };
    case 'mention_all':
      return { kind: { case: 'mentionAll', value: {} } };
    case 'face':
      return { kind: { case: 'face', value: { faceId: seg.faceId, isLarge: Boolean(seg.isLarge), name: seg.name ?? '' } } };
    case 'reply':
      return { kind: { case: 'reply', value: { seq: big(seg.seq), senderId: big(seg.senderId) } } };
    case 'image':
      return {
        kind: {
          case: 'image',
          value: { media: mediaInfo(seg.media), width: seg.width ?? 0, height: seg.height ?? 0, summary: seg.summary ?? '', sticker: seg.subType === 'sticker' },
        },
      };
    case 'record':
      return { kind: { case: 'record', value: { media: mediaInfo(seg.media), durationSec: seg.durationSec ?? 0 } } };
    case 'video':
      return {
        kind: {
          case: 'video',
          value: { media: mediaInfo(seg.media), width: seg.width ?? 0, height: seg.height ?? 0, durationSec: seg.durationSec ?? 0 },
        },
      };
    case 'file':
      return { kind: { case: 'file', value: { media: mediaInfo(seg.media), name: seg.name, size: big(seg.size) } } };
    case 'forward':
      return {
        kind: {
          case: 'forward',
          value: { forwardId: seg.forwardId, title: seg.title ?? '', preview: seg.preview ?? [], summary: seg.summary ?? '' },
        },
      };
    case 'market_face':
      return {
        kind: {
          case: 'marketFace',
          value: {
            emojiId: seg.emojiId,
            packageId: big(seg.packageId),
            key: seg.key ?? '',
            summary: seg.summary ?? '',
            ...(seg.media ? { media: mediaInfo(seg.media) } : {}),
          },
        },
      };
    case 'light_app':
      return { kind: { case: 'lightApp', value: { appName: seg.appName, json: seg.json } } };
    case 'xml':
      return { kind: { case: 'xml', value: { serviceId: big(seg.serviceId), xml: seg.xml } } };
    case 'markdown':
      return { kind: { case: 'markdown', value: { content: seg.content } } };
    case 'unknown':
      return {
        kind: { case: 'unknown', value: { original: seg.original, dataJson: seg.data === undefined ? '' : JSON.stringify(seg.data) } },
      };
  }
}

export function messageToProto(m: MessageRow): Message {
  return create(MessageSchema, {
    chatId: big(m.chatId),
    seq: big(m.seq),
    senderId: big(m.senderUin),
    senderName: m.senderName ?? '',
    time: unix(m.time),
    kind: m.kind === 'service' ? MessageKind.SERVICE : m.kind === 'call' ? MessageKind.CALL : MessageKind.NORMAL,
    segments: m.segments.map(segmentToProto),
    text: m.text,
    replyToSeq: big(m.replyToSeq),
    flags: m.flags,
    state: m.state === 'recalled' ? MessageState.RECALLED : MessageState.NORMAL,
    recalledBy: big(m.recalledBy),
    recalledAt: unix(m.recalledAt),
    version: big(m.version),
    reactions: (Array.isArray(m.reactions) ? (m.reactions as DomainReaction[]) : []).map((r) => ({
      emojiId: r.emojiId,
      count: r.count,
      me: Boolean(r.me),
    })),
  });
}

/** 服务事件：群文件的媒体信息单独放进 media 字段，其余放进 data_json。 */
export function chatEventToProto(e: ChatEventRow): ChatEvent {
  const { media, ...data } = e.data as { media?: DomainMediaInfo } & Record<string, unknown>;
  return create(ChatEventSchema, {
    id: big(e.id),
    chatId: big(e.chatId),
    kind: e.kind,
    time: unix(e.time),
    actorId: big(e.actorId),
    targetId: big(e.targetId),
    refSeq: big(e.refSeq),
    dataJson: JSON.stringify(data),
    version: big(e.version),
    ...(media ? { media: mediaInfo(media) } : {}),
  });
}

const CALL_PHASE: Record<CallRecord['phase'], CallPhase> = {
  ringing: CallPhase.RINGING,
  accepting: CallPhase.ACCEPTING,
  // 插件发出接听到 QQ 接通之间有个"accepted"，对客户端来说仍是"正在接通"。
  accepted: CallPhase.ACCEPTING,
  connected: CallPhase.CONNECTED,
  ended: CallPhase.ENDED,
};

export function callToProto(c: CallRecord): Call {
  return create(CallSchema, {
    id: c.callId,
    phase: CALL_PHASE[c.phase],
    media: c.media === 'video' ? CallMedia.VIDEO : CallMedia.VOICE,
    incoming: c.incoming,
    peerUin: big(c.peerUin),
    peerName: c.peerName ?? '',
    inviteAt: unix(c.inviteAt),
    connectedAt: unix(c.connectedAt),
    endedAt: unix(c.endedAt),
    endReason: c.endReason ?? 0,
    answeredDeviceId: big(c.answeredDeviceId),
  });
}

export function dialogToProto(d: DialogRow): Dialog {
  return create(DialogSchema, {
    chatId: big(d.chatId),
    qqAccountId: big(d.qqAccountId),
    scene: sceneToProto(d.scene),
    peerId: big(d.peerId),
    topSeq: big(d.topSeq),
    topTime: unix(d.topTime),
    unreadCount: d.unreadCount,
    unreadMentions: d.unreadMentions,
    unreadMentionAll: d.unreadMentionAll,
    unreadReplies: d.unreadReplies,
    readInboxMaxSeq: big(d.readInboxMaxSeq),
    pinned: d.pinned,
    pinnedAt: unix(d.pinnedAt),
    notifyPolicy: d.notifyPolicy,
    mentionAllNotify: d.mentionAllNotify,
    chatPts: big(d.chatPts),
    dialogPts: big(d.dialogPts),
    ...(d.topMessage ? { topMessage: messageToProto(d.topMessage) } : {}),
    ...(isDraft(d.draft)
      ? {
          draft: {
            segments: d.draft.segments.map(outgoingToProto),
            replyToSeq: big(d.draft.replyToSeq),
            updatedAt: big(d.draft.updatedAt),
          },
        }
      : {}),
  });
}

function isDraft(value: unknown): value is { segments: DomainOutgoingSegment[]; replyToSeq?: number; updatedAt?: number } {
  return Boolean(value) && Array.isArray((value as { segments?: unknown }).segments);
}

export function peerToProto(p: PeerRow): Peer {
  return create(PeerSchema, {
    qqAccountId: big(p.qqAccountId),
    kind: p.kind === 'group' ? PeerKind.GROUP : PeerKind.USER,
    peerId: big(p.peerId),
    name: p.name ?? '',
    remark: p.remark ?? '',
    isFriend: p.isFriend,
    memberCount: p.memberCount ?? 0,
    avatarSha256: p.avatarSha256 ?? '',
    sign: p.sign ?? '',
    muteAll: p.muteAll,
    selfMutedUntil: big(p.selfMutedUntil),
    selfRole: p.selfRole ?? '',
    pts: big(p.pts),
  });
}

export function differenceToProto(d: Difference): ProtoDifference {
  return create(DifferenceSchema, {
    pts: big(d.pts),
    isFinal: d.final,
    tooLong: d.tooLong,
    dialogs: d.dialogs.map(dialogToProto),
    peers: d.peers.map(peerToProto),
    tombstones: d.tombstones.map((t) => ({ pts: big(t.pts), entity: t.entity, key: t.key })),
    outbox: d.outbox.map(outboxToProto),
  });
}

const OUTBOX_STATES: Record<OutboxRow['state'], OutboxState> = {
  pending: OutboxState.PENDING,
  sending: OutboxState.SENDING,
  sent: OutboxState.SENT,
  failed: OutboxState.FAILED,
};

export function outboxToProto(o: OutboxRow): OutboxEntry {
  return create(OutboxEntrySchema, {
    pts: big(o.pts),
    clientRandomId: big(o.clientRandomId),
    chatId: big(o.chatId),
    state: OUTBOX_STATES[o.state] ?? OutboxState.UNSPECIFIED,
    seq: big(o.resultSeq),
    error: o.error ?? '',
    createdAt: unix(o.createdAt),
    segments: o.segments.map(outgoingToProto),
    replyToSeq: big(o.replyToSeq),
  });
}

export function outgoingToProto(seg: DomainOutgoingSegment): MessageInitShape<typeof OutgoingSegmentSchema> {
  switch (seg.type) {
    case 'text':
      return { kind: { case: 'text', value: seg.text } };
    case 'mention':
      return { kind: { case: 'mentionUserId', value: BigInt(seg.userId) } };
    case 'mention_all':
      return { kind: { case: 'mentionAll', value: true } };
    case 'face':
      return { kind: { case: 'faceId', value: seg.faceId } };
    case 'image':
      return { kind: { case: 'image', value: { sha256: seg.sha256, sticker: Boolean(seg.sticker), summary: seg.summary ?? '' } } };
    case 'record':
      return { kind: { case: 'record', value: { sha256: seg.sha256, durationSec: seg.durationSec ?? 0 } } };
    case 'video':
      return { kind: { case: 'video', value: { sha256: seg.sha256 } } };
    case 'file':
      return { kind: { case: 'file', value: { sha256: seg.sha256, name: seg.name } } };
    case 'forward':
      return {
        kind: {
          case: 'forward',
          value: {
            nodes: seg.nodes.map((n) => ({ userId: BigInt(n.userId), nickname: n.nickname, segments: n.segments.map(outgoingToProto) })),
          },
        },
      };
  }
}

/** 客户端的外发消息段 → 领域；不认识的段返回 null（由调用方报 InvalidArgument）。 */
export function outgoingFromProto(seg: OutgoingSegment): DomainOutgoingSegment | null {
  const k = seg.kind;
  switch (k.case) {
    case 'text':
      return { type: 'text', text: k.value };
    case 'mentionUserId':
      return { type: 'mention', userId: toSafeNumber(k.value, 'mention_user_id') };
    case 'mentionAll':
      return { type: 'mention_all' };
    case 'faceId':
      return { type: 'face', faceId: k.value };
    case 'image':
      return {
        type: 'image',
        sha256: k.value.sha256,
        ...(k.value.sticker ? { sticker: true } : {}),
        ...(k.value.summary ? { summary: k.value.summary } : {}),
      };
    case 'record':
      return { type: 'record', sha256: k.value.sha256, ...(k.value.durationSec ? { durationSec: k.value.durationSec } : {}) };
    case 'video':
      return { type: 'video', sha256: k.value.sha256 };
    case 'file':
      return { type: 'file', sha256: k.value.sha256, name: k.value.name };
    default:
      return null;
  }
}

/** 请求里的 int64 → number；超出安全整数范围的值一律拒绝。 */
export function toSafeNumber(value: bigint, field: string): number {
  if (value < BigInt(Number.MIN_SAFE_INTEGER) || value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new RangeError(`${field} is out of range`);
  }
  return Number(value);
}
