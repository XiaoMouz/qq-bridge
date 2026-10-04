// 联系人与资料同步：好友 / 群列表、资料与头像（按内容去重，变了才推送）、群成员、按需刷新的节流、后台轮换。
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { sql } from 'drizzle-orm';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { one } from '../src/db/client.ts';
import { ContactService } from '../src/contacts/service.ts';
import { MediaService } from '../src/media/service.ts';
import { LocalFsBackend } from '../src/media/store.ts';
import type { Update } from '../src/sync/rows.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage } from './helpers/fixtures.ts';

let t: TestDb;
let root: string;
let media: MediaService;
beforeAll(async () => {
  t = await startTestDb();
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-contacts-'));
  media = new MediaService(t.db, new LocalFsBackend(root));
});
afterAll(async () => {
  await t?.stop();
  await fs.rm(root, { recursive: true, force: true });
});

const png = (color: string) => sharp({ create: { width: 64, height: 64, channels: 3, background: color } }).png().toBuffer();

class FakeQq {
  readonly calls: string[] = [];
  friends: Record<string, unknown>[] = [];
  groups: Record<string, unknown>[] = [];
  strangers = new Map<number, Record<string, unknown>>();
  members: Record<string, unknown>[] = [];
  isConnected() {
    return true;
  }
  async call<T>(_qq: number, _action: string, p: { name: string; params: Record<string, unknown> }): Promise<T> {
    this.calls.push(p.name);
    switch (p.name) {
      case 'get_friend_list':
        return this.friends as T;
      case 'get_group_list':
        return this.groups as T;
      case 'get_stranger_info':
        return (this.strangers.get(Number(p.params.user_id)) ?? null) as T;
      case 'get_group_info':
        return { group_id: p.params.group_id, group_name: '新群名', member_count: 3, max_member_count: 200, group_memo: '群简介' } as T;
      case 'get_group_member_list':
        return this.members as T;
    }
    throw new Error(p.name);
  }
}

describe('ContactService', () => {
  it('syncs friends and groups, marks removed friends, and keeps profiles and avatars current', async () => {
    const { ingest, bus } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq();
    let avatar = await png('#f00');
    const contacts = new ContactService(t.db, ingest, media, null, () => qq, { fetchAvatar: async () => avatar });
    const peerUpdates: Update[] = [];
    bus.subscribe(acc.accountId, (u) => {
      if (u.type === 'peer') peerUpdates.push(u);
    });

    qq.friends = [
      { user_id: 30050, nickname: '甲', remark: '老甲' },
      { user_id: 30051, nickname: '乙', remark: '' },
    ];
    qq.groups = [{ group_id: 950001, group_name: '群一', member_count: 3 }];
    expect(await contacts.refreshLists(acc.qqAccountId)).toEqual({ friends: 2, groups: 1 });
    expect((await contacts.listPeers(acc.accountId, 'user')).map((p) => [p.peerId, p.name, p.remark])).toEqual([
      [30051, '乙', ''],
      [30050, '甲', '老甲'],
    ]);

    qq.friends = [{ user_id: 30050, nickname: '甲', remark: '老甲' }]; // 乙不再是好友
    await contacts.refreshLists(acc.qqAccountId);
    expect((await contacts.listPeers(acc.accountId, 'user')).map((p) => p.peerId)).toEqual([30050]);

    qq.strangers.set(30050, { user_id: 30050, uid: 'u_a', nickname: '甲甲', long_nick: '今天也很好', sex: 'female', age: 20, qqLevel: 30 });
    const first = await contacts.userProfile(acc.accountId, 30050, true);
    expect(first.profile).toMatchObject({ sex: 'female', age: 20, level: 30, peer: { name: '甲甲', sign: '今天也很好' } });
    expect(first.profile.peer.avatarSha256).toMatch(/^[0-9a-f]{64}$/);

    // 10 分钟内再打开：不重复请求。
    const before = qq.calls.length;
    await contacts.userProfile(acc.accountId, 30050, true);
    expect(qq.calls.length).toBe(before);

    // 过期后再刷新：头像没变就不推送，变了才推送。
    await t.db.execute(sql`update peers set profile_refreshed_at = now() - interval '1 hour' where peer_id = 30050`);
    peerUpdates.length = 0;
    await contacts.userProfile(acc.accountId, 30050, true);
    expect(peerUpdates).toHaveLength(0);
    await t.db.execute(sql`update peers set profile_refreshed_at = now() - interval '1 hour' where peer_id = 30050`);
    avatar = await png('#00f');
    const changed = await contacts.userProfile(acc.accountId, 30050, true);
    expect(changed.profile.peer.avatarSha256).not.toBe(first.profile.peer.avatarSha256);
    expect(peerUpdates).toHaveLength(1);
  });

  it('loads group members on first open and orders owner and admins first', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq();
    const contacts = new ContactService(t.db, ingest, media, null, () => qq, { fetchAvatar: async () => null });
    await ingest.upsertPeer(acc.qqAccountId, { kind: 'group', peerId: 950002, name: '旧群名' });
    qq.members = [
      { user_id: 1, nickname: 'a', card: '', role: 'member', last_sent_time: 1_700_000_000 },
      { user_id: 2, nickname: 'b', card: '管理', role: 'admin', title: '头衔' },
      { user_id: 3, nickname: 'c', role: 'owner', join_time: 1_600_000_000 },
    ];
    const res = await contacts.groupMembers(acc.accountId, 950002, { refresh: false, offset: 0, limit: 10 });
    expect(res.members.map((m) => [m.userId, m.role])).toEqual([
      [3, 'owner'],
      [2, 'admin'],
      [1, 'member'],
    ]);
    expect(res.total).toBe(3);
    const group = await contacts.groupProfile(acc.accountId, 950002, false);
    expect(group.profile).toMatchObject({ ownerId: 3, maxMemberCount: 200, peer: { name: '新群名', sign: '群简介', memberCount: 3 } });
  });

  it('loads a chat avatar when the chat is opened, at most once a day, without asking QQ for anything', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq();
    let fetches = 0;
    const image = await png('#0f0');
    const contacts = new ContactService(t.db, ingest, media, null, () => qq, {
      fetchAvatar: async () => {
        fetches += 1;
        return image;
      },
    });
    await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 30070, 1, 30070));
    await ingest.upsertPeer(acc.qqAccountId, { kind: 'user', peerId: 30070, name: '丙' });
    const chatId = (await one<{ id: number }>(t.db, sql`select id from chats where qq_account_id = ${acc.qqAccountId} and peer_id = 30070`)).id;

    contacts.chatOpened(chatId);
    await vi.waitFor(async () => {
      const p = await one<{ avatar_sha256: string | null }>(t.db, sql`select avatar_sha256 from peers where qq_account_id = ${acc.qqAccountId} and peer_id = 30070`);
      expect(p.avatar_sha256).toMatch(/^[0-9a-f]{64}$/);
    });
    contacts.chatOpened(chatId);
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(fetches).toBe(1);
    expect(qq.calls).toEqual([]); // 不经 QQ 协议
  });
});
