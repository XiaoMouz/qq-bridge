import fs from 'node:fs/promises';
import path from 'node:path';
import pino from 'pino';
import { buildServer } from './api/server.ts';
import { registerQFaceRoutes } from './api/qface-routes.ts';
import { MediaUrlSigner } from './api/media-urls.ts';
import type { ApiDeps } from './api/context.ts';
import { AuthService } from './auth/service.ts';
import type { Config } from './config.ts';
import { sql } from 'drizzle-orm';
import { createDb, rows, runMigrations, type Db } from './db/client.ts';
import { IngestService } from './ingest/service.ts';
import { MediaCleaner } from './media/cleanup.ts';
import { MediaFetcher } from './media/fetcher.ts';
import { MediaProcessor } from './media/processing.ts';
import { MediaService } from './media/service.ts';
import { StoredUrlSource, type MediaSource } from './media/source.ts';
import { LocalFsBackend, RemovableBackend } from './media/store.ts';
import { UploadService } from './media/upload.ts';
import { DialogPrefs } from './dialogs/prefs.ts';
import { OutboxService } from './outbox/service.ts';
import { OutboxWorker } from './outbox/worker.ts';
import { ActiveChats } from './sync/active-chats.ts';
import { OnlineDevices } from './sync/online-devices.ts';
import { UpdateBus } from './sync/bus.ts';
import { WriterRegistry } from './sync/writer.ts';
import { CallService } from './calls/service.ts';
import { AdminService } from './admin/service.ts';
import { NapcatWebUi } from './admin/napcat-webui.ts';
import { ContactService } from './contacts/service.ts';
import { TierManager } from './media/tiering.ts';
import { MessageForwarder } from './messages/forwarding.ts';
import { GroupContentService } from './contacts/group-content.ts';
import { StickerService } from './media/stickers.ts';
import { StorageBrowser } from './media/storage-browse.ts';
import { ForwardService } from './messages/forwards.ts';
import { MessageInteractions } from './messages/interactions.ts';
import { HttpCallGateway } from './calls/gateway.ts';
import { createUpstream } from './upstream/index.ts';
import { QqSettingsSync } from './upstream/settings-sync.ts';
import { ApnsClient } from './push/apns.ts';
import { PushNotifier } from './push/notifier.ts';

/** 组装服务端的全部依赖；测试与 CLI 共用。 */
export function createDeps(
  db: Db,
  opts: { mediaRoot: string; mediaColdRoot?: string; mediaUrlSecret: string; logLevel?: string; uploadMaxBytes?: number; ffmpegPath?: string },
): ApiDeps {
  const bus = new UpdateBus();
  const writers = new WriterRegistry(db, bus);
  const root = path.resolve(opts.mediaRoot);
  const backend = new LocalFsBackend(root);
  // 冷存储一般在外接硬盘上：用 RemovableBackend，盘不在时不会往系统盘上写。
  const media = new MediaService(db, backend, opts.mediaColdRoot ? new RemovableBackend(path.resolve(opts.mediaColdRoot)) : null);
  const ingest = new IngestService(db, writers);
  const logger = pino({ level: opts.logLevel ?? 'info' });
  const processor = new MediaProcessor(db, media, {
    ...(opts.ffmpegPath ? { ffmpegPath: opts.ffmpegPath } : {}),
    logger: logger.child({ component: 'media' }),
  });
  media.onPresenceChanged = (sha256, present) =>
    void ingest.mediaPresenceChanged(sha256, present).catch((error: unknown) => logger.warn({ err: error, sha256 }, 'media presence update failed'));
  const deps: ApiDeps = {
    db,
    bus,
    writers,
    ingest,
    auth: new AuthService(db),
    media,
    backend,
    uploads: new UploadService(db, media, path.join(root, 'uploads'), opts.uploadMaxBytes, processor),
    processor,
    outbox: new OutboxService(db, writers),
    forwarder: null as unknown as MessageForwarder,
    groupContent: null as unknown as GroupContentService,
    dialogPrefs: new DialogPrefs(writers),
    cleaner: new MediaCleaner(db, media, logger.child({ component: 'cleanup' })),
    upstream: null,
    history: null,
    // 没有上游 / LiveKit / 网关时只能记录和查询，接听会返回 Unavailable；startServer 里按配置替换。
    calls: new CallService(db, ingest, null, null, null),
    interactions: new MessageInteractions(db, ingest, () => deps.upstream),
    forwards: new ForwardService(db, ingest, () => deps.upstream),
    tiering: new TierManager(db, media, logger.child({ component: 'tiering' })),
    rehydrate: null,
    pokeMediaFetcher: () => undefined,
    fetchMediaNow: null,
    storageBrowser: new StorageBrowser(db),
    stickers: new StickerService(db, media, processor, () => deps.upstream, logger.child({ component: 'stickers' })),
    defaultAutoFetchMaxBytes: 200 * 1024 * 1024,
    admin: new AdminService(db, {
      upstream: () => deps.upstream,
      history: () => deps.history,
      calls: () => deps.calls,
      media,
    }),
    napcatWebUi: null,
    contacts: new ContactService(db, ingest, media, processor, () => deps.upstream, { logger: logger.child({ component: 'contacts' }) }),
    signer: new MediaUrlSigner(opts.mediaUrlSecret),
    activeChats: new ActiveChats(),
    onlineDevices: new OnlineDevices(),
    logger,
  };  deps.forwarder = new MessageForwarder(db, ingest, deps.outbox, () => deps.fetchMediaNow, deps.forwards, () => deps.upstream, deps.logger.child({ component: 'forward' }));
  deps.groupContent = new GroupContentService(db, media, () => deps.upstream, {
    ...(opts.uploadMaxBytes ? { maxFileBytes: opts.uploadMaxBytes * 2 } : {}),
    logger: logger.child({ component: 'group-content' }),
  });

  return deps;
}

/**
 * 启动服务端。mediaSource 由上游适配器提供（能向 NapCat 换新的媒体链接）；
 * 没有上游时只用入库时记下的链接，过期的媒体记为 expired。
 */
export async function startServer(config: Config, opts: { mediaSource?: MediaSource } = {}) {
  const db = createDb(config.DATABASE_URL);
  await runMigrations(db);
  const deps = createDeps(db, {
    mediaRoot: config.MEDIA_ROOT,
    ...(config.MEDIA_COLD_ROOT ? { mediaColdRoot: config.MEDIA_COLD_ROOT } : {}),
    mediaUrlSecret: config.MEDIA_URL_SECRET,
    logLevel: config.LOG_LEVEL,
    uploadMaxBytes: config.UPLOAD_MAX_BYTES,
    ...(config.FFMPEG_PATH ? { ffmpegPath: config.FFMPEG_PATH } : {}),
  });
  let fetcher: MediaFetcher | null = null;
  const upstream = config.UPSTREAM_TOKEN
    ? createUpstream(
        db,
        deps.ingest,
        deps.logger,
        {
          token: config.UPSTREAM_TOKEN,
          account: config.UPSTREAM_ACCOUNT,
          warmMessages: config.UPSTREAM_WARM_MESSAGES,
          backfillIntervalMs: config.UPSTREAM_BACKFILL_INTERVAL_MS,
          inboxRetentionDays: config.UPSTREAM_INBOX_RETENTION_DAYS,
        },
        {
          onMediaQueued: () => fetcher?.poke(),
          activeChats: deps.activeChats,
          onCall: (qqAccountId, state) => deps.calls.onPluginState(qqAccountId, state),
          onMemberChanged: (qqAccountId, groupId, userId) => deps.contacts.refreshMember(qqAccountId, groupId, userId),
        },
      )
    : null;
  deps.upstream = upstream?.hub ?? null;
  deps.history = upstream?.history ?? null;
  const livekit =
    config.LIVEKIT_API_KEY && config.LIVEKIT_API_SECRET && config.LIVEKIT_PUBLIC_URL
      ? { livekitApiKey: config.LIVEKIT_API_KEY, livekitApiSecret: config.LIVEKIT_API_SECRET, livekitPublicUrl: config.LIVEKIT_PUBLIC_URL }
      : null;
  deps.calls = new CallService(
    db,
    deps.ingest,
    upstream?.hub ?? null,
    config.CALL_GATEWAY_TOKEN ? new HttpCallGateway(config.CALL_GATEWAY_URL, config.CALL_GATEWAY_TOKEN) : null,
    livekit ? { ...livekit, logger: deps.logger.child({ component: 'calls' }) } : null,
  );
  if (config.APNS_KEY_PATH && config.APNS_KEY_ID && config.APNS_TEAM_ID) {
    const apns = new ApnsClient({
      key: await fs.readFile(config.APNS_KEY_PATH, 'utf8'),
      keyId: config.APNS_KEY_ID,
      teamId: config.APNS_TEAM_ID,
      topic: config.APNS_TOPIC,
      macosTopic: config.APNS_MACOS_TOPIC,
      logger: deps.logger.child({ component: 'apns' }),
    });
    const notifier = new PushNotifier(db, apns, {
      showPreview: config.APNS_PREVIEW,
      logger: deps.logger.child({ component: 'push' }),
      media: deps.media,
      isOnline: (deviceId) => deps.onlineDevices.has(deviceId),
    });
    deps.ingest.onNewMessage = (event) => notifier.onNewMessage(event);
    deps.ingest.onCall = (accountId, call) => notifier.onCall(accountId, call);
  }
  const app = await buildServer(deps);
  // QQ 表情资源放在媒体目录旁边（deploy/data/qface，见 tools/qface-sync.py）。
  registerQFaceRoutes(app, deps, path.join(config.MEDIA_ROOT, '..', 'qface'));
  if (upstream) await upstream.hub.register(app);
  if (config.CALL_LAB) {
    // 通话测试页（iOS 客户端完成前代替 iPhone 接听）。页面本身不含任何数据，接口照常要求登录。
    const labHtml = await fs.readFile(new URL('./calls/lab.html', import.meta.url), 'utf8');
    app.get('/lab/call', async (_req, reply) => reply.type('text/html; charset=utf-8').header('cache-control', 'no-store').send(labHtml));
  }
  await app.listen({ host: config.HOST, port: config.PORT });
  deps.logger.info(
    { host: config.HOST, port: config.PORT, upstream: Boolean(upstream), calls: Boolean(livekit && config.CALL_GATEWAY_TOKEN), push: Boolean(deps.ingest.onNewMessage), callLab: config.CALL_LAB },
    'qqbridge server listening',
  );
  await upstream?.start();

  fetcher =
    config.MEDIA_FETCH_CONCURRENCY > 0
      ? new MediaFetcher(db, deps.media, deps.ingest, opts.mediaSource ?? upstream?.mediaSource ?? new StoredUrlSource(), {
          concurrency: config.MEDIA_FETCH_CONCURRENCY,
          defaultMaxBytes: config.MEDIA_AUTO_FETCH_MAX_BYTES,
          priorityChatIds: () => deps.activeChats.chatIds(),
          logger: deps.logger.child({ component: 'media-fetcher' }),
        }, deps.processor)
      : null;
  fetcher?.start();
  if (fetcher) {
    const f = fetcher;
    deps.rehydrate = (sha256) => f.rehydrate(sha256);
    deps.pokeMediaFetcher = () => f.poke();
    deps.fetchMediaNow = (refId) => f.fetchNow(refId);
  }

  // 发送：发件箱 → 插件（x.send）。没有接上游时消息留在发件箱里，接上后自动发出。
  const outboxWorker = upstream
    ? new OutboxWorker(db, deps.outbox, upstream.hub, deps.signer, {
        mediaBaseUrl: config.UPSTREAM_MEDIA_BASE_URL ?? `http://host.internal:${config.PORT}`,
        logger: deps.logger.child({ component: 'outbox' }),
      })
    : null;
  if (upstream) {
    const base = (config.UPSTREAM_MEDIA_BASE_URL ?? `http://host.internal:${config.PORT}`).replace(/\/+$/, '');
    deps.stickers.pluginUrl = (sha256, name) => base + deps.signer.signNamed(sha256, name).url;
  }
  if (upstream && outboxWorker) {
    deps.outbox.onEnqueued = () => outboxWorker.poke();
    const onConnected = upstream.hub.onConnected;
    upstream.hub.onConnected = (info) => {
      onConnected?.(info);
      outboxWorker.poke();
    };
    outboxWorker.start();
  }
  const uploadCleanup = setInterval(
    () => void deps.uploads.cleanup().catch((error: unknown) => deps.logger.warn({ err: error }, 'upload cleanup failed')),
    3600_000,
  );
  uploadCleanup.unref();
  // 按保留策略清理原件：启动后 10 分钟跑一次，之后每天一次。
  const runRetention = () =>
    void deps.cleaner.runRetention().catch((error: unknown) => deps.logger.warn({ err: error }, 'retention cleanup failed'));
  const retentionFirst = setTimeout(runRetention, 10 * 60_000);
  const retentionDaily = setInterval(runRetention, 24 * 3600_000);
  retentionFirst.unref();
  retentionDaily.unref();

  deps.defaultAutoFetchMaxBytes = config.MEDIA_AUTO_FETCH_MAX_BYTES;
  deps.napcatWebUi = config.NAPCAT_WEBUI_TOKEN ? new NapcatWebUi(config.NAPCAT_WEBUI_URL, config.NAPCAT_WEBUI_TOKEN) : null;
  if (deps.media.hasColdTier) {
    // 外接盘在不在、后台进程有没有权限读（macOS 的"可移除宗卷"权限）都体现在这里。
    deps.logger.info({ root: config.MEDIA_COLD_ROOT, available: deps.media.coldAvailable }, 'cold storage');
  }
  deps.tiering.start();
  // 从 QQ 同步置顶、通知设置和"在别的设备上已读"：连上后 20 秒一次，之后每 5 分钟一次。
  const settingsSync = upstream ? new QqSettingsSync(db, upstream.hub, deps.dialogPrefs, deps.ingest, deps.logger.child({ component: 'qq-settings' })) : null;
  if (upstream && settingsSync) {
    const accounts = async () => (await rows<{ id: number }>(db, sql`select id from qq_accounts`)).map((r) => Number(r.id));
    settingsSync.start(accounts);
    const onConnected = upstream.hub.onConnected;
    upstream.hub.onConnected = (info) => {
      onConnected?.(info);
      setTimeout(() => void settingsSync.schedule(info.qqAccountId), 20_000).unref();
    };
  }
  if (upstream) deps.contacts.start(async () => (await rows<{ id: number }>(db, sql`select id from qq_accounts`)).map((r) => Number(r.id)));
  const close = async () => {
    deps.contacts.stop();
    settingsSync?.stop();
    deps.tiering.stop();
    clearInterval(uploadCleanup);
    clearTimeout(retentionFirst);
    clearInterval(retentionDaily);
    await outboxWorker?.stop();
    await upstream?.stop();
    await fetcher?.stop();
    await app.close();
    await db.$client.end();
  };
  return { app, deps, fetcher, upstream, close };
}
