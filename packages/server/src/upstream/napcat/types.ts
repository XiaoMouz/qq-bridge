// NapCat 事件里用到的 NT 原始结构（只声明映射需要的字段，参考 napcat-types 0.0.17 的
// napcat-core/types/msg.ts 与 element.ts）。字段都可能缺失，映射时一律按可选处理。

export const NtChatType = { friend: 1, group: 2, temp: 100 } as const;

export const NtElementType = {
  TEXT: 1,
  PIC: 2,
  FILE: 3,
  PTT: 4,
  VIDEO: 5,
  FACE: 6,
  REPLY: 7,
  GREY_TIP: 8,
  ARK: 10,
  MFACE: 11,
  MARKDOWN: 14,
  MULTIFORWARD: 16,
  /** 机器人消息下面的按钮（inlineKeyboardElement）。 */
  INLINE_KEYBOARD: 17,
  ONLINE_FILE: 23,
  ONLINE_FOLDER: 30,
} as const;

export interface NtElement {
  elementType: number;
  elementId: string;
  textElement?: { content?: string; atType?: number; atUid?: string; atNtUid?: string };
  faceElement?: { faceIndex?: number; faceType?: number; faceText?: string; resultId?: string };
  marketFaceElement?: { emojiPackageId?: number; faceName?: string; emojiId?: string; key?: string };
  replyElement?: { replayMsgSeq?: string; replayMsgId?: string; senderUin?: string; senderUid?: string };
  picElement?: {
    md5HexStr?: string;
    fileSize?: number | string;
    picWidth?: number;
    picHeight?: number;
    fileName?: string;
    picSubType?: number;
    fileUuid?: string;
    summary?: string;
    originImageUrl?: string;
  };
  pttElement?: { duration?: number; fileName?: string; fileSize?: string; fileUuid?: string; md5HexStr?: string };
  videoElement?: {
    fileName?: string;
    videoMd5?: string;
    fileTime?: number;
    fileSize?: string;
    thumbWidth?: number;
    thumbHeight?: number;
    fileUuid?: string;
  };
  fileElement?: { fileMd5?: string; fileName?: string; fileSize?: string; file10MMd5?: string; fileUuid?: string };
  arkElement?: { bytesData?: string };
  markdownElement?: { content?: string };
  multiForwardMsgElement?: { xmlContent?: string; resId?: string; fileName?: string };
  [key: string]: unknown;
}

export interface NtRawMessage {
  msgId?: string;
  msgRandom?: string;
  msgSeq?: string;
  msgTime?: string;
  chatType?: number;
  senderUid?: string;
  senderUin?: string;
  peerUid?: string;
  peerUin?: string;
  peerName?: string;
  sendNickName?: string;
  sendMemberName?: string;
  sendRemarkName?: string;
  elements?: NtElement[];
  [key: string]: unknown;
}

/** OneBot 11 消息段（NapCat 的 array 格式）。 */
export interface Ob11Segment {
  type: string;
  data?: Record<string, unknown>;
}

/** 插件转发过来的 OneBot 事件（消息事件带 raw = NT RawMessage；撤回通知带 qqbridge.recalled）。 */
export interface NapcatEvent {
  time?: number;
  self_id?: number;
  post_type?: string;
  message_type?: string;
  notice_type?: string;
  sub_type?: string;
  message_id?: number;
  user_id?: number;
  group_id?: number;
  target_id?: number;
  operator_id?: number;
  sender?: { user_id?: number; nickname?: string; card?: string };
  message?: Ob11Segment[] | string;
  raw?: NtRawMessage;
  /** 插件或服务端附上的被操作消息（OneBot 的 message_id 只是 NapCat 的短 id）。recalled 是旧字段名。 */
  qqbridge?: {
    message?: { msgSeq?: string; msgId?: string; chatType?: number; peerUin?: string; peerUid?: string };
    recalled?: { msgSeq?: string; msgId?: string; chatType?: number; peerUin?: string; peerUid?: string };
  };
  [key: string]: unknown;
}
