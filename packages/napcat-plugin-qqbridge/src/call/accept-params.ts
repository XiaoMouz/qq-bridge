// 接听参数映射。
// 改写自 ClaudiaGardner/maibot-qq-voice-call（GPL-3.0）bridge/napcat-plugin/index.mjs 的 buildAcceptParams，
// 该映射已在 Linux QQ 的 AVSDK 上验证：来电数组 invite[2] 是本账号，而原生 Accept 的会话键必须用 invite[1]（邀请方）。
// 本项目仅自用、不分发；如需公开发布，衍生部分须遵守 GPL-3.0。

export type AcceptParams = [number, string, string[], number, string, boolean, string];

export function buildAcceptParams(invite: unknown): AcceptParams {
  if (!Array.isArray(invite) || invite.length < 12) {
    throw new Error('AVSDK invite callback is incomplete');
  }
  const params = [invite[0], invite[1], [invite[1]], invite[3], invite[4], Boolean(invite[10]), invite[11]];
  const [kind, inviter, sessionKeys, roomType, roomKey, flag, extra] = params;
  const valid =
    typeof kind === 'number' &&
    typeof inviter === 'string' &&
    Array.isArray(sessionKeys) &&
    sessionKeys.every((item) => typeof item === 'string') &&
    typeof roomType === 'number' &&
    typeof roomKey === 'string' &&
    typeof flag === 'boolean' &&
    typeof extra === 'string';
  if (!valid) throw new Error('AVSDK invite does not match the native Accept signature');
  return params as AcceptParams;
}
