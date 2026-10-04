// P0 采样器：记录真实事件，探测媒体链接有效期，并提供几条研究用的只读查询接口。
// 这些结论决定领域模型（seq 语义、去重键、媒体刷新策略），见 docs/design.md 第 7 节 P0。
import type { CaptureWriter } from './capture.js';
import { HttpError, type ControlServer } from './control-server.js';
import { msgApi, resolvePeer, type Scene } from './core.js';
import type { NapCatPluginContext, OB11Event } from './napcat.js';
import { redactUrl } from './redact.js';

/** 链接有效期探测的时间点：从收到消息起算。 */
const URL_PROBE_OFFSETS_MS = [60_000, 15 * 60_000, 60 * 60_000, 6 * 3600_000, 24 * 3600_000];
const MAX_TRACKED_URLS = 60;
const MEDIA_SEGMENT_TYPES = new Set(['image', 'record', 'video', 'file', 'mface']);

export class Probe {
  private readonly timers = new Set<NodeJS.Timeout>();
  private trackedUrls = 0;

  constructor(
    private readonly ctx: NapCatPluginContext,
    private readonly capture: CaptureWriter,
    private readonly probeMediaUrls: boolean,
  ) {}

  /** 插件对每个事件都会调用；这里只做轻量记录，耗时操作都异步排队，不阻塞 NapCat 的事件分发。 */
  onEvent(event: OB11Event): void {
    this.capture.write('events', { event });
    if (this.probeMediaUrls && (event.post_type === 'message' || event.post_type === 'message_sent')) {
      this.scheduleUrlProbes(event);
    }
  }

  registerRoutes(server: ControlServer): void {
    server.route('GET', '/x/recent_contacts', async ({ url }) =>
      this.action('get_recent_contact', { count: intParam(url, 'count', 50) }),
    );

    // 按 seq 拉取原始 NT 消息：验证"能否按 seq 区间精确补历史"。
    server.route('GET', '/x/history_by_seq', async ({ url }) => {
      const peer = await resolvePeer(this.ctx.core, sceneParam(url), requiredParam(url, 'peer'));
      const seq = requiredParam(url, 'seq');
      const count = intParam(url, 'count', 20);
      const desc = url.searchParams.get('desc') !== '0';
      const result = await msgApi(this.ctx.core).getMsgsBySeqAndCount(peer, seq, count, desc, false);
      return summarizeHistory(result);
    });

    server.route('GET', '/x/history_latest', async ({ url }) => {
      const peer = await resolvePeer(this.ctx.core, sceneParam(url), requiredParam(url, 'peer'));
      const result = await msgApi(this.ctx.core).getAioFirstViewLatestMsgs(peer, intParam(url, 'count', 20));
      return summarizeHistory(result);
    });

    // 研究用：直接调用任意 OneBot 动作（只在回环地址 + token 下可用）。
    server.route('POST', '/x/action', async ({ body }) => {
      const { action, params } = (body ?? {}) as { action?: unknown; params?: unknown };
      if (typeof action !== 'string' || !action) throw new HttpError(400, 'action is required');
      return this.action(action, params ?? {});
    });
  }

  close(): void {
    for (const timer of this.timers) clearTimeout(timer);
    this.timers.clear();
  }

  private action(name: string, params: unknown): Promise<unknown> {
    return this.ctx.actions.call(name, params, this.ctx.adapterName, this.ctx.pluginManager.config);
  }

  private scheduleUrlProbes(event: OB11Event): void {
    const segments = Array.isArray(event.message) ? (event.message as { type?: string; data?: any }[]) : [];
    const raw = event.raw ?? {};
    const messageKey = {
      chatType: raw.chatType,
      peerUin: raw.peerUin,
      msgSeq: raw.msgSeq,
      msgId: raw.msgId,
    };
    segments.forEach((segment, index) => {
      const url = segment?.data?.url;
      if (!segment?.type || !MEDIA_SEGMENT_TYPES.has(segment.type)) return;
      if (typeof url !== 'string' || !/^https?:\/\//.test(url)) return;
      if (this.trackedUrls >= MAX_TRACKED_URLS) return;
      this.trackedUrls += 1;
      const startedAt = Date.now();
      for (const offset of URL_PROBE_OFFSETS_MS) {
        const timer = setTimeout(() => {
          this.timers.delete(timer);
          void this.probeUrl(url, { ...messageKey, segmentIndex: index, segmentType: segment.type, offsetMs: offset, startedAt });
        }, offset);
        timer.unref?.();
        this.timers.add(timer);
      }
    });
  }

  private async probeUrl(url: string, meta: Record<string, unknown>): Promise<void> {
    const record: Record<string, unknown> = { ...meta, url: redactUrl(url) };
    try {
      // 只取 1 个字节，避免真的下载大文件；部分服务器不支持 HEAD。
      const response = await fetch(url, { headers: { Range: 'bytes=0-0' }, signal: AbortSignal.timeout(15_000) });
      record.status = response.status;
      record.contentRange = response.headers.get('content-range');
      record.contentType = response.headers.get('content-type');
      await response.body?.cancel();
    } catch (error) {
      record.error = error instanceof Error ? error.message : String(error);
    }
    this.capture.write('url-probes', record);
  }
}

function summarizeHistory(result: any): unknown {
  const list: any[] = Array.isArray(result?.msgList) ? result.msgList : [];
  return {
    result: result?.result,
    errMsg: result?.errMsg,
    count: list.length,
    messages: list.map((msg) => ({
      msgId: msg.msgId,
      msgSeq: msg.msgSeq,
      msgRandom: msg.msgRandom,
      clientSeq: msg.clientSeq,
      msgTime: msg.msgTime,
      msgType: msg.msgType,
      senderUin: msg.senderUin,
      peerUin: msg.peerUin,
      elementTypes: Array.isArray(msg.elements) ? msg.elements.map((el: any) => el?.elementType) : [],
    })),
  };
}

function sceneParam(url: URL): Scene {
  const scene = url.searchParams.get('scene');
  if (scene !== 'friend' && scene !== 'group') throw new HttpError(400, 'scene must be friend or group');
  return scene;
}

function requiredParam(url: URL, name: string): string {
  const value = url.searchParams.get(name);
  if (!value) throw new HttpError(400, `${name} is required`);
  return value;
}

function intParam(url: URL, name: string, fallback: number): number {
  const value = url.searchParams.get(name);
  if (value === null) return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 200) throw new HttpError(400, `${name} must be 1..200`);
  return parsed;
}
