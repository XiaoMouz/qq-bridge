import { Code, ConnectError, createContextKey, type HandlerContext, type Interceptor } from '@connectrpc/connect';
import type { Logger } from 'pino';
import { InvalidCredentialsError, type AuthContext, type AuthService } from '../auth/service.ts';
import type { AdminService } from '../admin/service.ts';
import type { NapcatWebUi } from '../admin/napcat-webui.ts';
import type { CallService } from '../calls/service.ts';
import type { ContactService } from '../contacts/service.ts';
import type { ForwardService } from '../messages/forwards.ts';
import type { MessageInteractions } from '../messages/interactions.ts';
import type { Db } from '../db/client.ts';
import type { DialogPrefs } from '../dialogs/prefs.ts';
import type { IngestService } from '../ingest/service.ts';
import type { MediaCleaner } from '../media/cleanup.ts';
import type { MediaProcessor } from '../media/processing.ts';
import type { RehydrateResult } from '../media/fetcher.ts';
import type { MediaService } from '../media/service.ts';
import type { TierManager } from '../media/tiering.ts';
import type { StorageBackend } from '../media/store.ts';
import type { UploadService } from '../media/upload.ts';
import type { OutboxService } from '../outbox/service.ts';
import type { HoleFiller } from '../upstream/history.ts';
import type { UpstreamHub } from '../upstream/hub.ts';
import { NotFoundError } from '../sync/difference.ts';
import type { ActiveChats } from '../sync/active-chats.ts';
import type { UpdateBus } from '../sync/bus.ts';
import type { MediaUrlSigner } from './media-urls.ts';

export interface ApiDeps {
  db: Db;
  bus: UpdateBus;
  ingest: IngestService;
  auth: AuthService;
  media: MediaService;
  backend: StorageBackend;
  uploads: UploadService;
  processor: MediaProcessor;
  outbox: OutboxService;
  dialogPrefs: DialogPrefs;
  cleaner: MediaCleaner;
  /** 上游（NapCat 插件）；没有配置 UPSTREAM_TOKEN 时为 null。发送、撤回、已读回写都经过它。 */
  upstream: Pick<UpstreamHub, 'call' | 'isConnected' | 'connections'> | null;
  /** 懒回填：往上翻页翻过了服务端最早的一条时，现场向 QQ 拉一页。没有上游时为 null。 */
  history: Pick<HoleFiller, 'backfillOlder' | 'holes' | 'schedule'> | null;
  calls: CallService;
  interactions: MessageInteractions;
  forwards: ForwardService;
  contacts: ContactService;
  tiering: TierManager;
  /** 冷存储的盘不在时从 QQ 取回内容（媒体下载任务提供；没有上游时为 null）。 */
  rehydrate: ((sha256: string) => Promise<RehydrateResult>) | null;
  admin: AdminService;
  /** NapCat WebUI（扫码登录中转）；没配 NAPCAT_WEBUI_TOKEN 时为 null。 */
  napcatWebUi: NapcatWebUi | null;
  /** 没有配置自动下载上限时的默认值（MEDIA_AUTO_FETCH_MAX_BYTES）。 */
  defaultAutoFetchMaxBytes: number;
  signer: MediaUrlSigner;
  activeChats: ActiveChats;
  logger: Logger;
}

export const authKey = createContextKey<AuthContext | null>(null);

export function requireAuth(ctx: HandlerContext): AuthContext {
  const auth = ctx.values.get(authKey);
  if (!auth) throw new ConnectError('unauthenticated', Code.Unauthenticated);
  return auth;
}

/** 除 AuthService.Login 外，所有 RPC 都要求 Authorization: Bearer <设备令牌>。 */
export function authInterceptor(auth: AuthService): Interceptor {
  return (next) => async (req) => {
    if (req.service.typeName === 'qqbridge.v1.AuthService' && req.method.name === 'Login') return next(req);
    const header = req.header.get('authorization') ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
    const ctx = token ? await auth.authenticate(token) : null;
    if (!ctx) throw new ConnectError('unauthenticated', Code.Unauthenticated);
    req.contextValues.set(authKey, ctx);
    return next(req);
  };
}

/** 把领域错误映射成 Connect 错误码；未知错误记日志后返回 Internal（不把内部细节暴露给客户端）。 */
export function errorInterceptor(logger: Logger): Interceptor {
  return (next) => async (req) => {
    try {
      return await next(req);
    } catch (error) {
      if (error instanceof ConnectError) throw error;
      if (error instanceof NotFoundError) throw new ConnectError(error.message, Code.NotFound);
      if (error instanceof InvalidCredentialsError) throw new ConnectError(error.message, Code.Unauthenticated);
      if (error instanceof RangeError) throw new ConnectError(error.message, Code.InvalidArgument);
      logger.error({ err: error, method: `${req.service.typeName}/${req.method.name}` }, 'rpc failed');
      throw new ConnectError('internal error', Code.Internal);
    }
  };
}
