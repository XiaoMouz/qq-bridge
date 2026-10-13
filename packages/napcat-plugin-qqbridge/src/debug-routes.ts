// 研究用：看 QQ 内核返回的原始数据（置顶、群消息设置、收藏表情等字段名），只在容器内回环地址、带 token 才能访问。
import type { ControlServer } from './control-server.js';
import type { NapCatPluginContext } from './napcat.js';
import { callAction } from './upstream/actions.js';
import { createHandlers } from './upstream/handlers.js';

/** 只留标量字段和浅层对象，避免把大块数据吐出来。 */
function shallow(value: unknown, depth = 0, max = 2): unknown {
  if (value === null || typeof value !== 'object') return value;
  if (depth >= max) return Array.isArray(value) ? `[array ${value.length}]` : '[object]';
  if (Array.isArray(value)) return value.slice(0, 3).map((v) => shallow(v, depth + 1, max));
  return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, shallow(v, depth + 1, max)]));
}

export function registerDebugRoutes(server: ControlServer, ctx: NapCatPluginContext): void {
  // 直接调一个服务端用的 RPC（x.ptt_text 等），不经上游链路：POST {"name":"x.ptt_text","params":{...}}
  server.route('POST', '/v1/debug/rpc', async ({ body }) => {
    const { name, params } = (body ?? {}) as { name?: string; params?: unknown };
    const handler = name ? createHandlers(ctx)[name] : undefined;
    if (!handler) return { code: -1, message: `unknown rpc ${name}` };
    return { code: 0, data: await handler(params as never) };
  });
  server.route('GET', '/v1/debug/raw', async (req) => {
    const kind = req.url.searchParams.get('kind');
    const apis = (ctx.core as any)?.apis ?? {};
    switch (kind) {
      case 'recent': {
        const snap = await apis.UserApi.getRecentContactListSnapShot(5);
        return shallow(snap?.info?.changedList ?? snap);
      }
      case 'masks': {
        const groups: any[] = (await apis.GroupApi.getGroups(false)) ?? [];
        const count: Record<string, number> = {};
        for (const g of groups) count[`mask=${g.cmdUinMsgMask} top=${g.isTop}`] = (count[`mask=${g.cmdUinMsgMask} top=${g.isTop}`] ?? 0) + 1;
        return count;
      }
      case 'groups': {
        const groups = await apis.GroupApi.getGroups(false);
        return shallow(Array.isArray(groups) ? groups.slice(0, 3) : groups);
      }
      case 'fav': {
        const fav = await apis.MsgApi.fetchFavEmojiList(3);
        return { ...(shallow(fav) as object), first: fav?.emojiInfoList?.[0] };
      }
      case 'ob11': {
        // 看 OneBot 动作的返回：?kind=ob11&name=get_group_root_files&params={"group_id":"1"}
        const name = req.url.searchParams.get('name') ?? '';
        const params = JSON.parse(req.url.searchParams.get('params') ?? '{}');
        return shallow(await callAction(ctx, name, params), 0, 5);
      }
      case 'history': {
        // 看某个群某段的原始消息（灰条等 OneBot 不转发的元素）：?kind=history&group=1&seq=100&count=10
        const peer = { chatType: 2, peerUid: req.url.searchParams.get('group') ?? '', guildId: '' };
        const res = await apis.MsgApi.getMsgsBySeqAndCount(peer, req.url.searchParams.get('seq') ?? '0', Number(req.url.searchParams.get('count') ?? 10), true, true);
        return (res?.msgList ?? []).map((m: any) => ({
          msgSeq: m.msgSeq, msgType: m.msgType, subMsgType: m.subMsgType, senderUin: m.senderUin, sendMemberName: m.sendMemberName, msgTime: m.msgTime,
          elements: (m.elements ?? []).filter((e: any) => e.elementType !== 1 && e.elementType !== 2).map((e: any) => shallow(e, 0, 6)),
        }));
      }
      case 'webnotice': {
        const res = await apis.WebApi.getGroupNotice(req.url.searchParams.get('group') ?? '');
        const feed = (res?.feeds ?? [])[0];
        return { keys: Object.keys(res ?? {}), feedKeys: Object.keys(feed ?? {}), feed: shallow(feed, 0, 4), inst: shallow((res?.inst ?? [])[0], 0, 4) };
      }
      case 'methods': {
        // 看内核某个 service 有哪些方法：?kind=methods&service=getGroupService&match=ulletin
        const s = (ctx.core as any)?.context?.session;
        const name = req.url.searchParams.get('service') ?? 'getGroupService';
        const svc = typeof s?.[name] === 'function' ? s[name]() : null;
        const match = req.url.searchParams.get('match') ?? '';
        const names = new Set<string>();
        for (let o = svc; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) for (const k of Object.getOwnPropertyNames(o)) names.add(k);
        return [...names].filter((k) => k.toLowerCase().includes(match.toLowerCase())).sort();
      }
      default:
        return { kinds: ['recent', 'groups', 'fav', 'ob11', 'history', 'methods'], apis: Object.keys(apis) };
    }
  });
}
