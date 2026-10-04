// 访问 NapCat 内核对象的辅助函数。NapCatCore 不是稳定契约，所以每个入口都做存在性检查，
// 缺失时抛出带名字的错误，便于在 QQ/NapCat 升级后快速定位是哪一个内部接口变了。
import type { NapCatCoreLike } from './napcat.js';

export type Scene = 'friend' | 'group' | 'temp';

/** NT 内核的 ChatType 取值。 */
export const ChatType = { friend: 1, group: 2, temp: 100 } as const;

export interface Peer {
  chatType: number;
  peerUid: string;
  guildId: string;
}

export function requireFn<T extends (...args: any[]) => any>(owner: unknown, name: string, label: string): T {
  const fn = (owner as Record<string, unknown> | null | undefined)?.[name];
  if (typeof fn !== 'function') throw new Error(`NapCat internal API missing: ${label}.${name}`);
  return (fn as (...args: any[]) => any).bind(owner) as T;
}

export function session(core: NapCatCoreLike): Record<string, any> {
  const s = core?.context?.session;
  if (!s) throw new Error('NapCat internal API missing: core.context.session');
  return s;
}

export function selfInfo(core: NapCatCoreLike): { uid: string; uin: string } {
  const uid = String(core?.selfInfo?.uid ?? '');
  const uin = String(core?.selfInfo?.uin ?? '');
  if (!uid || !uin) throw new Error('QQ self identity is not available yet');
  return { uid, uin };
}

export async function uidByUin(core: NapCatCoreLike, uin: string): Promise<string> {
  const uid = await requireFn<(uin: string) => Promise<string>>(core?.apis?.UserApi, 'getUidByUinV2', 'UserApi')(uin);
  if (!uid) throw new Error(`cannot resolve uid for uin ${uin}`);
  return uid;
}

export async function uinByUid(core: NapCatCoreLike, uid: string): Promise<string | null> {
  try {
    const uin = await requireFn<(uid: string) => Promise<string>>(core?.apis?.UserApi, 'getUinByUidV2', 'UserApi')(uid);
    return uin && uin !== '0' ? String(uin) : null;
  } catch {
    return null;
  }
}

export async function displayNameByUid(core: NapCatCoreLike, uid: string): Promise<string | null> {
  try {
    const infos = await requireFn<(uids: string[]) => Promise<Map<string, any>>>(
      core?.apis?.UserApi,
      'getCoreAndBaseInfo',
      'UserApi',
    )([uid]);
    const info = infos?.get?.(uid);
    const name = info?.coreInfo?.remark || info?.coreInfo?.nick || info?.remark || info?.nick;
    return typeof name === 'string' && name.trim() ? name.trim() : null;
  } catch {
    return null;
  }
}

/** 由领域语义 (scene, peer QQ 号/群号) 构造 NT Peer。临时会话需要额外的群号，P0 暂不支持。 */
export async function resolvePeer(core: NapCatCoreLike, scene: Scene, peerId: string): Promise<Peer> {
  switch (scene) {
    case 'group':
      return { chatType: ChatType.group, peerUid: peerId, guildId: '' };
    case 'friend':
      return { chatType: ChatType.friend, peerUid: await uidByUin(core, peerId), guildId: '' };
    default:
      throw new Error('temp scene is not supported by this helper yet');
  }
}

export function msgApi(core: NapCatCoreLike): Record<string, any> {
  const api = core?.apis?.MsgApi;
  if (!api) throw new Error('NapCat internal API missing: core.apis.MsgApi');
  return api;
}
