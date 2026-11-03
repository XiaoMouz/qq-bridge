import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { ImportError } from '../imports/service.ts';
import type { ApiDeps } from './context.ts';

const createInput = z.object({ qqAccountId: z.number().int().positive(), backupPath: z.string().min(1), keysPath: z.string().min(1), batchSize: z.number().int().min(1).max(500).optional() });
const params = z.object({ id: z.uuid() });

/** 本地目录预检接口沿用设备令牌鉴权；路径还须通过服务端白名单。 */
export function registerImportRoutes(app: FastifyInstance, deps: ApiDeps): void {
  app.register(async routes => {
    routes.addHook('onRequest', async (request, reply) => {
      const header = request.headers.authorization ?? '';
      const auth = header.startsWith('Bearer ') ? await deps.auth.authenticate(header.slice(7).trim()) : null;
      if (!auth) return reply.code(401).send({ error: 'unauthenticated' });
      request.backupAccountId = auth.accountId;
      reply.header('cache-control', 'no-store');
    });
    routes.setErrorHandler((error, _request, reply) => {
      if (error instanceof ImportError) return reply.code(error.status).send({ error: error.message });
      if (error instanceof z.ZodError) return reply.code(400).send({ error: '请求参数无效', issues: error.issues });
      deps.logger.error({ err: error }, 'backup import API failed');
      return reply.code(500).send({ error: '备份任务操作失败' });
    });
    routes.post('/imports', async (request, reply) => reply.code(202).send(await deps.imports.create(request.backupAccountId!, createInput.parse(request.body))));
    routes.get('/imports', request => deps.imports.list(request.backupAccountId!));
    routes.get('/imports/:id', request => deps.imports.status(request.backupAccountId!, params.parse(request.params).id));
    routes.post('/imports/:id/pause', async (request, reply) => reply.code(202).send(await deps.imports.pause(request.backupAccountId!, params.parse(request.params).id)));
    routes.post('/imports/:id/resume', async (request, reply) => reply.code(202).send(await deps.imports.resume(request.backupAccountId!, params.parse(request.params).id)));
    routes.get('/imports/:id/reports/:view', request => {
      const p = params.extend({ view: z.string() }).parse(request.params);
      const q = z.object({ cursor: z.coerce.number().int().nonnegative().default(0), limit: z.coerce.number().int().min(1).max(500).default(100), kind: z.string().max(100).default('') }).parse(request.query);
      return deps.imports.report(request.backupAccountId!, p.id, p.view, q.cursor, q.limit, q.kind);
    });
  });
}

declare module 'fastify' {
  interface FastifyRequest { backupAccountId?: number }
}
