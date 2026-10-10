// 未读分三种（@我 / @全体成员 / 回复我）、从 QQ 同步置顶与通知设置（本地改过的不覆盖）、在别的设备上已读、收藏表情。
import { Readable } from 'node:stream';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { sql } from 'drizzle-orm';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one } from '../src/db/client.ts';
import { DialogPrefs } from '../src/dialogs/prefs.ts';
import { MediaService } from '../src/media/service.ts';
import { StickerService } from '../src/media/stickers.ts';
import { LocalFsBackend } from '../src/media/store.ts';
import { getDifference } from '../src/sync/difference.ts';
import { mapRawMessage } from '../src/upstream/napcat/map.ts';
import { QqSettingsSync } from '../src/upstream/settings-sync.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage, type TestAccount } from './helpers/fixtures.ts';
import { el, raw } from './helpers/napcat.ts';

let t: TestDb;
let root: string;
beforeAll(async () => {
  t = await startTestDb();
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-settings-'));
});
afterAll(async () => {
  await t?.stop();
  await fs.rm(root, { recursive: true, force: true });
});

const chat = (acc: TestAccount, peer: number) =>
  one<{
    id: number;
    unread_count: number;
    unread_mentions: number;
    unread_mention_all: number;
    unread_replies: number;
    pinned: boolean;
    pinned_at: Date | null;
    notify_policy: string;
    read_inbox_max_seq: number;
  }>(t.db, sql`select * from chats where qq_account_id = ${acc.qqAccountId} and peer_id = ${peer}`);

describe('unread counters', () => {
  it('counts mentions of me, @all and replies to me separately', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 990001, 1, acc.uin, { self: true }));
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 990001, 2, 20002, { extra: [{ type: 'mention', userId: acc.uin }] }));
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 990001, 3, 20002, { extra: [{ type: 'mention_all' }] }));
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 990001, 4, 20002, { extra: [{ type: 'mention_all' }, { type: 'mention', userId: acc.uin }] }));
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 990001, 5, 20002, { extra: [{ type: 'reply', seq: 1, senderId: acc.uin }] }));
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 990001, 6, 20002, { extra: [{ type: 'reply', seq: 1, senderId: 30003 }] }));
    expect(await chat(acc, 990001)).toMatchObject({ unread_count: 5, unread_mentions: 2, unread_mention_all: 1, unread_replies: 1 });

    await ingest.markRead(acc.accountId, (await chat(acc, 990001)).id, 4);
    expect(await chat(acc, 990001)).toMatchObject({ unread_count: 2, unread_mentions: 0, unread_mention_all: 0, unread_replies: 1 });
  });
});

describe('QQ settings sync', () => {
  it('turns a raw QQ reply to my message into a reply badge, not an @, and clears it on read', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const from = (await getDifference(t.db, acc.accountId, 0)).pts;
    const push = async (r: ReturnType<typeof raw>) => {
      const action = mapRawMessage(r, { selfUin: acc.uin, source: 'realtime' });
      if (action.type !== 'message') throw new Error(action.type);
      await ingest.ingestMessage(acc.qqAccountId, action.message);
    };
    await push(raw({ chatType: 2, peer: '990002', seq: 10, sender: String(acc.uin), elements: [el.text('我发的')] }));
    // 新版 QQ 把被回复者的 QQ 号放在 senderUid 里（senderUin 为空），两种都要认。
    const viaUid = el.reply(10, '');
    viaUid.replyElement = { ...viaUid.replyElement, senderUin: '0', senderUid: String(acc.uin) } as typeof viaUid.replyElement;
    await push(raw({ chatType: 2, peer: '990002', seq: 11, sender: '20002', elements: [viaUid, el.text('回你')] }));
    // 和真实的 QQ 回复一样带着 "@被回复人"：只算回复我，不算 @我。
    await push(raw({ chatType: 2, peer: '990002', seq: 12, sender: '20002', elements: [el.reply(10, String(acc.uin)), el.at(String(acc.uin), 'me'), el.text('再回你')] }));
    await push(raw({ chatType: 2, peer: '990002', seq: 13, sender: '20002', elements: [el.reply(10, '30003'), el.text('回别人')] }));

    expect(await chat(acc, 990002)).toMatchObject({ unread_count: 3, unread_mentions: 0, unread_mention_all: 0, unread_replies: 2 });
    // 客户端经增量同步拿到的会话行也带着"回复我"的计数，和 @ 分开。
    const dialog = (await getDifference(t.db, acc.accountId, from)).dialogs.find((d) => d.peerId === 990002);
    expect(dialog).toMatchObject({ unreadCount: 3, unreadMentions: 0, unreadMentionAll: 0, unreadReplies: 2 });

    await ingest.markRead(acc.accountId, (await chat(acc, 990002)).id, 13);
    expect(await chat(acc, 990002)).toMatchObject({ unread_count: 0, unread_replies: 0 });
  });

  it('imports pins, group message settings and friend do-not-disturb, but never overrides local choices', async () => {
    const { ingest, writers } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const prefs = new DialogPrefs(writers);
    for (const [scene, peer] of [
      ['group', 990011],
      ['group', 990012],
      ['group', 990013],
      ['friend', 30011],
    ] as const) {
      await ingest.ingestMessage(acc.qqAccountId, textMessage(scene, peer, 1, 20002));
    }
    const hub = {
      isConnected: () => true,
      call: async <T,>(): Promise<T> =>
        ({
          groups: [
            { groupCode: '990011', msgMask: 1, isTop: true, toppedAtMs: '1762276871000' },
            { groupCode: '990012', msgMask: 2, isTop: false, toppedAtMs: '0' },
            { groupCode: '990013', msgMask: 4, isTop: false, toppedAtMs: '0' },
            { groupCode: '999999', msgMask: 1, isTop: true, toppedAtMs: '0' }, // 服务端没有的群：不建
          ],
          recent: [
            { chatType: 1, peerUin: '30011', topFlag: 1, topFlagTime: '1791199388', isMsgDisturb: true, unreadCnt: '0', msgSeq: '1' },
            { chatType: 2, peerUin: '990013', topFlag: 0, topFlagTime: '0', isMsgDisturb: false, unreadCnt: '0', msgSeq: '1' },
          ],
        }) as T,
    };
    const sync = new QqSettingsSync(t.db, hub, prefs, ingest);
    const report = await sync.run(acc.qqAccountId);
    expect(report).toMatchObject({ chats: 4, changed: 4, markedRead: 2 });
    expect(await chat(acc, 990011)).toMatchObject({ pinned: true, notify_policy: 'all' });
    expect(new Date((await chat(acc, 990011)).pinned_at!).getTime()).toBe(1762276871000);
    expect(await chat(acc, 990012)).toMatchObject({ pinned: false, notify_policy: 'archived' });
    expect(await chat(acc, 990013)).toMatchObject({ notify_policy: 'muted', unread_count: 0 }); // 在别的设备上看过了
    expect(await chat(acc, 30011)).toMatchObject({ pinned: true, notify_policy: 'muted', unread_count: 0 });

    // 本地取消置顶、改成提醒：再同步也不改回去。
    await prefs.setPinned(acc.accountId, (await chat(acc, 990011)).id, false);
    await prefs.setNotifyPolicy(acc.accountId, (await chat(acc, 990012)).id, 'all');
    expect(await sync.run(acc.qqAccountId)).toMatchObject({ changed: 0 });
    expect(await chat(acc, 990011)).toMatchObject({ pinned: false });
    expect(await chat(acc, 990012)).toMatchObject({ notify_policy: 'all' });
  });
});

describe('stickers', () => {
  it('lists my saved stickers once and prepares images on demand, reusing content I already have', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const media = new MediaService(t.db, new LocalFsBackend(root));
    const a = await sharp({ create: { width: 32, height: 32, channels: 3, background: '#f00' } }).png().toBuffer();
    const b = await sharp({ create: { width: 32, height: 32, channels: 3, background: '#0f0' } }).png().toBuffer();
    const existing = await media.storeBlob(Readable.from([a]), { kind: 'image' });
    const md5b = (await import('node:crypto')).createHash('md5').update(b).digest('hex');
    let calls = 0;
    const hub = {
      isConnected: () => true,
      call: async <T,>(): Promise<T> => {
        calls += 1;
        return {
          emojis: [
            { md5: existing.md5, url: 'https://p.qpic.cn/a', isMarkFace: false, desc: '' },
            { md5: md5b, url: 'https://p.qpic.cn/b', isMarkFace: true, desc: '哈' },
          ],
        } as T;
      },
    };
    const downloads: string[] = [];
    const stickers = new StickerService(t.db, media, null, () => hub, undefined, async (url) => {
      downloads.push(url);
      return url.endsWith('/b') ? b : null;
    });
    const list = await stickers.list(acc.accountId, false);
    expect(list.map((s) => [s.md5, Boolean(s.sha256), s.market])).toEqual([
      [existing.md5, true, false], // 收到过同一张：直接用
      [md5b, false, true],
    ]);
    await stickers.list(acc.accountId, false);
    expect(calls).toBe(1); // 缓存

    const prepared = await stickers.prepare(acc.accountId, [md5b, existing.md5]);
    expect(prepared.map((s) => s.md5)).toEqual([md5b, existing.md5]);
    expect(downloads).toEqual(['https://p.qpic.cn/b']);
    expect((await stickers.ownedSha256(acc.accountId)).has(existing.sha256)).toBe(true);
  });
});
