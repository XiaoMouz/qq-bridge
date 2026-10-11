// 服务端可以调用的插件动作（经上游连接的 req/res）。只做"取数"，不在插件里做业务判断：
// 返回 NT 原始结构，由服务端统一映射（docs/design.md 4.3：映射放在服务端）。
import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { ChatType, msgApi, requireFn, uidByUin, type Peer } from '../core.js';
import type { NapCatPluginContext } from '../napcat.js';
import { callAction } from './actions.js';
import type { RpcHandler } from './link.js';
import type { SendParams, Sender } from './sender.js';
import { unwrapFileUuid } from './file-uuid.js';

/** 服务端存在 media_refs.locator 里的定位信息，换新下载链接时原样传回来。 */
export interface MediaLocator {
  chatType: number;
  peerUid: string;
  msgId: string;
  elementId: string;
  elementType: number;
  fileUuid?: string;
  file10MMd5?: string;
  originImageUrl?: string;
  md5HexStr?: string;
}

const ElementType = { PIC: 2, FILE: 3, PTT: 4, VIDEO: 5 } as const;
const URL_TIMEOUT_MS = 5000;

/** 通话桥里服务端会用到的部分（通话桥关闭时为 null）。 */
export interface CallControl {
  current(): unknown;
  accept(): Promise<unknown>;
  status(): Record<string, unknown>;
}

export function createHandlers(ctx: NapCatPluginContext, deps: { sender?: Sender; calls?: CallControl | null } = {}): Record<string, RpcHandler> {
  const fileApi = () => {
    const api = ctx.core?.apis?.FileApi;
    if (!api) throw new Error('NapCat internal API missing: core.apis.FileApi');
    return api as Record<string, any>;
  };

  const calls = () => {
    if (!deps.calls) throw new Error('call bridge is off (QQBRIDGE_CALLS=0)');
    return deps.calls;
  };

  return {
    /** 当前通话（服务端重连后用来对齐状态）。 */
    'x.call.current': async () => calls().current(),
    /** iPhone 端经服务端接听：服务端先让网关进好房间，再调这个。 */
    'x.call.accept': async () => calls().accept(),
    /** 通话桥健康状态（管理页用）；通话桥关闭时 enabled = false。 */
    'x.call.status': async () => {
      if (!deps.calls) return { enabled: false };
      const { serviceMethods: _omit, ...status } = deps.calls.status();
      return { enabled: true, ...status };
    },

    /** 透传 OneBot 动作（例如已读回写 mark_*_as_read）。 */
    ob11: async (params: { name?: unknown; params?: unknown }) => {
      if (typeof params?.name !== 'string' || !params.name) throw new Error('ob11: name is required');
      return callAction(ctx, params.name, params.params ?? {});
    },

    /** 发送消息：按 clientRandomId 去重（见 sender.ts）。 */
    'x.send': async (params: SendParams) => {
      if (!deps.sender) throw new Error('x.send: sender is not available');
      return deps.sender.send(params);
    },

    /** 撤回：自己的消息（2 分钟内），或群管理员撤回别人的。结果以 QQ 的撤回通知为准。 */
    'x.recall': async (params: { chatType?: number; peerUid?: string; peerUin?: string; msgId?: string }) => {
      if (!params?.msgId) throw new Error('x.recall: msgId is required');
      const peer = await historyPeer(ctx, params);
      await msgApi(ctx.core).recallMsg(peer, String(params.msgId));
      return { ok: true };
    },

    /** 最近会话及每个会话的最新一条原始消息（服务端据此对账和预热）。 */
    'x.recent_contacts': async (params: { count?: number }) => {
      const count = clamp(params?.count, 1, 500, 200);
      const snapshot = await requireFn<(n: number) => Promise<any>>(
        ctx.core?.apis?.UserApi,
        'getRecentContactListSnapShot',
        'UserApi',
      )(count);
      const list: any[] = Array.isArray(snapshot?.info?.changedList) ? snapshot.info.changedList : [];
      const api = msgApi(ctx.core);
      return Promise.all(
        list.map(async (c) => {
          let latest: unknown = null;
          try {
            const res = await api.getMsgsByMsgId({ chatType: c.chatType, peerUid: c.peerUid, guildId: '' }, [c.msgId]);
            latest = res?.msgList?.[0] ?? null;
          } catch {
            latest = null;
          }
          return {
            chatType: c.chatType,
            peerUid: String(c.peerUid ?? ''),
            peerUin: String(c.peerUin ?? ''),
            peerName: String(c.peerName ?? ''),
            remark: String(c.remark ?? ''),
            msgTime: String(c.msgTime ?? ''),
            latest,
          };
        }),
      );
    },

    /**
     * 按 seq 拉原始历史消息。fromSeq 为空时取最新的 count 条；否则从 fromSeq 起往更早拉（desc，默认），
     * includeCurrent 表示是否包含 fromSeq 本身（默认包含）。参数顺序与 NapCat 自己按 seq 取消息时一致：
     * getMsgsBySeqAndCount(peer, seq, count, isReverseOrder, isIncludeCurrent)。分页语义由 P0 采样确认。
     * 好友会话需要 NT uid：服务端知道就直接给 peerUid，否则用 peerUin 现查。
     */
    'x.history': async (params: {
      chatType?: number;
      peerUid?: string;
      peerUin?: string;
      fromSeq?: string;
      count?: number;
      desc?: boolean;
      includeCurrent?: boolean;
    }) => {
      const peer = await historyPeer(ctx, params);
      const count = clamp(params?.count, 1, 100, 20);
      const api = msgApi(ctx.core);
      const res = params.fromSeq
        ? await api.getMsgsBySeqAndCount(peer, String(params.fromSeq), count, params.desc !== false, params.includeCurrent !== false)
        : await api.getAioFirstViewLatestMsgs(peer, count);
      const msgList: unknown[] = Array.isArray(res?.msgList) ? res.msgList : [];
      return { peer, result: res?.result ?? 0, errMsg: res?.errMsg ?? '', messages: msgList };
    },

    /**
     * QQ 里的会话设置（一次拿全，不逐个请求）：群的消息设置（cmdUinMsgMask：1 接收并提醒、2 收进群助手、3 屏蔽、4 接收不提醒）
     * 与置顶；最近会话的置顶、免打扰和未读数（服务端据此同步"在别的设备上已读"）。
     */
    'x.chat_settings': async () => {
      const apis = (ctx.core as any)?.apis ?? {};
      const groups: any[] = (await requireFn<(force: boolean) => Promise<any[]>>(apis.GroupApi, 'getGroups', 'GroupApi')(false)) ?? [];
      const snapshot = await requireFn<(n: number) => Promise<any>>(apis.UserApi, 'getRecentContactListSnapShot', 'UserApi')(500);
      const recent: any[] = Array.isArray(snapshot?.info?.changedList) ? snapshot.info.changedList : [];
      return {
        groups: groups.map((g) => ({
          groupCode: String(g.groupCode ?? ''),
          msgMask: Number(g.cmdUinMsgMask ?? 0),
          isTop: Boolean(g.isTop),
          toppedAtMs: String(g.toppedTimestamp ?? '0'),
        })),
        recent: recent.map((c) => ({
          chatType: Number(c.chatType),
          peerUin: String(c.peerUin ?? ''),
          topFlag: Number(c.topFlag ?? 0),
          topFlagTime: String(c.topFlagTime ?? '0'),
          isMsgDisturb: Boolean(c.isMsgDisturb),
          unreadCnt: String(c.unreadCnt ?? '0'),
          msgSeq: String(c.msgSeq ?? '0'),
        })),
      };
    },

    /** 我收藏的表情（一次拿全）：md5、公开的图片地址、是否商城表情、描述。 */
    'x.fav_emojis': async (params: { count?: number }) => {
      const res = await requireFn<(n: number) => Promise<any>>(msgApi(ctx.core), 'fetchFavEmojiList', 'MsgApi')(clamp(params?.count, 1, 2000, 2000));
      const list: any[] = Array.isArray(res?.emojiInfoList) ? res.emojiInfoList : [];
      return {
        total: Number(res?.totalCnt ?? list.length),
        emojis: list.map((e) => ({
          md5: String(e.md5 ?? '').toLowerCase(),
          url: String(e.url ?? ''),
          isMarkFace: Boolean(e.isMarkFace),
          desc: String(e.desc ?? ''),
        })),
      };
    },

    /**
     * 加到"我的表情"（QQ 收藏表情）：QQ 只认本地文件，先从服务端的签名链接下载到临时目录，加完删掉。
     */
    'x.add_fav_emoji': async (params: { url?: string; name?: string }) => {
      if (!params?.url) throw new Error('x.add_fav_emoji: url is required');
      const res = await fetch(params.url, { signal: AbortSignal.timeout(60_000) });
      if (!res.ok) throw new Error(`x.add_fav_emoji: download failed: HTTP ${res.status}`);
      const data = Buffer.from(await res.arrayBuffer());
      const ext = path.extname(params.name ?? '') || '.png';
      const file = path.join(os.tmpdir(), `qqbridge-fav-${randomUUID()}${ext}`);
      await fs.writeFile(file, data);
      try {
        const add = requireFn<(p: Record<string, unknown>) => Promise<any>>(msgApi(ctx.core), 'addFavEmoji', 'MsgApi');
        const result = await add({
          emojiId: '',
          packageId: 0,
          emojiPath: file,
          fileSize: String(data.length),
          fileName: path.basename(file),
          md5: createHash('md5').update(data).digest('hex'),
          isMarkFace: false,
          isOrigin: true,
        });
        if (result && typeof result.result === 'number' && result.result !== 0) {
          throw new Error(`x.add_fav_emoji: ${result.errMsg || `QQ error ${result.result}`}`);
        }
        return { ok: true };
      } finally {
        await fs.rm(file, { force: true });
      }
    },

    /** 表情回应：加或取消自己对某条消息（按 seq）的回应。 */
    'x.react': async (params: { chatType?: number; peerUid?: string; peerUin?: string; seq?: string; emojiId?: string; add?: boolean }) => {
      if (!params?.seq || !params.emojiId) throw new Error('x.react: seq and emojiId are required');
      const peer = await historyPeer(ctx, params);
      const setEmojiLike = requireFn<(...a: unknown[]) => Promise<{ result?: number; errMsg?: string }>>(msgApi(ctx.core), 'setEmojiLike', 'MsgApi');
      const res = await setEmojiLike(peer, String(params.seq), String(params.emojiId), params.add !== false);
      if (res?.result) throw new Error(`setEmojiLike failed: ${res.result} ${res.errMsg ?? ''}`);
      return { ok: true };
    },

    /**
     * 合并转发的内容（原始消息）。rootMsgId 是合并转发所在消息的 NT msgId；
     * 展开嵌套的合并转发时 parentMsgId 是上一层里那个节点的 msgId，最外层与 rootMsgId 相同。
     */
    'x.forward': async (params: { chatType?: number; peerUid?: string; peerUin?: string; rootMsgId?: string; parentMsgId?: string }) => {
      if (!params?.rootMsgId) throw new Error('x.forward: rootMsgId is required');
      const peer = await historyPeer(ctx, params);
      const getMultiMsg = requireFn<(...a: unknown[]) => Promise<{ result?: number; errMsg?: string; msgList?: unknown[] }>>(msgApi(ctx.core), 'getMultiMsg', 'MsgApi');
      const res = await getMultiMsg(peer, String(params.rootMsgId), String(params.parentMsgId || params.rootMsgId));
      return { result: res?.result ?? 0, errMsg: res?.errMsg ?? '', messages: Array.isArray(res?.msgList) ? res.msgList : [] };
    },

    /** 按 resid 拉合并转发的内容（用卡片发的聊天记录、或 getMultiMsg 拿不到的嵌套记录）。 */
    'x.forward_by_resid': async (params: { resId?: string }) => {
      if (!params?.resId) throw new Error('x.forward_by_resid: resId is required');
      const fetch = requireFn<(resId: string) => Promise<unknown[]>>(ctx.core?.apis?.PacketApi?.pkt?.operation, 'FetchForwardMsg', 'PacketApi');
      const messages = await fetch(String(params.resId));
      return { result: 0, messages: Array.isArray(messages) ? messages : [] };
    },

    /** 媒体换新下载链接（QQ 的链接带 rkey，会过期）。拿不到返回 url = null。 */
    'x.media_url': async (locator: MediaLocator) => {
      if (!locator || typeof locator.elementType !== 'number') throw new Error('x.media_url: locator is required');
      const api = fileApi();
      const peerUid = String(locator.peerUid ?? '');
      switch (locator.elementType) {
        case ElementType.PIC: {
          const url = await api.getImageUrl?.({ originImageUrl: locator.originImageUrl, md5HexStr: locator.md5HexStr });
          return { url: nonEmpty(url) };
        }
        case ElementType.VIDEO: {
          try {
            const urls = await api.getVideoUrl?.({ chatType: locator.chatType, peerUid, guildId: '0' }, locator.msgId, locator.elementId);
            const found = Array.isArray(urls) ? urls.find((u: any) => u?.url) : null;
            if (found?.url) return { url: String(found.url) };
          } catch {
            // 退回到 packet 方式
          }
          const fileUuid = locator.fileUuid;
          if (!fileUuid || !api.getVideoUrlPacket) return { url: null };
          return { url: await packetUrl(() => api.getVideoUrlPacket(peerUid, unwrapFileUuid(fileUuid), URL_TIMEOUT_MS)) };
        }
        case ElementType.PTT:
          if (!locator.fileUuid || !api.getPttUrl) return { url: null };
          return { url: await packetUrl(() => api.getPttUrl(peerUid, locator.fileUuid, URL_TIMEOUT_MS)) };
        case ElementType.FILE:
          if (!locator.fileUuid || !api.getFileUrl) return { url: null };
          return {
            url: await packetUrl(() => api.getFileUrl(locator.chatType, peerUid, locator.fileUuid, locator.file10MMd5, URL_TIMEOUT_MS)),
          };
        default:
          return { url: null };
      }
    },
  };
}

async function historyPeer(
  ctx: NapCatPluginContext,
  params: { chatType?: number; peerUid?: string; peerUin?: string },
): Promise<Peer> {
  const chatType = Number(params?.chatType);
  if (chatType === ChatType.group) {
    const code = params.peerUid || params.peerUin;
    if (!code) throw new Error('x.history: group code is required');
    return { chatType, peerUid: String(code), guildId: '' };
  }
  if (chatType === ChatType.friend || chatType === ChatType.temp) {
    const uid = params.peerUid || (params.peerUin ? await uidByUin(ctx.core, String(params.peerUin)) : '');
    if (!uid) throw new Error('x.history: peerUid or peerUin is required');
    return { chatType, peerUid: uid, guildId: '' };
  }
  throw new Error(`x.history: unsupported chatType ${params?.chatType}`);
}

function clamp(value: unknown, min: number, max: number, fallback: number): number {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.max(min, Math.min(Math.floor(n), max));
}

/**
 * 经 packet 换链接。QQ 服务器回了包、但里面没有下载信息时（资源已过期或被删），NapCat 会在读
 * `download.info` 时抛 TypeError——这是"拿不到了"，返回 null，让服务端记为过期而不是反复重试。
 */
async function packetUrl(fn: () => Promise<unknown>): Promise<string | null> {
  try {
    return nonEmpty(await fn());
  } catch (error) {
    if (error instanceof TypeError && /reading '(info|download|domain)'/.test(error.message)) return null;
    throw error;
  }
}

function nonEmpty(url: unknown): string | null {
  return typeof url === 'string' && url.length > 0 ? url : null;
}
