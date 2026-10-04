import fs from 'node:fs';
import type { IncomingMessage } from 'node:http';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { WebSocketServer, type WebSocket } from 'ws';
import { UpstreamLink } from '../src/upstream/link.js';
import { UpstreamQueue } from '../src/upstream/queue.js';
import type { PluginFrame, ServerFrame } from '../src/upstream/wire.js';

const TOKEN = 't'.repeat(40);
const logger = { log: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() };

/** 假服务端：记录收到的帧，按测试需要回 welcome / ack / req。 */
class FakeServer {
  readonly wss: WebSocketServer;
  readonly frames: PluginFrame[] = [];
  readonly authHeaders: (string | undefined)[] = [];
  socket: WebSocket | null = null;
  received: number[] = [];
  connections = 0;
  /** 服务端已持久保存的游标（welcome 里的 resume）。 */
  stored = 0;
  autoAck = true;
  welcome: (hello: Extract<PluginFrame, { t: 'hello' }>) => ServerFrame = () => ({ t: 'welcome', resume: this.stored });

  constructor() {
    this.wss = new WebSocketServer({ port: 0, host: '127.0.0.1' });
    this.wss.on('connection', (socket: WebSocket, req: IncomingMessage) => {
      this.connections += 1;
      this.socket = socket;
      this.authHeaders.push(req.headers.authorization);
      socket.on('message', (data) => {
        const frame = JSON.parse(data.toString()) as PluginFrame;
        this.frames.push(frame);
        if (frame.t === 'hello') socket.send(JSON.stringify(this.welcome(frame)));
        if (frame.t === 'events') {
          for (const e of frame.list) {
            this.received.push(e.c);
            this.stored = Math.max(this.stored, e.c);
          }
          if (this.autoAck) socket.send(JSON.stringify({ t: 'ack', c: this.stored } satisfies ServerFrame));
        }
      });
    });
  }

  get url() {
    return `ws://127.0.0.1:${(this.wss.address() as AddressInfo).port}/upstream/napcat`;
  }

  send(frame: ServerFrame) {
    this.socket?.send(JSON.stringify(frame));
  }

  async close() {
    for (const client of this.wss.clients) client.terminate();
    await new Promise((resolve) => this.wss.close(resolve));
  }
}

let dir: string;
let server: FakeServer;
let queue: UpstreamQueue;
let link: UpstreamLink | null;

beforeEach(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qqbridge-link-'));
  server = new FakeServer();
  await new Promise((resolve) => server.wss.once('listening', resolve));
  queue = UpstreamQueue.open(dir);
  link = null;
});

afterEach(async () => {
  await link?.stop();
  await server.close();
  queue.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

function startLink(opts: Partial<ConstructorParameters<typeof UpstreamLink>[0]> = {}) {
  link = new UpstreamLink({
    url: server.url,
    token: TOKEN,
    queue,
    hello: async () => ({ self: { uin: '10001', uid: 'u_self' }, impl: { plugin: 'test' } }),
    handlers: {},
    logger,
    minBackoffMs: 20,
    maxBackoffMs: 50,
    ...opts,
  });
  link.start();
  return link;
}

describe('UpstreamLink', () => {
  it('authenticates, introduces the queue, replays the backlog and lets acks trim the queue', async () => {
    for (let i = 1; i <= 5; i++) queue.append({ n: i });
    startLink();
    await vi.waitFor(() => expect(server.received).toEqual([1, 2, 3, 4, 5]));
    expect(server.authHeaders).toEqual([`Bearer ${TOKEN}`]);
    expect(server.frames[0]).toMatchObject({
      t: 'hello',
      v: 1,
      queue: { id: queue.id, first: 1, last: 5 },
      self: { uin: '10001', uid: 'u_self' },
    });
    await vi.waitFor(() => expect(queue.acked).toBe(5));

    // 追上进度后，新事件入队就立刻发送。
    queue.append({ n: 6 });
    link!.notify();
    await vi.waitFor(() => expect(server.received).toEqual([1, 2, 3, 4, 5, 6]));
  });

  it('resumes after the position the server already stored, across reconnects', async () => {
    for (let i = 1; i <= 4; i++) queue.append({ n: i });
    server.stored = 2; // 服务端之前已经收到 1..2
    startLink();
    await vi.waitFor(() => expect(server.received).toEqual([3, 4]));

    // 服务端断开（例如重启）；期间又来了两条。
    server.socket!.terminate();
    queue.append({ n: 5 });
    queue.append({ n: 6 });
    link!.notify(); // 未连上时不发送，也不报错
    await vi.waitFor(() => expect(server.connections).toBe(2));
    await vi.waitFor(() => expect(server.received).toEqual([3, 4, 5, 6]));
  });

  it('keeps at most maxInFlight events unacknowledged', async () => {
    server.autoAck = false;
    for (let i = 1; i <= 10; i++) queue.append({ n: i });
    startLink({ maxInFlight: 4, batchSize: 3 });
    await vi.waitFor(() => expect(server.received).toEqual([1, 2, 3, 4]));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(server.received).toEqual([1, 2, 3, 4]);

    server.send({ t: 'ack', c: 3 });
    await vi.waitFor(() => expect(server.received).toEqual([1, 2, 3, 4, 5, 6, 7]));
    expect(queue.acked).toBe(3);
  });

  it('answers server requests with handler results or errors', async () => {
    startLink({
      handlers: {
        'x.echo': async (params) => ({ echoed: params }),
        'x.fail': async () => {
          throw new Error('boom');
        },
      },
    });
    await vi.waitFor(() => expect(server.frames.some((f) => f.t === 'hello')).toBe(true));
    server.send({ t: 'req', id: 'a', action: 'x.echo', params: { k: 1 } });
    server.send({ t: 'req', id: 'b', action: 'x.fail', params: {} });
    server.send({ t: 'req', id: 'c', action: 'x.nope', params: {} });
    await vi.waitFor(() => expect(server.frames.filter((f) => f.t === 'res')).toHaveLength(3));
    const res = Object.fromEntries(server.frames.filter((f) => f.t === 'res').map((f) => [(f as { id: string }).id, f]));
    expect(res.a).toEqual({ t: 'res', id: 'a', ok: true, data: { echoed: { k: 1 } } });
    expect(res.b).toEqual({ t: 'res', id: 'b', ok: false, error: 'boom' });
    expect(res.c).toMatchObject({ ok: false, error: 'unknown action: x.nope' });
  });

  it('switches to a new queue id when the server is ahead of the local queue', async () => {
    for (let i = 1; i <= 3; i++) queue.append({ n: i });
    const oldId = queue.id;
    server.welcome = (hello) =>
      hello.queue.id === oldId ? { t: 'welcome', resume: 0, reset: true } : { t: 'welcome', resume: 0 };
    startLink();
    await vi.waitFor(() => expect(server.received).toEqual([1, 2, 3]));
    expect(queue.id).not.toBe(oldId);
    expect(server.connections).toBe(2);
  });

  it('retries the hello later while QQ is not logged in yet', async () => {
    let ready = false;
    startLink({
      hello: async () => {
        if (!ready) throw new Error('QQ self identity is not available yet');
        return { self: { uin: '1', uid: 'u' }, impl: { plugin: 'test' } };
      },
    });
    await vi.waitFor(() => expect(server.connections).toBeGreaterThanOrEqual(1));
    ready = true;
    await vi.waitFor(() => expect(server.frames.some((f) => f.t === 'hello')).toBe(true));
    expect(link!.state).toMatchObject({ welcomed: true });
  });
});
