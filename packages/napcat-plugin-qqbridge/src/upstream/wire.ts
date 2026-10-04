// 插件 ⇄ 服务端的线路协议（JSON over WebSocket，v1）。服务端的对应定义在
// packages/server/src/upstream/wire.ts，两边改动必须同步（服务端测试里用真实的插件客户端联调）。
//
// 连接：插件主动连 ws(s)://<server>/upstream/napcat，带 Authorization: Bearer <UPSTREAM_TOKEN>。
// 流程：hello →（服务端）welcome{resume} → 插件从 resume+1 开始批量发送 events → 服务端落库后回 ack{c}（累计确认）。
// 服务端可随时发 req 调用插件（换媒体链接、按 seq 拉历史、调用 OneBot 动作），插件回 res。
import type { QueuedEvent } from './queue.js';

export const WIRE_VERSION = 1;

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
  /** resume：服务端已持久保存的最大游标。reset = true 表示服务端的记录比插件新（例如插件数据目录被还原），插件应换一个新队列 id 重新开始。 */
  | { t: 'welcome'; resume: number; reset?: boolean }
  | { t: 'ack'; c: number }
  | { t: 'req'; id: string; action: string; params: unknown };
