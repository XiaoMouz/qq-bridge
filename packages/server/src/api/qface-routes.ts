// QQ 表情资源（tools/qface-sync.py 下载到 deploy/data/qface，来源 koishijs/QFace）：
//   GET /qface/:id/:kind/:name   kind = png | apng | lottie，例如 /qface/451/lottie/451.json
// 客户端没带的新表情图、超级表情的动画从这里取。鉴权与 RPC 相同（Authorization: Bearer <设备令牌>）。
import fs from 'node:fs';
import path from 'node:path';
import type { FastifyInstance } from 'fastify';
import type { ApiDeps } from './context.ts';

const KINDS = new Set(['png', 'apng', 'lottie']);
const TYPES: Record<string, string> = { '.png': 'image/png', '.json': 'application/json' };

export function registerQFaceRoutes(app: FastifyInstance, deps: ApiDeps, root: string): void {
  const base = path.resolve(root);
  app.get<{ Params: { id: string; kind: string; name: string } }>('/qface/:id/:kind/:name', async (request, reply) => {
    const header = request.headers.authorization ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
    if (!token || !(await deps.auth.authenticate(token))) return reply.code(401).send({ error: 'unauthenticated' });
    const { id, kind, name } = request.params;
    if (!KINDS.has(kind) || id.includes('/') || id.includes('..') || name.includes('/') || name.includes('..')) {
      return reply.code(400).send({ error: 'bad path' });
    }
    const file = path.resolve(base, id, kind, name);
    if (!file.startsWith(base + path.sep)) return reply.code(400).send({ error: 'bad path' });
    const stat = await fs.promises.stat(file).catch(() => null);
    if (!stat?.isFile()) return reply.code(404).send({ error: 'not found' });
    reply
      .header('content-type', TYPES[path.extname(name)] ?? 'application/octet-stream')
      .header('content-length', stat.size)
      .header('cache-control', 'private, max-age=604800');
    return reply.send(fs.createReadStream(file));
  });
}
