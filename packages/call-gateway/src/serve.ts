// 网关常驻模式（docs/design.md 5.2）：服务端的 CallService 经这个控制接口让网关以"QQ 端"身份进出 LiveKit 房间。
//   POST   /bridges        {room, token}  入会并开始桥接（同一时间只桥接一个房间，换房间时先退出旧的）
//   DELETE /bridges/:room                 退出
//   GET    /status                        当前房间与统计
// 所有请求都要求 Authorization: Bearer <CALL_GATEWAY_TOKEN>。只在 compose 内网和宿主机回环上开放。
import { timingSafeEqual } from 'node:crypto';
import http from 'node:http';
import { PulseCapture, PulsePlayback } from './audio-io.ts';
import { CallAudioBridge } from './bridge.ts';

export interface ServeOptions {
  host: string;
  port: number;
  token: string;
  livekitUrl: string;
  pulseServer: string;
  log: (event: string, detail?: Record<string, unknown>) => void;
  /** 测试用：替换真实的桥。 */
  createBridge?: (room: string, token: string) => Pick<CallAudioBridge, 'start' | 'stop' | 'stats'>;
}

interface Active {
  room: string;
  bridge: Pick<CallAudioBridge, 'start' | 'stop' | 'stats'>;
  startedAt: string;
}

export function startGatewayServer(opts: ServeOptions): Promise<http.Server> {
  let active: Active | null = null;
  // 入会、退出串行执行，避免两个请求交错时留下孤儿连接。
  let chain: Promise<unknown> = Promise.resolve();
  const serial = <T>(fn: () => Promise<T>): Promise<T> => {
    const next = chain.then(fn, fn);
    chain = next.catch(() => undefined);
    return next;
  };

  const createBridge =
    opts.createBridge ??
    ((room: string, token: string) =>
      new CallAudioBridge({
        url: opts.livekitUrl,
        token,
        capture: new PulseCapture({ server: opts.pulseServer }),
        playback: new PulsePlayback({ server: opts.pulseServer }),
        onLog: (event, detail) => opts.log(event, { room, ...detail }),
      }));

  async function stopActive(): Promise<void> {
    if (!active) return;
    const { room, bridge } = active;
    active = null;
    await bridge.stop().catch((error: unknown) => opts.log('stop failed', { room, error: String(error) }));
    opts.log('left', { room });
  }

  const server = http.createServer(async (req, res) => {
    const send = (status: number, body: unknown) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    try {
      if (!authorized(req.headers.authorization, opts.token)) return send(401, { error: 'unauthorized' });
      const url = new URL(req.url ?? '/', 'http://gateway');
      if (req.method === 'GET' && url.pathname === '/status') {
        return send(200, { room: active?.room ?? null, startedAt: active?.startedAt ?? null, stats: active?.bridge.stats ?? null });
      }
      if (req.method === 'POST' && url.pathname === '/bridges') {
        const body = (await readJson(req)) as { room?: unknown; token?: unknown };
        if (typeof body.room !== 'string' || !body.room || typeof body.token !== 'string' || !body.token) {
          return send(400, { error: 'room and token are required' });
        }
        const room = body.room;
        await serial(async () => {
          if (active?.room === room) return; // 重复请求（服务端重试）
          await stopActive();
          const bridge = createBridge(room, body.token as string);
          await bridge.start();
          active = { room, bridge, startedAt: new Date().toISOString() };
          opts.log('joined', { room });
        });
        return send(200, { room });
      }
      const leave = /^\/bridges\/([^/]+)$/.exec(url.pathname);
      if (req.method === 'DELETE' && leave) {
        const room = decodeURIComponent(leave[1]!);
        const found = await serial(async () => {
          if (active?.room !== room) return false;
          await stopActive();
          return true;
        });
        return send(found ? 200 : 404, { room });
      }
      return send(404, { error: 'not found' });
    } catch (error) {
      opts.log('request failed', { error: String(error) });
      return send(500, { error: String(error) });
    }
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(opts.port, opts.host, () => resolve(server));
  });
}

function authorized(header: string | undefined, token: string): boolean {
  const given = Buffer.from(header?.startsWith('Bearer ') ? header.slice(7) : '');
  const expected = Buffer.from(token);
  return given.length === expected.length && timingSafeEqual(given, expected);
}

async function readJson(req: http.IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > 64 * 1024) throw new Error('request body too large');
    chunks.push(chunk as Buffer);
  }
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {};
}
