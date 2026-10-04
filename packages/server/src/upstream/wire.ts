// 插件 ⇄ 服务端线路协议 v1。与 packages/napcat-plugin-qqbridge/src/upstream/wire.ts 保持一致
// （test/upstream-hub.test.ts 用真实的插件客户端联调，两边不一致会直接失败）。
export const WIRE_VERSION = 1;

export interface QueuedEvent {
  c: number;
  at: number;
  e: unknown;
}

export interface HelloFrame {
  t: 'hello';
  v: number;
  queue: { id: string; first: number; last: number };
  self: { uin: string; uid: string; nick?: string };
  impl: { plugin: string; napcat?: string; qq?: string };
}

export type PluginFrame =
  | HelloFrame
  | { t: 'events'; list: QueuedEvent[] }
  | { t: 'res'; id: string; ok: true; data: unknown }
  | { t: 'res'; id: string; ok: false; error: string };

export type ServerFrame =
  | { t: 'welcome'; resume: number; reset?: boolean }
  | { t: 'ack'; c: number }
  | { t: 'req'; id: string; action: string; params: unknown };
