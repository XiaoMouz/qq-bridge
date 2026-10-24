import { fastifyConnectPlugin } from '@connectrpc/connect-fastify';
import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from 'fastify';
import { authInterceptor, errorInterceptor, type ApiDeps } from './context.ts';
import { parseRange } from './media-urls.ts';
import { registerServices } from './services.ts';
import { registerUploadRoutes } from './upload-routes.ts';
import { RpcTiming } from './rpc-timing.ts';

const SHA256 = /^[0-9a-f]{64}$/;

export async function buildServer(deps: ApiDeps): Promise<FastifyInstance> {
  // forceCloseConnections：关闭时直接断开长连接（订阅流的客户端会自动重连并用差量追平），避免关停被流挂住。
  const app = Fastify({ logger: false, bodyLimit: 4 * 1024 * 1024, forceCloseConnections: true });

  const pool = deps.db.$client;
  const timing = new RpcTiming(deps.logger.child({ component: 'rpc' }), 1000, () => ({
    total: pool.totalCount,
    idle: pool.idleCount,
    waiting: pool.waitingCount,
  }));
  await app.register(fastifyConnectPlugin, {
    routes: (router) => registerServices(router, deps),
    // 第一个拦截器在最外层：先计时（含认证和错误映射），再映射错误，再做认证。
    interceptors: [timing.interceptor(), errorInterceptor(deps.logger), authInterceptor(deps.auth)],
  });
  const timingLog = setInterval(() => {
    const summary = timing.drain();
    if (Object.keys(summary).length > 0) deps.logger.info({ rpc: summary, pool: timing.poolStats() }, 'rpc latency (ms)');
  }, 60_000);
  timingLog.unref();
  app.addHook('onClose', async () => clearInterval(timingLog));

  app.get('/healthz', async () => ({ ok: true }));
  registerUploadRoutes(app, deps);

  // 媒体下载：签名链接 + Range，支持边下边播。可选的文件名段只用于下载方识别类型和保存时的文件名。
  type MediaRequest = FastifyRequest<{ Params: { sha256: string; name?: string }; Querystring: { exp?: string; sig?: string } }>;
  const serveMedia = async (request: MediaRequest, reply: FastifyReply) => {
    const { sha256, name } = request.params;
    if (!SHA256.test(sha256) || !deps.signer.verify(sha256, request.query.exp, request.query.sig)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    let blob = await deps.media.getBlob(sha256);
    if (!blob) return reply.code(404).send({ error: 'not found' });
    if (blob.state === 'purged' || (blob.tier === 'cold' && !deps.media.coldAvailable)) {
      // 原件已清理（按需会话只留了缩略图和预览图），或者冷存储的外接盘不在：当场从 QQ 取回一份放进热存储；
      // 拿不到就告诉客户端已过期。
      const result = deps.rehydrate ? await deps.rehydrate(sha256) : 'expired';
      if (result !== 'restored') return reply.code(410).send({ error: 'expired', reason: result === 'unavailable' ? 'qq_offline' : 'not_available' });
      blob = await deps.media.getBlob(sha256);
      if (!blob || blob.state !== 'present') return reply.code(410).send({ error: 'expired' });
    }
    // 记访问：冷存储里的内容常被打开时提回热存储（见 media/tiering.ts）。
    deps.tiering.onAccess(sha256);

    const etag = `"${blob.sha256}"`;
    reply
      .header('accept-ranges', 'bytes')
      .header('etag', etag)
      .header('cache-control', 'private, max-age=31536000, immutable')
      .header('content-type', blob.mime ?? 'application/octet-stream');
    if (name) reply.header('content-disposition', `inline; filename*=UTF-8''${encodeURIComponent(name)}`);
    if (request.headers['if-none-match'] === etag) return reply.code(304).send();

    const range = parseRange(request.headers.range, blob.size);
    if (range === 'invalid') return reply.code(416).header('content-range', `bytes */${blob.size}`).send();
    if (range) {
      reply
        .code(206)
        .header('content-range', `bytes ${range.start}-${range.end}/${blob.size}`)
        .header('content-length', range.end - range.start + 1);
      return reply.send(await deps.media.openBlob(blob, range));
    }
    reply.header('content-length', blob.size);
    return reply.send(await deps.media.openBlob(blob));
  };
  app.get('/media/:sha256', serveMedia);
  app.get('/media/:sha256/:name', serveMedia);

  return app;
}
