import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import type { PluginLogger } from './napcat.js';

export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export interface RouteRequest {
  url: URL;
  body: unknown;
}

export type RouteHandler = (req: RouteRequest) => unknown | Promise<unknown>;

const MAX_BODY_BYTES = 2 * 1024 * 1024;

/**
 * 插件控制接口：只监听回环地址，除 /healthz 外都要求 Bearer token。
 * 响应统一为 { code: 0, data } 或 { code: -1, message }。
 */
export class ControlServer {
  private readonly routes = new Map<string, RouteHandler>();
  private server: http.Server | null = null;

  constructor(
    private readonly host: string,
    private readonly port: number,
    private readonly token: string,
    private readonly logger: PluginLogger,
  ) {}

  route(method: 'GET' | 'POST', pathname: string, handler: RouteHandler): void {
    this.routes.set(`${method} ${pathname}`, handler);
  }

  async start(): Promise<void> {
    const server = http.createServer((req, res) => {
      void this.dispatch(req, res);
    });
    server.on('clientError', (_error, socket) => socket.destroy());
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(this.port, this.host, () => resolve());
    });
    this.server = server;
  }

  async close(): Promise<void> {
    const server = this.server;
    this.server = null;
    if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  private async dispatch(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    const url = new URL(req.url ?? '/', `http://${this.host}:${this.port}`);
    if (req.method === 'GET' && url.pathname === '/healthz') {
      return send(res, 200, { ok: true });
    }
    if (!this.authorized(req)) {
      return send(res, 401, { code: -1, message: 'Unauthorized' });
    }
    const handler = this.routes.get(`${req.method} ${url.pathname}`);
    if (!handler) return send(res, 404, { code: -1, message: 'Not Found' });
    try {
      const body = req.method === 'POST' ? await readJson(req) : undefined;
      const data = await handler({ url, body });
      return send(res, 200, { code: 0, data: data ?? null });
    } catch (error) {
      if (error instanceof HttpError) return send(res, error.status, { code: -1, message: error.message });
      this.logger.warn(`[qqbridge] ${req.method} ${url.pathname} failed:`, error);
      return send(res, 500, { code: -1, message: error instanceof Error ? error.message : String(error) });
    }
  }

  private authorized(req: http.IncomingMessage): boolean {
    const header = req.headers.authorization ?? '';
    if (!header.startsWith('Bearer ')) return false;
    const supplied = Buffer.from(header.slice(7), 'utf8');
    const expected = Buffer.from(this.token, 'utf8');
    return supplied.length === expected.length && timingSafeEqual(supplied, expected);
  }
}

async function readJson(req: http.IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buf = chunk as Buffer;
    size += buf.length;
    if (size > MAX_BODY_BYTES) throw new HttpError(413, 'request body is too large');
    chunks.push(buf);
  }
  const text = Buffer.concat(chunks).toString('utf8');
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, 'invalid JSON body');
  }
}

function send(res: http.ServerResponse, status: number, body: unknown): void {
  const encoded = Buffer.from(
    JSON.stringify(body, (_key, value) => (typeof value === 'bigint' ? value.toString() : value)),
  );
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': encoded.byteLength,
    'Cache-Control': 'no-store',
  });
  res.end(encoded);
}
