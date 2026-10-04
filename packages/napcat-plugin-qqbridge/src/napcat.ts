// 插件实际用到的 NapCat 接口的最小结构类型。
// 不直接引用 napcat-types：它发布的是 NapCat 内部 TS 源码，版本漂移时容易连带类型错误；
// 这里只声明我们依赖的那一小部分，访问内核服务的地方一律做运行时守卫。

export interface PluginLogger {
  log(...args: unknown[]): void;
  info(...args: unknown[]): void;
  warn(...args: unknown[]): void;
  error(...args: unknown[]): void;
}

/** OneBot 动作的完整返回（NapCat 的 OB11Return）。 */
export interface ActionResult {
  status: string;
  retcode: number;
  data: unknown;
  message?: string;
}

export interface ActionMapLike {
  /** 成功时只返回 data；data 为空也会被当成失败抛错（例如 mark_*_as_read），需要区分时用 get(...).handle。 */
  call(actionName: string, params: unknown, adapter: string, config: unknown): Promise<unknown>;
  get?(actionName: string): { handle(params: unknown, adapter: string, config: unknown): Promise<ActionResult> } | undefined;
}

export interface PluginRouterLike {
  get(path: string, handler: (req: unknown, res: { json(body: unknown): void }) => void): void;
}

/** NapCatCore 是内部对象，不是稳定契约；只通过 core.ts 里带守卫的辅助函数访问。 */
export type NapCatCoreLike = Record<string, any>;

export interface NapCatPluginContext {
  core: NapCatCoreLike;
  actions: ActionMapLike;
  pluginName: string;
  pluginPath: string;
  configPath: string;
  dataPath: string;
  adapterName: string;
  pluginManager: { config: unknown };
  logger: PluginLogger;
  router: PluginRouterLike;
}

/** OneBot 11 事件（插件适配器为 array 格式且开启 debug，消息事件会附带 raw = NT RawMessage）。 */
export type OB11Event = Record<string, unknown> & {
  time?: number;
  self_id?: number;
  post_type?: string;
  message_type?: string;
  notice_type?: string;
  raw?: Record<string, unknown>;
};
