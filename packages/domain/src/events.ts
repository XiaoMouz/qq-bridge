// 会话里的服务事件（QQ 的"小灰条"）与表情回应。上游的各种通知映射到这里，服务端统一存档并同步给客户端。
import type { IncomingMedia, PeerProfile, Scene } from './types.ts';

export type ChatEventKind =
  | 'member_join'
  | 'member_leave'
  | 'admin_set'
  | 'admin_unset'
  | 'mute'
  | 'unmute'
  | 'card_change'
  | 'title'
  | 'group_name'
  | 'essence_add'
  | 'essence_remove'
  | 'poke'
  | 'friend_add'
  | 'group_file'
  | 'gray_tip'
  /** 通话记录（data：incoming、media、result、durationSec、endReason）。 */
  | 'call';

export interface IncomingChatEvent {
  scene: Scene;
  peerId: number;
  kind: ChatEventKind;
  /** unix 秒。 */
  time: number;
  actorId?: number;
  targetId?: number;
  /** 相关的消息 seq（例如被设为精华的那条）。 */
  refSeq?: number;
  data?: Record<string, unknown>;
  /** 要存档的媒体（群文件）。 */
  media?: IncomingMedia;
  /** 顺带更新的资料（例如改了群名）。 */
  peers?: PeerProfile[];
}

export interface Reaction {
  emojiId: string;
  count: number;
  /** 自己是否也点了这个表情。 */
  me?: boolean;
}

export interface ReactionChange {
  /** 变化的表情及其当前总数（QQ 只给发生变化的那个表情）。 */
  likes: { emojiId: string; count: number }[];
  /** 这次是谁点的；是自己时用 isAdd 更新 me。 */
  byMe: boolean;
  isAdd: boolean;
}

/** 合并一次表情回应变化：更新数量，数量为 0 的移除；保持原有顺序，新表情排在最后。 */
export function applyReactionChange(current: readonly Reaction[], change: ReactionChange): Reaction[] {
  const next = current.map((r) => ({ ...r }));
  for (const like of change.likes) {
    const existing = next.find((r) => r.emojiId === like.emojiId);
    const me = change.byMe ? change.isAdd : (existing?.me ?? false);
    if (existing) {
      existing.count = Math.max(0, like.count);
      existing.me = me;
    } else if (like.count > 0) {
      next.push({ emojiId: like.emojiId, count: like.count, me });
    }
  }
  return next.filter((r) => r.count > 0).map((r) => (r.me ? r : { emojiId: r.emojiId, count: r.count }));
}
