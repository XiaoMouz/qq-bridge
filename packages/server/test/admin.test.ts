// 管理：深度归档（从第一条补起、排在普通缺口之后）、存档完整性列表、NapCat WebUI 扫码登录中转。
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { createHash } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one } from '../src/db/client.ts';
import { NapcatWebUi } from '../src/admin/napcat-webui.ts';
import { AdminService } from '../src/admin/service.ts';
import { CallService } from '../src/calls/service.ts';
import { MediaService } from '../src/media/service.ts';
import { LocalFsBackend } from '../src/media/store.ts';
import { HoleFiller } from '../src/upstream/history.ts';
import { InboxProcessor } from '../src/upstream/inbox.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { FakeQq } from './helpers/fake-qq.ts';
import { createTestAccount, services, textMessage } from './helpers/fixtures.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

describe('deep archive and archive status', () => {
  it('fills history from the very first message after ordinary holes, then reports it complete', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq(acc.uin);
    qq.chat(2, '970001', 120, () => '20002');
    for (const seq of [80, 81, 100, 120]) await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 970001, seq, 20002));
    const filler = new HoleFiller(t.db, qq, new InboxProcessor(t.db, ingest), null, { sleep: async () => {} });
    const hub = Object.assign(qq, { isConnected: () => true, connections: () => [] });
    const admin = new AdminService(t.db, {
      upstream: () => hub,
      history: () => filler,
      calls: () => new CallService(t.db, ingest, null, null, null),
      media: new MediaService(t.db, new LocalFsBackend('/tmp/qqbridge-admin-unused')),
    });
    const chatId = (await one<{ id: number }>(t.db, sql`select id from chats where qq_account_id = ${acc.qqAccountId} and peer_id = 970001`)).id;

    let status = (await admin.archiveStatus(acc.accountId, 10)).find((c) => c.chatId === chatId)!;
    expect(status).toMatchObject({ earliestSeq: 80, topSeq: 120, holes: 2, missingSeqs: 37, deepArchive: false, historyComplete: false });

    expect(await admin.setDeepArchive(acc.accountId, chatId, true)).toBe(true);
    const holes = await filler.holes(acc.qqAccountId, chatId);
    expect(holes.find((h) => h.deep)).toMatchObject({ lower: 1, upper: 80 });

    await filler.idle(); // setDeepArchive 已经安排了一轮
    await filler.fillHoles(acc.qqAccountId); // 再跑一轮：最早一条之前拿到空页，确认到头
    status = (await admin.archiveStatus(acc.accountId, 10)).find((c) => c.chatId === chatId)!;
    expect(status).toMatchObject({ earliestSeq: 1, holes: 0, missingSeqs: 0, deepArchive: true, historyComplete: true });

    const other = await createTestAccount(t.db, ingest);
    expect(await admin.setDeepArchive(other.accountId, chatId, true)).toBe(false); // 别人的会话
  });
});

describe('NapCat WebUI relay', () => {
  it('logs in with the token hash, reports the QR code and renews the credential when it expires', async () => {
    const token = 'webui-token-123';
    let issued = 0;
    let valid = '';
    let qrcode = 'https://txz.qq.com/p?k=old';
    const server = http.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        const send = (data: unknown, code = 0, status = 200) => {
          res.writeHead(status, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ code, message: code ? 'Unauthorized' : 'success', data }));
        };
        if (req.url === '/api/auth/login') {
          const ok = JSON.parse(body).hash === createHash('sha256').update(`${token}.napcat`).digest('hex');
          if (!ok) return send(null, -1);
          valid = `cred-${++issued}`;
          return send({ Credential: valid });
        }
        if (req.headers.authorization !== `Bearer ${valid}`) return send(null, -1, 401);
        if (req.url === '/api/QQLogin/CheckLoginStatus') return send({ isLogin: false, isOffline: false, loginPhase: 'qrcode', qrcodeurl: qrcode });
        if (req.url === '/api/QQLogin/RefreshQRcode') {
          qrcode = 'https://txz.qq.com/p?k=new';
          return send(null);
        }
        send(null, -1, 404);
      });
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    try {
      const webui = new NapcatWebUi(`http://127.0.0.1:${(server.address() as AddressInfo).port}`, token);
      expect(await webui.loginState()).toEqual({ loggedIn: false, offline: false, phase: 'qrcode', qrcodeUrl: 'https://txz.qq.com/p?k=old', error: '' });
      valid = 'rotated'; // 服务端那边凭据失效：自动重新登录一次
      expect(await webui.refreshQrcode()).toBe('https://txz.qq.com/p?k=new');
      expect(issued).toBe(2);
    } finally {
      server.close();
    }
  });
});
