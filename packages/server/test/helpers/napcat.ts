// 按 NapCat 真实结构构造的事件样本（字段取自 napcat-types 0.0.17 与 NapCat 的 OB11 转换代码）。
// P0 采到真实样本后，这里的样本以 fixtures/ 里的脱敏数据为准再校对一遍。
import type { NapcatEvent, NtElement, NtRawMessage } from '../../src/upstream/napcat/types.ts';

let elementCounter = 7_000_000_000_000_000_000n;
const nextElementId = () => String(++elementCounter);

export const el = {
  text: (content: string): NtElement => ({ elementType: 1, elementId: nextElementId(), textElement: { content, atType: 0 } }),
  at: (uin: string, name: string): NtElement => ({
    elementType: 1,
    elementId: nextElementId(),
    textElement: { content: `@${name}`, atType: 2, atUid: uin, atNtUid: `u_${uin}` },
  }),
  atAll: (): NtElement => ({ elementType: 1, elementId: nextElementId(), textElement: { content: '@全体成员', atType: 1, atUid: '0' } }),
  face: (faceIndex: number, faceType = 2, resultId?: string): NtElement => ({
    elementType: 6,
    elementId: nextElementId(),
    faceElement: { faceIndex, faceType, ...(resultId ? { resultId } : {}) },
  }),
  reply: (seq: number, senderUin: string): NtElement => ({
    elementType: 7,
    elementId: nextElementId(),
    replyElement: { replayMsgSeq: String(seq), replayMsgId: '7400000000000000001', senderUin },
  }),
  pic: (o: { md5: string; size: number; w: number; h: number; name?: string; sticker?: boolean }): NtElement => ({
    elementType: 2,
    elementId: nextElementId(),
    picElement: {
      md5HexStr: o.md5.toUpperCase(),
      fileSize: String(o.size),
      picWidth: o.w,
      picHeight: o.h,
      fileName: o.name ?? `${o.md5.toUpperCase()}.jpg`,
      picSubType: o.sticker ? 1 : 0,
      fileUuid: `uuid-${o.md5.slice(0, 8)}`,
      summary: o.sticker ? '[动画表情]' : '',
      originImageUrl: `/download?appid=1407&fileid=${o.md5.slice(0, 12)}`,
    },
  }),
  ptt: (o: { md5: string; size: number; duration: number }): NtElement => ({
    elementType: 4,
    elementId: nextElementId(),
    pttElement: { md5HexStr: o.md5, fileSize: String(o.size), duration: o.duration, fileName: `${o.md5}.amr`, fileUuid: `ptt-${o.md5.slice(0, 6)}` },
  }),
  video: (o: { md5: string; size: number; w: number; h: number; seconds: number }): NtElement => ({
    elementType: 5,
    elementId: nextElementId(),
    videoElement: {
      videoMd5: o.md5,
      fileSize: String(o.size),
      thumbWidth: o.w,
      thumbHeight: o.h,
      fileTime: o.seconds,
      fileName: `${o.md5}.mp4`,
      fileUuid: `video-${o.md5.slice(0, 6)}`,
    },
  }),
  file: (o: { name: string; size: number; md5?: string; head?: string }): NtElement => ({
    elementType: 3,
    elementId: nextElementId(),
    fileElement: {
      fileName: o.name,
      fileSize: String(o.size),
      ...(o.md5 ? { fileMd5: o.md5 } : {}),
      ...(o.head ? { file10MMd5: o.head } : {}),
      fileUuid: `/file-${o.name}`,
    },
  }),
  mface: (emojiId: string, name: string): NtElement => ({
    elementType: 11,
    elementId: nextElementId(),
    marketFaceElement: { emojiId, emojiPackageId: 1234, faceName: name, key: 'k1' },
  }),
  forward: (resId: string, xml: string): NtElement => ({
    elementType: 16,
    elementId: nextElementId(),
    multiForwardMsgElement: { resId, xmlContent: xml, fileName: 'MultiMsg' },
  }),
  ark: (json: string): NtElement => ({ elementType: 10, elementId: nextElementId(), arkElement: { bytesData: json } }),
  unknown: (elementType: number): NtElement => ({ elementType, elementId: nextElementId(), calendarElement: { summary: 'x' } }),
};

let msgIdCounter = 7_400_000_000_000_000_000n;

export function raw(o: {
  chatType: 1 | 2 | 100 | 8;
  peer: string;
  peerUid?: string;
  seq: number;
  sender: string;
  time?: number;
  elements: NtElement[];
  peerName?: string;
  sendNickName?: string;
}): NtRawMessage {
  return {
    msgId: String(++msgIdCounter),
    msgRandom: '123456789',
    msgSeq: String(o.seq),
    msgTime: String(o.time ?? 1_700_000_000 + o.seq),
    chatType: o.chatType,
    senderUid: `u_${o.sender}`,
    senderUin: o.sender,
    peerUid: o.peerUid ?? (o.chatType === 2 ? o.peer : `u_${o.peer}`),
    peerUin: o.peer,
    peerName: o.peerName ?? '',
    sendNickName: o.sendNickName ?? '',
    sendMemberName: '',
    sendRemarkName: '',
    elements: o.elements,
  };
}

/** 实时消息事件：NapCat 的 OB11 消息 + raw（插件适配器 debug 模式）。 */
export function messageEvent(r: NtRawMessage, opts: { self?: boolean; ob11?: NapcatEvent['message']; nickname?: string } = {}): NapcatEvent {
  const group = r.chatType === 2;
  return {
    time: Number(r.msgTime),
    self_id: 10001,
    post_type: opts.self ? 'message_sent' : 'message',
    message_type: group ? 'group' : 'private',
    sub_type: group ? 'normal' : 'friend',
    message_id: 12345,
    user_id: Number(r.senderUin),
    ...(group ? { group_id: Number(r.peerUin) } : {}),
    ...(opts.self && !group ? { target_id: Number(r.peerUin) } : {}),
    sender: { user_id: Number(r.senderUin), nickname: opts.nickname ?? `nick-${r.senderUin}`, card: '' },
    message: opts.ob11 ?? [],
    raw: r,
  };
}
