import type { AddressInfo } from 'node:net';
import type http from 'node:http';
import { afterEach, describe, expect, it } from 'vitest';
import { startGatewayServer } from '../src/serve.ts';

const TOKEN = 't'.repeat(32);
let server: http.Server | null = null;
afterEach(() => {
  server?.close();
  server = null;
});

async function start() {
  const events: string[] = [];
  server = await startGatewayServer({
    host: '127.0.0.1',
    port: 0,
    token: TOKEN,
    livekitUrl: 'ws://unused',
    pulseServer: 'unused',
    log: () => undefined,
    createBridge: (room, token) => ({
      stats: { framesSent: 0, framesDropped: 0, framesReceived: 0, remoteIdentity: null, connected: true },
      start: async () => void events.push(`start ${room} ${token}`),
      stop: async () => void events.push(`stop ${room}`),
    }),
  });
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const call = (method: string, path: string, body?: unknown, token = TOKEN) =>
    fetch(base + path, {
      method,
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
  return { events, call };
}

describe('gateway control API', () => {
  it('requires the token', async () => {
    const { call } = await start();
    expect((await call('GET', '/status', undefined, 'x'.repeat(32))).status).toBe(401);
    expect((await call('GET', '/status')).status).toBe(200);
  });

  it('bridges one room at a time, ignores repeated joins and leaves on request', async () => {
    const { events, call } = await start();
    expect((await call('POST', '/bridges', { room: 'r1', token: 'a' })).status).toBe(200);
    expect((await call('POST', '/bridges', { room: 'r1', token: 'a' })).status).toBe(200); // 重试
    expect((await call('POST', '/bridges', { room: 'r2', token: 'b' })).status).toBe(200); // 换房间：先退出 r1
    expect(await (await call('GET', '/status')).json()).toMatchObject({ room: 'r2' });
    expect((await call('DELETE', '/bridges/r1')).status).toBe(404);
    expect((await call('DELETE', '/bridges/r2')).status).toBe(200);
    expect(events).toEqual(['start r1 a', 'stop r1', 'start r2 b', 'stop r2']);
    expect((await call('POST', '/bridges', { room: '' })).status).toBe(400);
  });
});
