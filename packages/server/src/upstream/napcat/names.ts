// QQ 的群名片 / 发送者名字有时被灰条或消息摘要占掉：
// 「A邀请B进入群聊，点击欢迎...」「A邀请了“B”加入群聊点击欢迎」「A邀请您参加某某活动」「A：[图片]…」。
// 这些不是真名字，当作没有（显示昵称）。

const INVITE_TIP = /邀请.*([进加]入了?群聊|参加)/;
const ABSTRACT = /：/;
const ABSTRACT_TAIL = /\[(图片|动画表情|表情|语音|视频|文件)\]|(…|\.\.\.)$/;

/** 是不是被灰条 / 消息摘要占掉的假名字。 */
export function isBogusMemberName(name: string | null | undefined): boolean {
  if (!name) return false;
  return INVITE_TIP.test(name) || (ABSTRACT.test(name) && ABSTRACT_TAIL.test(name));
}

/** 真名字或 undefined。 */
export function realMemberName(name: unknown): string | undefined {
  if (typeof name !== 'string' || !name.trim()) return undefined;
  return isBogusMemberName(name) ? undefined : name;
}
