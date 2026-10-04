// 调用 OneBot 动作并区分成败：NapCat 的 actions.call 会把"成功但没有返回数据"也当成失败，这里改用完整返回判断。
import type { NapCatPluginContext } from '../napcat.js';

export async function callAction(ctx: NapCatPluginContext, name: string, params: unknown): Promise<unknown> {
  const action = ctx.actions.get?.(name);
  if (!action) return ctx.actions.call(name, params, ctx.adapterName, ctx.pluginManager.config);
  const res = await action.handle(params, ctx.adapterName, ctx.pluginManager.config);
  if (res.status !== 'ok') throw new Error(res.message || `${name} failed (retcode ${res.retcode})`);
  return res.data ?? null;
}
