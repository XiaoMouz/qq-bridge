// 上游链路联调：服务端是真实的接入点 + 收件箱 + 数据库，插件端直接用插件包里真实的队列和连接客户端。
import fs from 'node:fs';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { sql } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import pino from 'pino';
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { UpstreamLink } from '../../napcat-plugin-qqbridge/src/upstream/link.ts';
import { UpstreamQueue } from '../../napcat-plugin-qqbridge/src/upstream/queue.ts';
import { createDeps } from '../src/app.ts';
import { buildServer } from '../src/api/server.ts';
import type { ApiDeps } from '../src/api/context.ts';
import { maybeOne, one, rows } from '../src/db/client.ts';
import { createUpstream, type Upstream } from '../src/upstream/index.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { el, messageEvent, raw } from './helpers/napcat.ts';

const TOKEN = 'upstream-token-'.padEnd(48, 'x');
const SELF = '10001';
const silent = { log() {}, info() {}, warn() {}, error() {} };

let t: TestDb;
let deps: ApiDeps;
let upstream: Upstream;
let app: FastifyInstance;
let url: string;
let tmp: string;
const links: UpstreamLink[] = [];
const queues: UpstreamQueue[] = [];

beforeAll(async () => {
  t = await startTestDb();
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'qqbridge-upstream-'));
  deps = createDeps(t.db, { mediaRoot: path.join(tmp, 'media'), mediaUrlSecret: 's'.repeat(40), logLevel: 'silent' });
  const owner = await one<{ id: number }>(t.db, sql`insert into accounts (username, password_hash) values ('owner', 'x') returning id`);
  await t.db.execute(sql`insert into sync_state (account_id) values (${owner.id})`);
  upstream = createUpstream(t.db, deps.ingest, pino({ level: 'silent' }), {
    token: TOKEN,
    warmMessages: 0,
    backfillIntervalMs: 200,
    inboxRetentionDays: 30,
  });
  // 对账另有专门的测试；这里不让它去调插件。
  upstream.hub.onConnected = null;
  app = await buildServer(deps);
  await upstream.hub.register(app);
  await app.listen({ host: '127.0.0.1', port: 0 });
  url = `ws://127.0.0.1:${(app.server.address() as AddressInfo).port}/upstream/napcat`;
});

afterEach(async () => {
  for (const link of links.splice(0)) await link.stop();
  for (const q of queues.splice(0)) q.close();
});

afterAll(async () => {
  await app?.close();
  await upstream?.stop();
  await t?.stop();
  fs.rmSync(tmp, { recursive: true, force: true });
});

function plugin(opts: { dir?: string; token?: string; handlers?: ConstructorParameters<typeof UpstreamLink>[0]['handlers'] } = {}) {
  const queue = UpstreamQueue.open(opts.dir ?? fs.mkdtempSync(path.join(tmp, 'queue-')));
  const link = new UpstreamLink({
    url,
    token: opts.token ?? TOKEN,
    queue,
    hello: async () => ({ self: { uin: SELF, uid: 'u_self', nick: '我' }, impl: { plugin: 'test' } }),
    handlers: opts.handlers ?? {},
    logger: silent,
    minBackoffMs: 20,
    maxBackoffMs: 100,
  });
  queues.push(queue);
  links.push(link);
  return { queue, link };
}

async function messageAt(peerId: number, seq: number) {
  return maybeOne<{ text: string; state: string; segments: unknown[] }>(
    t.db,
    sql`select m.text, m.state, m.segments from messages m join chats c on c.id = m.chat_id where c.peer_id = ${peerId} and m.seq = ${seq}`,
  );
}

describe('upstream link (plugin ⇄ server)', () => {
  it('archives the backlog and live events, acknowledges them, and records latency', async () => {
    const { queue, link } = plugin();
    const MD5 = '00112233445566778899aabbccddeeff';
    const groupMsg = raw({
      chatType: 2,
      peer: '600001',
      seq: 41,
      sender: '20002',
      peerName: '联调群',
      elements: [el.text('看图'), el.pic({ md5: MD5, size: 1000, w: 640, h: 480 })],
    });
    queue.append(
      messageEvent(groupMsg, {
        ob11: [{ type: 'image', data: { file: `${MD5.toUpperCase()}.jpg`, url: 'https://multimedia.nt.qq.com.cn/download?rkey=1' } }],
      }),
    );
    queue.append({ post_type: 'meta_event', meta_event_type: 'heartbeat', self_id: Number(SELF) }); // 插件正常不会转发，这里验证服务端也能容忍
    link.start();

    await vi.waitFor(() => expect(queue.acked).toBe(2), { timeout: 10_000 });
    await vi.waitFor(async () => expect(await messageAt(600001, 41)).toMatchObject({ text: '看图[图片]' }), { timeout: 10_000 });
    await upstream.inbox.idle(); // 消息入库后还会更新群资料、标记事件状态

    const ref = await one<{ url: string; locator: Record<string, unknown>; qq_md5: string; fetch_state: string }>(
      t.db,
      sql`select r.url, r.locator, r.qq_md5, r.fetch_state from media_refs r join chats c on c.id = r.chat_id where c.peer_id = 600001`,
    );
    expect(ref).toMatchObject({ url: 'https://multimedia.nt.qq.com.cn/download?rkey=1', qq_md5: MD5, fetch_state: 'pending' });
    expect(ref.locator).toMatchObject({ chatType: 2, peerUid: '600001', elementType: 2, msgId: groupMsg.msgId });
    const group = await one<{ name: string }>(t.db, sql`select name from peers where kind = 'group' and peer_id = 600001`);
    expect(group.name).toBe('联调群');

    // 实时：入队即发送。
    const live = raw({ chatType: 1, peer: '30003', seq: 7, sender: SELF, elements: [el.text('从手机发的')] });
    queue.append(messageEvent(live, { self: true }));
    link.notify();
    await vi.waitFor(async () => expect(await messageAt(30003, 7)).toMatchObject({ text: '从手机发的' }), { timeout: 10_000 });
    await upstream.inbox.idle(); // 入库之后才会把事件标记为 done

    const states = await rows<{ kind: string; state: string }>(t.db, sql`select kind, state from upstream_events order by id`);
    expect(states).toEqual([
      { kind: 'message.group', state: 'done' },
      { kind: 'meta_event.heartbeat', state: 'ignored' },
      { kind: 'message_sent.private', state: 'done' },
    ]);
    expect(upstream.inbox.latency.recorded).toBe(2);
    expect(upstream.inbox.latency.summary().ingest.max).toBeLessThan(5_000);
    const qq = await one<{ uid: string; nickname: string }>(t.db, sql`select uid, nickname from qq_accounts where uin = ${Number(SELF)}`);
    expect(qq).toEqual({ uid: 'u_self', nickname: '我' });
  });

  it('applies recalls the plugin resolved, and keeps the ones it could not place', async () => {
    const { queue, link } = plugin();
    const msg = raw({ chatType: 2, peer: '600002', seq: 9, sender: '20002', elements: [el.text('马上撤回')] });
    queue.append(messageEvent(msg));
    queue.append({ post_type: 'notice', notice_type: 'group_recall', self_id: Number(SELF), group_id: 600002, user_id: 20002, operator_id: 20002, message_id: 1, time: 1_700_000_100, qqbridge: { recalled: { msgSeq: '9' } } });
    queue.append({ post_type: 'notice', notice_type: 'group_recall', self_id: Number(SELF), group_id: 600002, message_id: 2, time: 1_700_000_101 });
    link.start();
    await vi.waitFor(async () => expect(await messageAt(600002, 9)).toMatchObject({ state: 'recalled', text: '马上撤回' }), { timeout: 10_000 });
    await upstream.inbox.idle();
    const last = await one<{ state: string; error: string }>(t.db, sql`select state, error from upstream_events order by id desc limit 1`);
    expect(last).toEqual({ state: 'ignored', error: 'recall notice without a resolvable seq' });
  });

  it('rejects wrong tokens, resumes after reconnects without duplicates, and serves server→plugin calls', async () => {
    const intruder = plugin({ token: 'w'.repeat(48) });
    intruder.link.start();
    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(intruder.link.state.welcomed).toBe(false);
    await intruder.link.stop();

    const dir = fs.mkdtempSync(path.join(tmp, 'queue-'));
    const first = plugin({ dir, handlers: { 'x.echo': async (p) => ({ echo: p }) } });
    first.queue.append(messageEvent(raw({ chatType: 2, peer: '600003', seq: 1, sender: '20002', elements: [el.text('一')] })));
    first.link.start();
    await vi.waitFor(() => expect(first.queue.acked).toBe(1), { timeout: 10_000 });
    const qqAccountId = upstream.hub.connections()[0]!.qqAccountId;
    expect(await upstream.hub.call(qqAccountId, 'x.echo', { a: 1 })).toEqual({ echo: { a: 1 } });

    // 服务端断开所有连接（例如重启）；期间插件又收到两条。
    upstream.hub.close();
    first.queue.append(messageEvent(raw({ chatType: 2, peer: '600003', seq: 2, sender: '20002', elements: [el.text('二')] })));
    first.queue.append(messageEvent(raw({ chatType: 2, peer: '600003', seq: 3, sender: '20002', elements: [el.text('三')] })));
    first.link.notify();
    await vi.waitFor(() => expect(first.queue.acked).toBe(3), { timeout: 10_000 });
    await upstream.inbox.idle();
    const texts = await rows<{ text: string }>(
      t.db,
      sql`select m.text from messages m join chats c on c.id = m.chat_id where c.peer_id = 600003 order by m.seq`,
    );
    expect(texts.map((r) => r.text)).toEqual(['一', '二', '三']);
    const events = await one<{ n: number }>(
      t.db,
      sql`select count(*)::int as n from upstream_events where queue_id = ${first.queue.id}`,
    );
    expect(events.n).toBe(3);
  });

  it('asks a plugin with an outdated queue to start a new one, and loses nothing', async () => {
    const dir = fs.mkdtempSync(path.join(tmp, 'queue-'));
    const a = plugin({ dir });
    for (let seq = 1; seq <= 3; seq++) {
      a.queue.append(messageEvent(raw({ chatType: 1, peer: '30009', seq, sender: '30009', elements: [el.text(`m${seq}`)] })));
    }
    a.link.start();
    await vi.waitFor(() => expect(a.queue.acked).toBe(3), { timeout: 10_000 });
    const oldId = a.queue.id;
    await a.link.stop();
    a.queue.close();
    queues.splice(queues.indexOf(a.queue), 1);

    // 模拟插件数据目录被还原到旧状态：同一个队列 id，但只到游标 1，之后又收到新消息。
    const segment = fs.readdirSync(dir).find((f) => f.startsWith('seg-'))!;
    const firstLine = fs.readFileSync(path.join(dir, segment), 'utf8').split('\n')[0]!;
    fs.writeFileSync(path.join(dir, segment), `${firstLine}\n`);
    fs.writeFileSync(path.join(dir, 'queue.json'), JSON.stringify({ id: oldId, acked: 1 }));
    const b = plugin({ dir });
    b.queue.append(messageEvent(raw({ chatType: 1, peer: '30009', seq: 4, sender: '30009', elements: [el.text('m4')] })));
    b.link.start();
    await vi.waitFor(async () => expect(await messageAt(30009, 4)).toMatchObject({ text: 'm4' }), { timeout: 10_000 });
    expect(b.queue.id).not.toBe(oldId);
  });
});
