// 发送链路：上传（秒传 / tus 续传）→ SendMessage 进发件箱 → 发送任务经上游发往 QQ；以及撤回、已读回写。
import { createHash, randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { Code, createClient, type Interceptor } from '@connectrpc/connect';
import { createConnectTransport } from '@connectrpc/connect-node';
import { MediaService, MessageService, DialogService, OutboxState, SyncService } from '@qqbridge/protocol';
import { sql } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { ApiDeps } from '../src/api/context.ts';
import { buildServer } from '../src/api/server.ts';
import { createDeps } from '../src/app.ts';
import { one } from '../src/db/client.ts';
import { OutboxWorker } from '../src/outbox/worker.ts';
import { getDifference } from '../src/sync/difference.ts';
import { UpstreamCallError, UpstreamOfflineError, UpstreamTimeoutError } from '../src/upstream/hub.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { textMessage } from './helpers/fixtures.ts';

let t: TestDb;
let mediaRoot: string;
let deps: ApiDeps;
let app: FastifyInstance;
let baseUrl: string;
let accountId: number;
let qqAccountId: number;
let token: string;
let otherToken: string;

/** 可控的假上游：记录调用，按测试设置的行为返回。 */
const upstream = {
  connected: true,
  calls: [] as { action: string; params: any }[],
  behavior: async (_action: string, _params: any): Promise<unknown> => ({ messageId: 1, msgSeq: '1', msgId: 'm1' }),
  connections() {
    return [];
  },
  isConnected(_qq: number) {
    return this.connected;
  },
  async call<T>(_qq: number, action: string, params: unknown): Promise<T> {
    if (!this.connected) throw new UpstreamOfflineError(_qq);
    this.calls.push({ action, params });
    return (await this.behavior(action, params)) as T;
  },
};

beforeAll(async () => {
  t = await startTestDb();
  mediaRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-send-'));
  deps = createDeps(t.db, { mediaRoot, mediaUrlSecret: 's'.repeat(40), logLevel: 'silent', uploadMaxBytes: 10 * 1024 * 1024 });
  deps.upstream = upstream;
  app = await buildServer(deps);
  await app.listen({ host: '127.0.0.1', port: 0 });
  baseUrl = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`;
  accountId = await deps.auth.createAccount('owner', 'password123');
  qqAccountId = await deps.ingest.registerQqAccount(accountId, 10001, 'me');
  token = (await deps.auth.login('owner', 'password123', { name: 'iPhone', platform: 'ios' })).token;
  await deps.auth.createAccount('other', 'password456');
  otherToken = (await deps.auth.login('other', 'password456', { name: 'Mac', platform: 'macos' })).token;
});

afterAll(async () => {
  await app?.close();
  await t?.stop();
  await fs.rm(mediaRoot, { recursive: true, force: true });
});

function clients(tok = token) {
  const auth: Interceptor = (next) => async (req) => {
    req.header.set('authorization', `Bearer ${tok}`);
    return next(req);
  };
  const transport = createConnectTransport({ baseUrl, httpVersion: '1.1', interceptors: [auth] });
  return {
    media: createClient(MediaService, transport),
    messages: createClient(MessageService, transport),
    dialogs: createClient(DialogService, transport),
    sync: createClient(SyncService, transport),
  };
}

const sha256 = (b: Buffer) => createHash('sha256').update(b).digest('hex');

function patch(url: string, offset: number, body: Buffer, tok = token) {
  return fetch(baseUrl + url, {
    method: 'PATCH',
    headers: {
      authorization: `Bearer ${tok}`,
      'tus-resumable': '1.0.0',
      'upload-offset': String(offset),
      'content-type': 'application/offset+octet-stream',
    },
    body,
  });
}

/** 走完整的上传流程，返回 sha256。 */
async function upload(content: Buffer, mime: string, name = ''): Promise<string> {
  const sha = sha256(content);
  const prepared = await clients().media.prepareUpload({ sha256: sha, size: BigInt(content.length), mime, name });
  if (prepared.exists) return sha;
  const res = await patch(prepared.uploadUrl, Number(prepared.offset), content.subarray(Number(prepared.offset)));
  expect(res.status).toBe(204);
  return sha;
}

async function newChat(peerId: number, scene: 'group' | 'friend' = 'group') {
  const { chatId } = await deps.ingest.ingestMessage(qqAccountId, textMessage(scene, peerId, 100, 20002));
  return chatId;
}

let randomId = 1000n;

describe('uploads (instant + resumable)', () => {
  it('uploads in pieces, survives interruptions, verifies the checksum and then deduplicates', async () => {
    const content = randomBytes(300_000);
    const sha = sha256(content);
    const { media } = clients();
    const prepared = await media.prepareUpload({ sha256: sha, size: BigInt(content.length), mime: 'application/pdf', name: 'a.pdf' });
    expect(prepared).toMatchObject({ exists: false, offset: 0n });
    expect(prepared.uploadUrl).toMatch(/^\/upload\/[0-9a-f-]{36}$/);

    expect((await patch(prepared.uploadUrl, 0, content.subarray(0, 100_000))).headers.get('upload-offset')).toBe('100000');
    // 断线后：HEAD 查进度，再调 PrepareUpload 也拿到同一个地址和进度（App 重启也能续传）。
    const head = await fetch(baseUrl + prepared.uploadUrl, { method: 'HEAD', headers: { authorization: `Bearer ${token}` } });
    expect(head.status).toBe(200);
    expect(head.headers.get('upload-offset')).toBe('100000');
    expect(head.headers.get('upload-length')).toBe('300000');
    const again = await media.prepareUpload({ sha256: sha, size: BigInt(content.length), mime: 'application/pdf' });
    expect(again).toMatchObject({ exists: false, uploadUrl: prepared.uploadUrl, offset: 100_000n });

    expect((await patch(prepared.uploadUrl, 50_000, content.subarray(50_000))).status).toBe(409); // 偏移不对
    expect((await patch(prepared.uploadUrl, 100_000, content.subarray(100_000), otherToken)).status).toBe(404); // 别人的上传
    expect((await patch(prepared.uploadUrl, 100_000, content.subarray(100_000), 'bad')).status).toBe(401);

    // 模拟上次写入到一半崩溃：文件比记录的进度长，以数据库为准截断后续传。
    const part = path.join(mediaRoot, 'uploads', `${prepared.uploadUrl.split('/').pop()}.part`);
    await fs.appendFile(part, randomBytes(1234));
    const done = await patch(prepared.uploadUrl, 100_000, content.subarray(100_000));
    expect(done.status).toBe(204);
    expect(done.headers.get('upload-offset')).toBe('300000');
    expect(done.headers.get('upload-sha256')).toBe(sha);
    expect(await deps.media.hasContent(sha, content.length)).toBe(true);
    expect((await fetch(baseUrl + prepared.uploadUrl, { method: 'HEAD', headers: { authorization: `Bearer ${token}` } })).status).toBe(404);

    // 第二次就是秒传。
    expect(await media.prepareUpload({ sha256: sha, size: BigInt(content.length), mime: 'application/pdf' })).toMatchObject({ exists: true });
  });

  it('throws away uploads whose content does not match the declared sha256', async () => {
    const declared = randomBytes(1000);
    const prepared = await clients().media.prepareUpload({ sha256: sha256(declared), size: 1000n, mime: 'image/png' });
    const res = await patch(prepared.uploadUrl, 0, randomBytes(1000));
    expect(res.status).toBe(460);
    expect(await deps.media.hasContent(sha256(declared), 1000)).toBe(false);
    expect((await fetch(baseUrl + prepared.uploadUrl, { method: 'HEAD', headers: { authorization: `Bearer ${token}` } })).status).toBe(404);
    await expect(clients().media.prepareUpload({ sha256: 'x', size: 1n })).rejects.toMatchObject({ code: Code.InvalidArgument });
    await expect(clients().media.prepareUpload({ sha256: 'a'.repeat(64), size: 20n * 1024n * 1024n })).rejects.toMatchObject({
      code: Code.ResourceExhausted,
    });
  });
});

describe('sending', () => {
  it('queues messages idempotently and syncs their progress to every device', async () => {
    const chatId = await newChat(700001);
    const { messages, sync } = clients();
    const before = (await sync.getState({})).pts;
    const id = ++randomId;
    const req = { chatId: BigInt(chatId), clientRandomId: id, segments: [{ kind: { case: 'text' as const, value: '你好' } }] };
    const first = await messages.sendMessage(req);
    expect(first.entry).toMatchObject({ clientRandomId: id, chatId: BigInt(chatId), state: OutboxState.PENDING });
    expect(first.entry!.segments[0]!.kind).toEqual({ case: 'text', value: '你好' });
    const retry = await messages.sendMessage(req); // 网络抖动后客户端重试
    expect(retry.entry!.pts).toBe(first.entry!.pts);
    const outboxRows = await one<{ n: number }>(t.db, sql`select count(*)::int as n from outbox where client_random_id = ${Number(id)}`);
    expect(outboxRows.n).toBe(1);

    const diff = (await sync.getDifference({ pts: before })).difference!;
    expect(diff.outbox.map((o) => o.clientRandomId)).toEqual([id]);
    const fresh = await getDifference(t.db, accountId, 0);
    expect(fresh.outbox.map((o) => o.clientRandomId)).toContain(Number(id));

    await expect(messages.sendMessage({ chatId: BigInt(chatId), clientRandomId: ++randomId, segments: [] })).rejects.toMatchObject({
      code: Code.InvalidArgument,
    });
    await expect(
      messages.sendMessage({ chatId: 999_999n, clientRandomId: ++randomId, segments: [{ kind: { case: 'text', value: 'x' } }] }),
    ).rejects.toMatchObject({ code: Code.NotFound });
    await expect(
      messages.sendMessage({
        chatId: BigInt(chatId),
        clientRandomId: ++randomId,
        segments: [{ kind: { case: 'image', value: { sha256: 'c'.repeat(64), name: '', durationSec: 0, sticker: false, summary: '' } } }],
      }),
    ).rejects.toMatchObject({ code: Code.FailedPrecondition });
    // 处理掉这条，免得影响后面的测试。
    await t.db.execute(sql`update outbox set state = 'sent' where client_random_id = ${Number(id)}`);
  });

  it('sends through the upstream: real reply seq, mentions, faces, and media the plugin can download', async () => {
    const chatId = await newChat(700002);
    const image = await (await import('sharp')).default({ create: { width: 8, height: 8, channels: 3, background: '#f00' } }).png().toBuffer();
    const imageSha = await upload(image, 'image/png');
    const pdf = randomBytes(2048);
    const pdfSha = await upload(pdf, 'application/pdf', '报告.pdf');
    const { messages } = clients();
    const textId = ++randomId;
    await messages.sendMessage({
      chatId: BigInt(chatId),
      clientRandomId: textId,
      replyToSeq: 100n,
      segments: [
        { kind: { case: 'mentionUserId', value: 20002n } },
        { kind: { case: 'text', value: ' 看图' } },
        { kind: { case: 'faceId', value: '14' } },
        { kind: { case: 'image', value: { sha256: imageSha, name: '', durationSec: 0, sticker: false, summary: '' } } },
      ],
    });
    const fileId = ++randomId;
    await messages.sendMessage({
      chatId: BigInt(chatId),
      clientRandomId: fileId,
      segments: [{ kind: { case: 'file', value: { sha256: pdfSha, name: '报告.pdf', durationSec: 0, sticker: false, summary: '' } } }],
    });

    upstream.calls = [];
    let seq = 200;
    upstream.behavior = async () => ({ messageId: seq, msgSeq: String(++seq), msgId: `m${seq}` });
    const worker = new OutboxWorker(t.db, deps.outbox, upstream, deps.signer, { mediaBaseUrl: baseUrl });
    expect(await worker.runOnce()).toBe(1); // 同一会话按顺序：第一条发完才轮到第二条
    expect(await worker.runOnce()).toBe(1);

    const [textCall, fileCall] = upstream.calls;
    expect(textCall).toMatchObject({ action: 'x.send', params: { clientRandomId: String(textId), chatType: 2, peerUin: '700002' } });
    const msg = textCall!.params.message;
    expect(msg.slice(0, 4)).toEqual([
      { type: 'reply', data: { seq: 100 } },
      { type: 'at', data: { qq: '20002' } },
      { type: 'text', data: { text: ' 看图' } },
      { type: 'face', data: { id: '14' } },
    ]);
    expect(msg[4].type).toBe('image');
    expect(msg[4].data.file).toMatch(new RegExp(`^${baseUrl}/media/${imageSha}/${imageSha.slice(0, 16)}\\.png\\?exp=\\d+&sig=`));
    // 插件能用这个链接下载到原内容。
    const downloaded = await fetch(msg[4].data.file);
    expect(Buffer.from(await downloaded.arrayBuffer())).toEqual(image);

    expect(fileCall!.params.message).toEqual([
      { type: 'file', data: { file: expect.stringContaining(`/media/${pdfSha}/${encodeURIComponent('报告.pdf')}?`), name: '报告.pdf' } },
    ]);
    const pdfRes = await fetch(fileCall!.params.message[0].data.file);
    expect(pdfRes.headers.get('content-disposition')).toBe(`inline; filename*=UTF-8''${encodeURIComponent('报告.pdf')}`);

    const sent = await one<{ state: string; result_seq: number; qq_msg_id: string }>(
      t.db,
      sql`select state, result_seq, qq_msg_id from outbox where client_random_id = ${Number(textId)}`,
    );
    expect(sent).toEqual({ state: 'sent', result_seq: 201, qq_msg_id: 'm201' });
  });

  it('waits while QQ is offline, retries timeouts, and fails fast when QQ refuses', async () => {
    const chatId = await newChat(700003, 'friend');
    const { messages } = clients();
    const send = async () => {
      const id = ++randomId;
      await messages.sendMessage({ chatId: BigInt(chatId), clientRandomId: id, segments: [{ kind: { case: 'text', value: `m${id}` } }] });
      return id;
    };
    const state = async (id: bigint) =>
      one<{ state: string; attempts: number; error: string | null; next_attempt_at: unknown }>(
        t.db,
        sql`select state, attempts, error, next_attempt_at from outbox where client_random_id = ${Number(id)}`,
      );
    const worker = new OutboxWorker(t.db, deps.outbox, upstream, deps.signer, { mediaBaseUrl: baseUrl, retryDelaysMs: [60_000] });

    const a = await send();
    upstream.connected = false;
    expect(await worker.runOnce()).toBe(0);
    expect(await state(a)).toMatchObject({ state: 'pending', attempts: 0 });

    upstream.connected = true;
    upstream.calls = [];
    upstream.behavior = async () => {
      throw new UpstreamTimeoutError('upstream call x.send timed out');
    };
    expect(await worker.runOnce()).toBe(1);
    expect(await state(a)).toMatchObject({ state: 'pending', attempts: 1, error: 'upstream call x.send timed out' });
    expect(await worker.runOnce()).toBe(0); // 退避中
    const b = await send();
    expect(await worker.runOnce()).toBe(0); // 同一会话里前一条还没发出，后面的等着

    await t.db.execute(sql`update outbox set next_attempt_at = now() where client_random_id = ${Number(a)}`);
    upstream.behavior = async () => ({ messageId: 9, msgSeq: '501', msgId: 'm501' });
    expect(await worker.runOnce()).toBe(1);
    expect(await state(a)).toMatchObject({ state: 'sent', attempts: 2 });
    expect(upstream.calls.map((c) => c.params.clientRandomId)).toEqual([String(a), String(a)]); // 重试用同一个 id，插件去重

    upstream.behavior = async () => {
      throw new UpstreamCallError('Action send_private_msg failed: 对方不是你的好友');
    };
    expect(await worker.runOnce()).toBe(1);
    expect(await state(b)).toMatchObject({ state: 'failed', attempts: 1, error: 'Action send_private_msg failed: 对方不是你的好友' });

    // 用户点"重发"：同一个 client_random_id 再调一次 SendMessage。
    const resent = await messages.sendMessage({ chatId: BigInt(chatId), clientRandomId: b, segments: [{ kind: { case: 'text', value: 'x' } }] });
    expect(resent.entry).toMatchObject({ state: OutboxState.PENDING, error: '' });
    upstream.behavior = async () => ({ messageId: 10, msgSeq: '502', msgId: 'm502' });
    expect(await worker.runOnce()).toBe(1);
    expect(await state(b)).toMatchObject({ state: 'sent' });
  });
});

describe('recall and read write-back', () => {
  it('recalls through the upstream with the QQ message id, and reports why QQ refused', async () => {
    const chatId = await newChat(700004);
    await t.db.execute(sql`update messages set qq_msg_id = '7400000000000000777' where chat_id = ${chatId} and seq = 100`);
    const { messages } = clients();
    upstream.calls = [];
    upstream.behavior = async () => ({ ok: true });
    await messages.recallMessage({ chatId: BigInt(chatId), seq: 100n });
    expect(upstream.calls).toEqual([
      { action: 'x.recall', params: { chatType: 2, peerUid: '700004', peerUin: '700004', msgId: '7400000000000000777' } },
    ]);

    upstream.behavior = async () => {
      throw new UpstreamCallError('超过撤回时限');
    };
    await expect(messages.recallMessage({ chatId: BigInt(chatId), seq: 100n })).rejects.toMatchObject({
      code: Code.FailedPrecondition,
      rawMessage: '超过撤回时限',
    });
    upstream.connected = false;
    await expect(messages.recallMessage({ chatId: BigInt(chatId), seq: 100n })).rejects.toMatchObject({ code: Code.Unavailable });
    upstream.connected = true;
    await expect(messages.recallMessage({ chatId: BigInt(chatId), seq: 999n })).rejects.toMatchObject({ code: Code.NotFound });
  });

  it('marks the chat read in QQ when the user reads it here', async () => {
    const chatId = await newChat(700005);
    upstream.calls = [];
    upstream.behavior = async () => null;
    expect((await clients().dialogs.markRead({ chatId: BigInt(chatId), maxSeq: 100n })).changed).toBe(true);
    await expect.poll(() => upstream.calls).toEqual([
      { action: 'ob11', params: { name: 'mark_group_msg_as_read', params: { group_id: 700005 } } },
    ]);
  });
});
