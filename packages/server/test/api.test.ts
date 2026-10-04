import { randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { Code, ConnectError, createClient, type Interceptor } from '@connectrpc/connect';
import { createConnectTransport } from '@connectrpc/connect-node';
import {
  AuthService,
  DialogService,
  HistoryDirection,
  MediaKind,
  MediaService,
  MediaState,
  MessageService,
  SyncService,
  type SubscribeResponse,
} from '@qqbridge/protocol';
import { sql } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { createDeps } from '../src/app.ts';
import { buildServer } from '../src/api/server.ts';
import type { ApiDeps } from '../src/api/context.ts';
import { maybeOne } from '../src/db/client.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { imageMessage, textMessage } from './helpers/fixtures.ts';

let t: TestDb;
let mediaRoot: string;
let deps: ApiDeps;
let app: FastifyInstance;
let baseUrl: string;
let accountId: number;
let qqAccountId: number;

beforeAll(async () => {
  t = await startTestDb();
  mediaRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-api-'));
  deps = createDeps(t.db, { mediaRoot, mediaUrlSecret: 's'.repeat(40), logLevel: 'silent' });
  app = await buildServer(deps);
  await app.listen({ host: '127.0.0.1', port: 0 });
  baseUrl = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`;
  accountId = await deps.auth.createAccount('owner', 'password123');
  qqAccountId = await deps.ingest.registerQqAccount(accountId, 10001, 'me');
});

afterAll(async () => {
  await app?.close();
  await t?.stop();
  await fs.rm(mediaRoot, { recursive: true, force: true });
});

function transport(token?: string) {
  const auth: Interceptor = (next) => async (req) => {
    if (token) req.header.set('authorization', `Bearer ${token}`);
    return next(req);
  };
  return createConnectTransport({ baseUrl, httpVersion: '1.1', interceptors: [auth] });
}

describe('API end to end', () => {
  it('serves the Telegram-style sync flow, media and storage APIs to an authenticated device', async () => {
    // 未登录调用被拒绝。
    const anonymous = createClient(SyncService, transport());
    await expect(anonymous.getState({})).rejects.toMatchObject({ code: Code.Unauthenticated });

    const login = await createClient(AuthService, transport()).login({
      username: 'owner',
      password: 'password123',
      deviceName: 'iPhone',
      platform: 'ios',
    });
    const t1 = transport(login.token);
    const sync = createClient(SyncService, t1);
    const dialogs = createClient(DialogService, t1);
    const messages = createClient(MessageService, t1);
    const media = createClient(MediaService, t1);
    expect((await sync.getState({})).pts).toBe(0n);

    // 订阅流：先差量（此时为空），再实时推送。
    const controller = new AbortController();
    const events: SubscribeResponse[] = [];
    const stream = (async () => {
      try {
        for await (const res of sync.subscribe({ pts: 0n }, { signal: controller.signal })) events.push(res);
      } catch (error) {
        if (!(error instanceof ConnectError && error.code === Code.Canceled)) throw error;
      }
    })();
    try {
      await vi.waitFor(() => expect(events[0]?.event.case).toBe('difference'));

      // 入库一条带图片的消息，随后图片"下载完成"。
      const content = randomBytes(4096);
      const { chatId } = await deps.ingest.ingestMessage(qqAccountId, imageMessage('group', 77, 10, 5, {}, { time: 1_700_000_000 }));
      await deps.ingest.ingestMessage(qqAccountId, textMessage('group', 77, 11, 5, { text: '看图' }));
      const ref = await maybeOne<{ id: number }>(t.db, sql`select id from media_refs where chat_id = ${chatId}`);
      const blob = await deps.media.storeBlob(Readable.from([content]), { kind: 'image', mime: 'image/jpeg' });
      // 缩略图 / 预览图（真实流程由下载任务生成，这里直接登记）。
      const thumb = await deps.media.storeBlob(Readable.from([randomBytes(300)]), { kind: 'image', mime: 'image/webp' });
      const preview = await deps.media.storeBlob(Readable.from([randomBytes(900)]), { kind: 'image', mime: 'image/webp' });
      await t.db.execute(
        sql`insert into blob_variants (sha256, variant, variant_sha256)
            values (${blob.sha256}, 'thumb', ${thumb.sha256}), (${blob.sha256}, 'preview', ${preview.sha256})`,
      );
      // 别人的内容的缩略图：不能借"缩略图"的名义拿到链接。
      const foreign = await deps.media.storeBlob(Readable.from([randomBytes(500)]), { kind: 'image' });
      const foreignThumb = await deps.media.storeBlob(Readable.from([randomBytes(50)]), { kind: 'image' });
      await t.db.execute(
        sql`insert into blob_variants (sha256, variant, variant_sha256) values (${foreign.sha256}, 'thumb', ${foreignThumb.sha256})`,
      );
      await deps.ingest.mediaStored(ref!.id, blob, {
        thumbhash: 'AAAA',
        thumbSha256: thumb.sha256,
        previewSha256: preview.sha256,
        width: 1600,
        height: 1200,
      });

      // 客户端从流里收到"媒体就绪"的消息更新（chat_pts = 3：两条新消息 + 一次媒体更新）。
      await vi.waitFor(() => {
        const last = events.findLast((e) => e.event.case === 'chatMessage');
        expect(last?.event.case === 'chatMessage' && last.event.value.chatPts).toBe(3n);
      });
      const mediaUpdate = events.findLast((e) => e.event.case === 'chatMessage');
      const segment = mediaUpdate?.event.case === 'chatMessage' ? mediaUpdate.event.value.message?.segments[0] : undefined;
      expect(segment?.kind.case === 'image' && segment.kind.value.media).toMatchObject({
        state: MediaState.STORED,
        sha256: blob.sha256,
        thumbhash: 'AAAA',
        thumbSha256: thumb.sha256,
        previewSha256: preview.sha256,
        width: 1600,
        height: 1200,
      });

      // 差量与历史。
      const diff = (await sync.getDifference({ pts: 0n })).difference!;
      expect(diff.isFinal).toBe(true);
      expect(diff.dialogs).toHaveLength(1);
      expect(diff.dialogs[0]).toMatchObject({ chatId: BigInt(chatId), unreadCount: 2, topSeq: 11n });
      expect(diff.dialogs[0]?.topMessage?.text).toBe('看图');
      const history = await messages.getHistory({ chatId: BigInt(chatId), direction: HistoryDirection.OLDER, limit: 10 });
      expect(history.messages.map((m) => m.seq)).toEqual([10n, 11n]);
      expect(history.chatPts).toBe(3n);

      // 签名链接 + Range 下载。
      const signed = await media.signMediaUrls({
        sha256: [blob.sha256, thumb.sha256, preview.sha256, foreign.sha256, foreignThumb.sha256, 'f'.repeat(64)],
      });
      expect(signed.urls.map((u) => u.sha256).sort()).toEqual([blob.sha256, thumb.sha256, preview.sha256].sort());
      const original = signed.urls.find((u) => u.sha256 === blob.sha256)!;
      const thumbUrl = signed.urls.find((u) => u.sha256 === thumb.sha256)!;
      expect((await fetch(baseUrl + thumbUrl.url)).headers.get('content-length')).toBe('300');
      const ranged = await fetch(baseUrl + original.url, { headers: { Range: 'bytes=0-9' } });
      expect(ranged.status).toBe(206);
      expect(ranged.headers.get('content-range')).toBe('bytes 0-9/4096');
      expect(Buffer.from(await ranged.arrayBuffer())).toEqual(content.subarray(0, 10));
      const whole = await fetch(baseUrl + original.url);
      expect(Buffer.from(await whole.arrayBuffer())).toEqual(content);
      expect((await fetch(`${baseUrl}/media/${blob.sha256}`)).status).toBe(403);

      // 出处、占用统计、清理预估、秒传判定。
      const usages = await media.listMediaUsages({ sha256: blob.sha256 });
      expect(usages.usages).toEqual([expect.objectContaining({ chatId: BigInt(chatId), messageSeq: 10n, peerId: 77n, kind: MediaKind.IMAGE })]);
      const overview = await media.getStorageOverview({});
      expect(overview).toMatchObject({ physicalBytes: 4096n, logicalBytes: 4096n, blobCount: 1 });
      const plan = await media.planCleanup({ chatId: BigInt(chatId), kinds: [MediaKind.IMAGE], olderThanDays: 0 });
      expect(plan).toMatchObject({ purgeableBlobCount: 1, freedBytes: 4096n });
      expect((await media.prepareUpload({ sha256: blob.sha256, size: 4096n })).exists).toBe(true);
      expect((await media.prepareUpload({ sha256: 'a'.repeat(64), size: 1n })).exists).toBe(false);

      // 标记已读：会话更新经 pts 推送。
      const before = (await sync.getState({})).pts;
      expect((await dialogs.markRead({ chatId: BigInt(chatId), maxSeq: 11n })).changed).toBe(true);
      const afterRead = (await sync.getDifference({ pts: before })).difference!;
      expect(afterRead.dialogs[0]).toMatchObject({ unreadCount: 0, readInboxMaxSeq: 11n });

      // 批量首屏（预取）：不存在的会话直接跳过。
      const batch = await sync.getChatDifferences({
        chats: [{ chatId: BigInt(chatId), chatPts: 0n }, { chatId: 999_999n, chatPts: 0n }],
        perChatLimit: 1,
      });
      expect(batch.chats).toHaveLength(1);
      expect(batch.chats[0]).toMatchObject({ chatId: BigInt(chatId), chatPts: 3n, tooLong: true, isFinal: true });
      expect(batch.chats[0]!.messages.map((m) => m.seq)).toEqual([11n]);

      // 正在看的会话：只能是自己的会话；chat_id = 0 表示退出。
      await dialogs.setActiveChat({ chatId: BigInt(chatId) });
      expect(deps.activeChats.chatIds()).toEqual([chatId]);
      await expect(dialogs.setActiveChat({ chatId: 999_999n })).rejects.toMatchObject({ code: Code.NotFound });
      await dialogs.setActiveChat({ chatId: 0n });
      expect(deps.activeChats.chatIds()).toEqual([]);
    } finally {
      controller.abort();
      await stream;
    }

    // 设备管理与登出。
    const auth = createClient(AuthService, t1);
    expect((await auth.listDevices({})).devices).toEqual([expect.objectContaining({ name: 'iPhone', current: true })]);
    await auth.logout({});
    await expect(sync.getState({})).rejects.toMatchObject({ code: Code.Unauthenticated });
  });

  it('maps unknown chats to NotFound', async () => {
    const login = await createClient(AuthService, transport()).login({ username: 'owner', password: 'password123' });
    const messages = createClient(MessageService, transport(login.token));
    await expect(messages.getHistory({ chatId: 999_999n, limit: 5 })).rejects.toMatchObject({ code: Code.NotFound });
  });
});
