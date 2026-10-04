import { afterEach, describe, expect, it } from 'vitest';
import { ControlServer, HttpError } from '../src/control-server.js';

const TOKEN = 't'.repeat(40);
const logger = { log() {}, info() {}, warn() {}, error() {} };
let server: ControlServer | null = null;

async function startServer(): Promise<string> {
  const port = 20000 + Math.floor(Math.random() * 20000);
  server = new ControlServer('127.0.0.1', port, TOKEN, logger);
  server.route('GET', '/ping', () => ({ pong: true }));
  server.route('POST', '/echo', ({ body }) => body);
  server.route('GET', '/conflict', () => {
    throw new HttpError(409, 'busy');
  });
  await server.start();
  return `http://127.0.0.1:${port}`;
}

afterEach(async () => {
  await server?.close();
  server = null;
});

describe('ControlServer', () => {
  it('serves /healthz without auth and rejects other routes without the token', async () => {
    const base = await startServer();
    expect(await (await fetch(`${base}/healthz`)).json()).toEqual({ ok: true });
    expect((await fetch(`${base}/ping`)).status).toBe(401);
    expect((await fetch(`${base}/ping`, { headers: { Authorization: 'Bearer wrong' } })).status).toBe(401);
  });

  it('routes authorized requests and maps HttpError to its status', async () => {
    const base = await startServer();
    const auth = { Authorization: `Bearer ${TOKEN}` };
    expect(await (await fetch(`${base}/ping`, { headers: auth })).json()).toEqual({ code: 0, data: { pong: true } });
    const echo = await fetch(`${base}/echo`, {
      method: 'POST',
      headers: { ...auth, 'Content-Type': 'application/json' },
      body: JSON.stringify({ a: 1 }),
    });
    expect(await echo.json()).toEqual({ code: 0, data: { a: 1 } });
    const conflict = await fetch(`${base}/conflict`, { headers: auth });
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toEqual({ code: -1, message: 'busy' });
    expect((await fetch(`${base}/missing`, { headers: auth })).status).toBe(404);
  });
});
