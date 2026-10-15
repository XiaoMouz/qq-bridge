// 推送：APNs 客户端（对着本地的 HTTP/2 服务）和"哪些消息要推、通知里写什么"。
import { generateKeyPairSync, randomUUID, verify } from 'node:crypto';
import http2 from 'node:http2';
import type { AddressInfo } from 'node:net';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { CallRecord } from '../src/calls/service.ts';
import { DialogPrefs } from '../src/dialogs/prefs.ts';
import { one } from '../src/db/client.ts';
import { ApnsClient, type ApnsMessage, type ApnsResult, type PushSender } from '../src/push/apns.ts';
import { PushNotifier } from '../src/push/notifier.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage, type TestAccount } from './helpers/fixtures.ts';

describe('ApnsClient', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  let server: http2.Http2Server;
  let origin: string;
  const seen: { headers: http2.IncomingHttpHeaders; body: string }[] = [];
  let reply: (token: string) => { status: number; reason?: string } = () => ({ status: 200 });

  beforeAll(async () => {
    server = http2.createServer((req, res) => {
      let body = '';
      req.on('data', (c: Buffer) => (body += c.toString('utf8')));
      req.on('end', () => {
        seen.push({ headers: req.headers, body });
        const r = reply(String(req.headers[':path']).split('/').pop()!);
        res.writeHead(r.status, { 'content-type': 'application/json' });
        res.end(r.reason ? JSON.stringify({ reason: r.reason }) : '');
      });
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  afterAll(() => server?.close());

  const client = () =>
    new ApnsClient({
      key: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
      keyId: 'KEYID00001',
      teamId: 'TEAMID0001',
      topic: 'com.example.app',
      macosTopic: 'com.example.app.mac',
      origins: { sandbox: origin, production: origin },
    });

  it('sends a signed request with the APNs headers', async () => {
    const c = client();
    expect(await c.send({ token: 'ab12', env: 'sandbox', payload: { aps: { alert: 'hi' } }, collapseId: 'x' })).toEqual({ ok: true });
    c.close();
    const { headers, body } = seen.at(-1)!;
    expect(headers[':path']).toBe('/3/device/ab12');
    expect(headers).toMatchObject({ 'apns-topic': 'com.example.app', 'apns-push-type': 'alert', 'apns-priority': '10', 'apns-collapse-id': 'x' });
    expect(JSON.parse(body)).toEqual({ aps: { alert: 'hi' } });
    // JWT：ES256，kid / iss 正确，签名能用公钥验过。
    const [h, p, s] = String(headers.authorization).replace('bearer ', '').split('.');
    expect(JSON.parse(Buffer.from(h!, 'base64url').toString())).toEqual({ alg: 'ES256', kid: 'KEYID00001' });
    expect(JSON.parse(Buffer.from(p!, 'base64url').toString())).toMatchObject({ iss: 'TEAMID0001' });
    expect(verify('sha256', Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(s!, 'base64url'))).toBe(true);
  });

  it('routes Mac notifications and VoIP to the Mac topic without changing iOS', async () => {
    const c = client();
    try {
      await c.send({ token: 'mac', platform: 'macos', env: 'sandbox', payload: {} });
      expect(seen.at(-1)!.headers['apns-topic']).toBe('com.example.app.mac');
      await c.send({ token: 'mac-voip', platform: 'macos', env: 'production', pushType: 'voip', payload: {} });
      expect(seen.at(-1)!.headers['apns-topic']).toBe('com.example.app.mac.voip');
      await c.send({ token: 'phone', platform: 'ios', env: 'sandbox', payload: {} });
      expect(seen.at(-1)!.headers['apns-topic']).toBe('com.example.app');
    } finally {
      c.close();
    }
  });

  it('reports dead tokens so they can be dropped', async () => {
    reply = (token) => (token === 'dead' ? { status: 410, reason: 'Unregistered' } : { status: 400, reason: 'PayloadTooLarge' });
    const c = client();
    expect(await c.send({ token: 'dead', env: 'production', payload: {} })).toEqual({ ok: false, status: 410, reason: 'Unregistered', invalidToken: true });
    expect(await c.send({ token: 'beef', env: 'production', payload: {} })).toEqual({ ok: false, status: 400, reason: 'PayloadTooLarge', invalidToken: false });
    c.close();
    reply = () => ({ status: 200 });
  });
});

describe('来电推送与桌面持续同步', () => {
  let t: TestDb;
  let acc: TestAccount;
  let prefs: DialogPrefs;
  let groupChat: number;
  let notifier: PushNotifier;
  let online = true;
  let rejectVoip = false;
  const sent: ApnsMessage[] = [];
  const sender: PushSender = {
    send: async (message) => {
      sent.push(message);
      return rejectVoip && message.pushType === 'voip'
        ? { ok: false, status: 503, reason: 'ServiceUnavailable', invalidToken: false }
        : { ok: true };
    },
    close: () => undefined,
  };
  const incoming = (): CallRecord => ({
    callId: randomUUID(), qqAccountId: acc.qqAccountId, phase: 'ringing', incoming: true,
    media: 'voice', peerUin: 400, peerName: '测试来电', groupId: null,
    inviteAt: new Date(), acceptedAt: null, connectedAt: null, endedAt: null,
    endReason: null, answeredDeviceId: null, room: null,
  });
  beforeAll(async () => {
    t = await startTestDb();
    const svc = services(t.db);
    acc = await createTestAccount(t.db, svc.ingest);
    prefs = new DialogPrefs(svc.writers);
    groupChat = (await svc.ingest.ingestMessage(acc.qqAccountId, textMessage('group', 300, 1, 400))).chatId;
    await t.db.execute(sql`insert into devices (account_id, name, platform, token_hash, apns_token, apns_voip_token, apns_env)
      values (${acc.accountId}, 'iPhone', 'ios', '\\x11', 'ios-alert', 'ios-voip', 'sandbox'),
             (${acc.accountId}, 'Mac', 'macos', '\\x12', 'mac-alert', 'mac-voip', 'sandbox')`);
  });
  beforeEach(async () => {
    sent.length = 0;
    online = true;
    rejectVoip = false;
    notifier = new PushNotifier(t.db, sender, { isOnline: () => online });
    await prefs.setNotifyPolicy(acc.accountId, groupChat, 'all');
  });
  afterAll(async () => { await t?.stop(); });

  it('连接 Subscribe 时 Mac 仍收到系统来电，iOS 保持前台不推送', async () => {
    const call = incoming();
    expect(await notifier.notifyCall(acc.accountId, call)).toBe(1);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ token: 'mac-voip', platform: 'macos', pushType: 'voip', payload: { call: { id: call.callId } } });
    expect(await notifier.notifyCall(acc.accountId, call)).toBe(0);
    expect(sent).toHaveLength(1);
  });

  it('断开 Subscribe 后 iOS 与 Mac 都收到来电', async () => {
    online = false;
    expect(await notifier.notifyCall(acc.accountId, incoming())).toBe(2);
    expect(sent.map((m) => m.token).sort()).toEqual(['ios-voip', 'mac-voip']);
  });

  it('历史重复登记不会重复振铃，也不会在已投递 VoIP 后追加普通通知', async () => {
    online = false;
    await t.db.execute(sql`insert into devices (account_id, name, platform, token_hash, apns_token, apns_voip_token, apns_env)
      values (${acc.accountId}, '旧 iPhone', 'ios', '\\x13', 'ios-alert', 'ios-voip', 'sandbox')`);
    try {
      const call = incoming();
      expect(await notifier.notifyCall(acc.accountId, call)).toBe(2);
      expect(sent.map((m) => m.token).sort()).toEqual(['ios-voip', 'mac-voip']);
      sent.length = 0;
      expect(await notifier.notifyCall(acc.accountId, { ...call, phase: 'ended', endedAt: new Date() })).toBe(2);
      expect(sent.map((m) => m.token).sort()).toEqual(['ios-alert', 'mac-alert']);
      rejectVoip = true;
      sent.length = 0;
      expect(await notifier.notifyCall(acc.accountId, incoming())).toBe(2);
      expect(sent.map((m) => m.token).sort()).toEqual(['ios-alert', 'ios-voip', 'mac-alert', 'mac-voip']);
    } finally {
      await t.db.execute(sql`delete from devices where account_id = ${acc.accountId} and name = '旧 iPhone'`);
    }
  });

  it('Mac 的 VoIP 投递失败时回退普通来电通知', async () => {
    rejectVoip = true;
    expect(await notifier.notifyCall(acc.accountId, incoming())).toBe(1);
    expect(sent.map((m) => m.token)).toEqual(['mac-voip', 'mac-alert']);
    expect(sent[1]).toMatchObject({ platform: 'macos', payload: { aps: { 'interruption-level': 'time-sensitive' } } });
  });

  it.each(['muted', 'archived', 'mentions'] as const)('Mac 群语音仍遵守 %s 设置', async (policy) => {
    await prefs.setNotifyPolicy(acc.accountId, groupChat, policy);
    expect(await notifier.notifyCall(acc.accountId, { ...incoming(), groupId: 300 })).toBe(0);
    expect(sent).toHaveLength(0);
  });

  it('呼出不会变成来电；响铃结束后发送无声未接通知', async () => {
    expect(await notifier.notifyCall(acc.accountId, { ...incoming(), incoming: false })).toBe(0);
    const call = incoming();
    await notifier.notifyCall(acc.accountId, call);
    sent.length = 0;
    expect(await notifier.notifyCall(acc.accountId, { ...call, phase: 'ended', endedAt: new Date() })).toBe(2);
    expect(sent.map((m) => m.token).sort()).toEqual(['ios-alert', 'mac-alert']);
    for (const message of sent) {
      expect(message.payload).toMatchObject({ aps: { alert: { body: '未接语音通话' } } });
      expect((message.payload as { aps: Record<string, unknown> }).aps.sound).toBeUndefined();
    }
  });
});

describe('PushNotifier', () => {
  let t: TestDb;
  let svc: ReturnType<typeof services>;
  let acc: TestAccount;
  let prefs: DialogPrefs;
  const sent: ApnsMessage[] = [];
  let answer: (m: ApnsMessage) => ApnsResult = () => ({ ok: true });
  const sender: PushSender = { send: async (m) => (sent.push(m), answer(m)), close: () => undefined };
  let notifier: PushNotifier;
  let seq = 1;

  beforeAll(async () => {
    t = await startTestDb();
    svc = services(t.db);
    acc = await createTestAccount(t.db, svc.ingest);
    prefs = new DialogPrefs(svc.writers);
    notifier = new PushNotifier(t.db, sender, { now: () => (1_800_000_000 + seq) * 1000 });
    await t.db.execute(sql`insert into devices (account_id, name, platform, token_hash, apns_token, apns_env)
                           values (${acc.accountId}, 'iPhone', 'ios', '\\x01', 'aaaa', 'sandbox'),
                                  (${acc.accountId}, 'iPad', 'ios', '\\x02', 'bbbb', 'production'),
                                  (${acc.accountId}, 'Mac', 'macos', '\\x03', null, null)`);
    await t.db.execute(sql`insert into peers (qq_account_id, kind, peer_id, name, pts) values (${acc.qqAccountId}, 'group', 300, '测试群', 0),
                                                                                          (${acc.qqAccountId}, 'user', 400, '小明', 0)`);
    await t.db.execute(sql`insert into group_members (qq_account_id, group_id, user_id, card, nickname) values (${acc.qqAccountId}, 300, 401, '群名片', '昵称')`);
  });
  afterAll(async () => {
    await t?.stop();
  });

  async function receive(msg: ReturnType<typeof textMessage>) {
    const { chatId } = await svc.ingest.ingestMessage(acc.qqAccountId, msg);
    sent.length = 0;
    const n = await notifier.notify({ accountId: acc.accountId, chatId, seq: msg.seq });
    return { chatId, n };
  }
  const chatOf = async (scene: string, peer: number) =>
    (await one<{ id: number }>(t.db, sql`select id from chats where scene = ${scene} and peer_id = ${peer}`)).id;

  it('pushes private messages to every registered device, with title, body and badge', async () => {
    const s = seq++;
    const { chatId, n } = await receive(textMessage('friend', 400, s, 400, { text: '你好' }));
    expect(n).toBe(2);
    expect(sent.map((m) => [m.token, m.env])).toEqual([
      ['aaaa', 'sandbox'],
      ['bbbb', 'production'],
    ]);
    expect(sent[0]!.payload).toEqual({
      aps: { alert: { title: '小明', body: '你好' }, sound: 'default', badge: 1, 'thread-id': `chat-${chatId}`, 'mutable-content': 1 },
      chatId,
      seq: s,
      // 发送者：通知扩展据此显示头像（测试里没有头像）。
      sender: { id: 400, name: '小明' },
    });
  });

  it('preserves the stored device platform when delivering notifications', async () => {
    await t.db.execute(sql`update devices set apns_token = 'mac-token', apns_env = 'sandbox' where account_id = ${acc.accountId} and platform = 'macos'`);
    try {
      const { n } = await receive(textMessage('friend', 400, seq++, 400, { text: 'Mac 消息' }));
      expect(n).toBe(3);
      expect(sent.find((m) => m.token === 'mac-token')).toMatchObject({ platform: 'macos', env: 'sandbox' });
      expect(sent.find((m) => m.token === 'aaaa')).toMatchObject({ platform: 'ios' });
    } finally {
      await t.db.execute(sql`update devices set apns_token = null where account_id = ${acc.accountId} and platform = 'macos'`);
    }
  });

  it('prefixes the group member name (card first)', async () => {
    const s = seq++;
    await receive(textMessage('group', 300, s, 401, { text: '大家好' }));
    expect((sent[0]!.payload as { aps: { alert: unknown } }).aps.alert).toEqual({ title: '测试群', body: '群名片: 大家好' });
  });

  it('同一推送端点的多条登录记录只发送一次，不合并不同环境和平台', async () => {
    await t.db.execute(sql`insert into devices (account_id, name, platform, token_hash, apns_token, apns_env)
      values (${acc.accountId}, 'duplicate-test', 'ios', '\\x21', 'aaaa', 'sandbox'),
             (${acc.accountId}, 'duplicate-test', 'ios', '\\x22', 'aaaa', 'production'),
             (${acc.accountId}, 'duplicate-test', 'macos', '\\x23', 'aaaa', 'sandbox')`);
    try {
      expect((await receive(textMessage('friend', 400, seq++, 400))).n).toBe(4);
      expect(sent.filter((m) => m.token === 'aaaa' && m.env === 'sandbox' && m.platform === 'ios')).toHaveLength(1);
      expect(sent.filter((m) => m.token === 'aaaa' && m.env === 'production')).toHaveLength(1);
      expect(sent.filter((m) => m.platform === 'macos')).toHaveLength(1);
    } finally {
      await t.db.execute(sql`delete from devices where account_id = ${acc.accountId} and name = 'duplicate-test'`);
    }
  });

  it('skips own messages, backfill and stale messages', async () => {
    expect((await receive(textMessage('friend', 400, seq++, acc.uin, { self: true }))).n).toBe(0);
    expect((await receive(textMessage('friend', 400, seq++, 400, { source: 'backfill' }))).n).toBe(0);
    expect((await receive(textMessage('friend', 400, seq++, 400, { time: 1_700_000_000 }))).n).toBe(0);
  });

  it('respects the chat notification policy', async () => {
    const group = await chatOf('group', 300);
    await prefs.setNotifyPolicy(acc.accountId, group, 'muted');
    expect((await receive(textMessage('group', 300, seq++, 401))).n).toBe(0);

    await prefs.setNotifyPolicy(acc.accountId, group, 'mentions');
    expect((await receive(textMessage('group', 300, seq++, 401))).n).toBe(0);
    const at = await receive(textMessage('group', 300, seq++, 401, { text: ' 看这个', extra: [{ type: 'mention', userId: acc.uin, name: '我' }] }));
    expect(at.n).toBe(2);
    expect((sent[0]!.payload as { aps: { alert: { body: string } } }).aps.alert.body).toBe('[有人@我] 群名片: @我 看这个');
    // @全体成员：默认提醒，关掉后不推。
    expect((await receive(textMessage('group', 300, seq++, 401, { extra: [{ type: 'mention_all' }] }))).n).toBe(2);
    await prefs.setMentionAllNotify(acc.accountId, group, false);
    expect((await receive(textMessage('group', 300, seq++, 401, { extra: [{ type: 'mention_all' }] }))).n).toBe(0);
  });

  it('badge: all unread in chats that notify, only @me and replies elsewhere, never @all on its own', async () => {
    const group = await chatOf('group', 300);
    await prefs.setNotifyPolicy(acc.accountId, group, 'archived');
    const s = seq++;
    await receive(textMessage('friend', 400, s, 400));
    const counts = await one<{ friend: number; mentions: number; replies: number; all: number }>(
      t.db,
      sql`select (select unread_count from chats where scene = 'friend' and peer_id = 400) as friend,
                 unread_mentions as mentions, unread_replies as replies, unread_mention_all as all
            from chats where id = ${group}`,
    );
    expect(counts.mentions).toBeGreaterThan(0);
    expect(counts.all).toBeGreaterThan(0);
    expect((sent[0]!.payload as { aps: { badge: number } }).aps.badge).toBe(counts.friend + counts.mentions + counts.replies);
  });

  it('drops tokens APNs says are dead', async () => {
    answer = (m) => (m.token === 'aaaa' ? { ok: false, status: 410, reason: 'Unregistered', invalidToken: true } : { ok: true });
    expect((await receive(textMessage('friend', 400, seq++, 400))).n).toBe(1);
    const row = await one<{ n: number }>(t.db, sql`select count(*)::int as n from devices where account_id = ${acc.accountId} and apns_token is not null`);
    expect(row.n).toBe(1);
    answer = () => ({ ok: true });
  });

  it('ingest calls the hook for messages from others only', async () => {
    const events: number[] = [];
    svc.ingest.onNewMessage = (e) => events.push(e.seq);
    const a = seq++;
    const b = seq++;
    await svc.ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 400, a, 400));
    await svc.ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 400, b, acc.uin, { self: true }));
    await svc.ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 400, a, 400)); // 重复
    svc.ingest.onNewMessage = null;
    expect(events).toEqual([a]);
  });
});
