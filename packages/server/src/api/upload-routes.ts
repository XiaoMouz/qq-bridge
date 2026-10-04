// tus 1.0 核心协议的上传端点（创建走 MediaService.PrepareUpload，先做秒传判定）：
//   HEAD  /upload/:id → Upload-Offset / Upload-Length（断线后查进度）
//   PATCH /upload/:id → 从 Upload-Offset 处追加（Content-Type: application/offset+octet-stream）
// 鉴权与 RPC 相同：Authorization: Bearer <设备令牌>，只能操作自己账号的上传。
import type { Readable } from 'node:stream';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { UploadError } from '../media/upload.ts';
import type { ApiDeps } from './context.ts';

const TUS_VERSION = '1.0.0';

export function registerUploadRoutes(app: FastifyInstance, deps: ApiDeps): void {
  // 不解析请求体，直接把流交给上传服务（大小由上传服务按声明的长度把关）。
  app.addContentTypeParser('application/offset+octet-stream', (_request, payload, done) => done(null, payload));

  const authenticate = async (request: FastifyRequest, reply: FastifyReply) => {
    const header = request.headers.authorization ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
    const auth = token ? await deps.auth.authenticate(token) : null;
    if (!auth) {
      await reply.code(401).header('tus-resumable', TUS_VERSION).send();
      return null;
    }
    return auth;
  };

  app.options('/upload/:id', async (_request, reply) =>
    reply.code(204).header('tus-resumable', TUS_VERSION).header('tus-version', TUS_VERSION).send(),
  );

  app.route<{ Params: { id: string } }>({
    method: 'HEAD',
    url: '/upload/:id',
    handler: async (request, reply) => {
      const auth = await authenticate(request, reply);
      if (!auth) return reply;
      const status = await deps.uploads.status(auth.accountId, request.params.id).catch(() => null);
      reply.header('tus-resumable', TUS_VERSION).header('cache-control', 'no-store');
      if (!status) return reply.code(404).send();
      return reply.code(200).header('upload-offset', status.offset).header('upload-length', status.size).send();
    },
  });

  app.patch<{ Params: { id: string } }>('/upload/:id', async (request, reply) => {
    const auth = await authenticate(request, reply);
    if (!auth) return reply;
    reply.header('tus-resumable', TUS_VERSION);
    const offset = Number(request.headers['upload-offset']);
    if (!Number.isSafeInteger(offset) || offset < 0) return reply.code(400).send({ error: 'Upload-Offset is required' });
    try {
      const result = await deps.uploads.append(auth.accountId, request.params.id, offset, request.body as Readable);
      reply.header('upload-offset', result.offset);
      if (result.sha256) reply.header('upload-sha256', result.sha256);
      return reply.code(204).send();
    } catch (error) {
      if (error instanceof UploadError) return reply.code(error.status).send({ error: error.message });
      throw error;
    }
  });
}
