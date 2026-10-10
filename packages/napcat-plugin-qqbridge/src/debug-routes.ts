// 研究用：看 QQ 内核返回的原始数据（置顶、群消息设置、收藏表情等字段名），只在容器内回环地址、带 token 才能访问。
import type { ControlServer } from './control-server.js';
import type { NapCatPluginContext } from './napcat.js';

/** 只留标量字段和浅层对象，避免把大块数据吐出来。 */
function shallow(value: unknown, depth = 0): unknown {
  if (value === null || typeof value !== 'object') return value;
  if (depth >= 2) return Array.isArray(value) ? `[array ${value.length}]` : '[object]';
  if (Array.isArray(value)) return value.slice(0, 3).map((v) => shallow(v, depth + 1));
  return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, shallow(v, depth + 1)]));
}

export function registerDebugRoutes(server: ControlServer, ctx: NapCatPluginContext): void {
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
      default:
        return { kinds: ['recent', 'groups', 'fav'], apis: Object.keys(apis) };
    }
  });
}
