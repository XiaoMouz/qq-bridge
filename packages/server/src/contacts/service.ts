// 联系人与资料同步（docs/design.md 4.8 ContactService）。不在后台逐个爬取资料（风控风险高），只在需要时取：
// - 好友列表、群列表：各一次请求就能拿全，建好索引。上游连上后和每天各刷新一次，也可手动触发；
// - 头像：打开会话时（SetActiveChat）检查，超过一天没检查过才下载一次；
// - 详细资料（签名、性别等级、群成员等）：打开资料页时请求（refresh = true，缓存超过 10 分钟才当场刷新）。
// 头像从 QQ 头像服务下载，按内容去重存成 blob；内容变了才更新 peers.avatar_sha256（经 pts 推给客户端）。
// 所有请求都走插件的 ob11 透传（NapCat 的 get_friend_list / get_stranger_info / get_group_info / get_group_member_list）。
import { Readable } from 'node:stream';
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, rows, type Db } from '../db/client.ts';
import type { IngestService } from '../ingest/service.ts';
import type { MediaProcessor } from '../media/processing.ts';
import type { MediaService } from '../media/service.ts';
import { PEER_COLUMNS, toPeer, type PeerRow } from '../sync/rows.ts';
import type { UpstreamHub } from '../upstream/hub.ts';

export interface ContactOptions {
  /** 打开资料页时，缓存超过这么久才当场刷新。 */
  onDemandMaxAgeMs?: number;
  /** 打开会话时，头像超过这么久没检查过才重新下载。 */
  avatarMaxAgeMs?: number;
  /** 头像下载（测试时替换）。返回 null 表示没拿到。 */
  fetchAvatar?: (url: string) => Promise<Buffer | null>;
  logger?: Logger;
  sleep?: (ms: number) => Promise<void>;
}

export interface UserProfile {
  peer: PeerRow;
  sex: string;
  age: number;
  level: number;
  refreshedAt: Date | null;
}

export interface GroupProfile {
  peer: PeerRow;
  maxMemberCount: number;
  ownerId: number;
  refreshedAt: Date | null;
}

export interface GroupMemberRow {
  userId: number;
  nickname: string;
  card: string;
  role: string;
  title: string;
  level: string;
  joinedAt: Date | null;
  lastSentAt: Date | null;
}

export interface FriendCategory {
  id: number;
  name: string;
  sort: number;
  userIds: number[];
  specialCare: boolean;
}

/** QQ 的"特别关心"分组：里面的人同时也在自己原本的分组里。 */
const SPECIAL_CARE = 9999;

export class ContactError extends Error {
  constructor(
    readonly code: 'not_found' | 'failed',
    message: string,
  ) {
    super(message);
  }
}

type Ob11 = Record<string, unknown>;

const str = (v: unknown): string | undefined => (typeof v === 'string' && v.trim() ? v : undefined);
const num = (v: unknown): number | undefined => {
  const n = typeof v === 'string' ? Number(v) : v;
  return typeof n === 'number' && Number.isFinite(n) && n > 0 ? n : undefined;
};
const unixDate = (v: unknown): Date | null => {
  const n = num(v);
  return n ? new Date(n * 1000) : null;
};

export class ContactService {
  private readonly o: Required<Omit<ContactOptions, 'logger'>> & Pick<ContactOptions, 'logger'>;
  private timer: NodeJS.Timeout | null = null;
  private running: Promise<void> | null = null;
  private readonly avatarInFlight = new Set<string>();

  constructor(
    private readonly db: Db,
    private readonly ingest: Pick<IngestService, 'upsertPeer'>,
    private readonly media: Pick<MediaService, 'storeBlob'>,
    private readonly processor: Pick<MediaProcessor, 'process'> | null,
    private readonly upstream: () => Pick<UpstreamHub, 'call' | 'isConnected'> | null,
    opts: ContactOptions = {},
  ) {
    this.o = {
      onDemandMaxAgeMs: 10 * 60_000,
      avatarMaxAgeMs: 24 * 3600_000,
      fetchAvatar: defaultFetchAvatar,
      sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
      ...opts,
    };
  }

  // ---------- 后台同步：只刷新好友 / 群列表 ----------

  /** 上游连上后（1 分钟后）和之后每天刷新一次好友列表与群列表，各一次请求。 */
  start(accounts: () => Promise<number[]>): void {
    const tick = () => {
      if (this.running) return;
      this.running = (async () => {
        for (const qq of await accounts()) {
          if (!this.upstream()?.isConnected(qq)) continue;
          const lists = await this.refreshLists(qq);
          this.o.logger?.info({ qqAccountId: qq, ...lists }, 'contact lists synced');
        }
      })()
        .catch((error: unknown) => this.o.logger?.warn({ err: error }, 'contact list sync failed'))
        .finally(() => {
          this.running = null;
        });
    };
    this.timer = setInterval(tick, 24 * 3600_000);
    this.timer.unref();
    setTimeout(tick, 60_000).unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /**
   * 打开会话：头像缺失或超过一天没检查过就下载一次（后台进行，不耽误打开会话）。
   * 同一个对象同时只下载一次。
   */
  chatOpened(chatId: number): void {
    void (async () => {
      const chat = await maybeOne<{ qq_account_id: number; scene: string; peer_id: number; checked: string | null }>(
        this.db,
        sql`select c.qq_account_id, c.scene, c.peer_id, p.extra->>'avatarCheckedAt' as checked
              from chats c left join peers p on p.qq_account_id = c.qq_account_id and p.peer_id = c.peer_id
                                            and p.kind = case c.scene when 'group' then 'group' else 'user' end
             where c.id = ${chatId}`,
      );
      if (!chat || (chat.scene !== 'friend' && chat.scene !== 'group')) return;
      if (chat.scene === 'group') void this.refreshMuteState(Number(chat.qq_account_id), Number(chat.peer_id));
      if (chat.checked && Date.now() - Number(chat.checked) < this.o.avatarMaxAgeMs) return;
      const kind = chat.scene === 'group' ? 'group' : 'user';
      const key = `${chat.qq_account_id}:${kind}:${chat.peer_id}`;
      if (this.avatarInFlight.has(key)) return;
      this.avatarInFlight.add(key);
      try {
        await this.refreshAvatar(Number(chat.qq_account_id), kind, Number(chat.peer_id));
      } finally {
        this.avatarInFlight.delete(key);
      }
    })().catch((error: unknown) => this.o.logger?.debug({ err: error, chatId }, 'avatar refresh failed'));
  }

  /** 一批人的头像：超过一天没检查过（或从没有过）的才下载，最多 4 个并发。返回 userId → sha256。 */
  async avatars(accountId: number, userIds: number[]): Promise<Map<number, string>> {
    return this.batchAvatars(await this.qqAccountOf(accountId), 'user', userIds);
  }

  /** 一批群的头像（联系人页的群列表），规则同上；只处理已知的群。 */
  async groupAvatars(accountId: number, groupIds: number[]): Promise<Map<number, string>> {
    return this.batchAvatars(await this.qqAccountOf(accountId), 'group', groupIds);
  }

  private async batchAvatars(qq: number, kind: 'user' | 'group', peerIds: number[]): Promise<Map<number, string>> {
    const ids = [...new Set(peerIds)].slice(0, 50);
    if (ids.length === 0) return new Map();
    const list = sql.join(ids.map((i) => sql`${i}`), sql`, `);
    const known = await rows<{ peer_id: number; avatar_sha256: string | null; checked: string | null }>(
      this.db,
      sql`select peer_id, avatar_sha256, extra->>'avatarCheckedAt' as checked from peers
           where qq_account_id = ${qq} and kind = ${kind} and peer_id in (${list})`,
    );
    const byId = new Map(known.map((k) => [Number(k.peer_id), k]));
    const stale = ids.filter((id) => {
      const k = byId.get(id);
      // 群只处理已知的（群号是我们自己列出来的）；人可以是没资料的群友。
      if (kind === 'group' && !k) return false;
      return !k?.checked || Date.now() - Number(k.checked) > this.o.avatarMaxAgeMs;
    });
    for (let i = 0; i < stale.length; i += 4) {
      await Promise.all(
        stale.slice(i, i + 4).map(async (id) => {
          const key = `${qq}:${kind}:${id}`;
          if (this.avatarInFlight.has(key)) return;
          this.avatarInFlight.add(key);
          try {
            if (!byId.has(id)) await this.ingest.upsertPeer(qq, { kind, peerId: id }); // 没资料的群友：先建一行
            await this.refreshAvatar(qq, kind, id);
          } catch (error) {
            this.o.logger?.warn({ err: error, kind, id }, 'avatar refresh failed');
          } finally {
            this.avatarInFlight.delete(key);
          }
        }),
      );
    }
    const after = await rows<{ peer_id: number; avatar_sha256: string | null }>(
      this.db,
      sql`select peer_id, avatar_sha256 from peers where qq_account_id = ${qq} and kind = ${kind} and peer_id in (${list})`,
    );
    return new Map(after.filter((a) => a.avatar_sha256).map((a) => [Number(a.peer_id), a.avatar_sha256!]));
  }

  /** 只下载头像（不经 QQ 协议，直接从头像服务取），变了才更新。 */
  async refreshAvatar(qqAccountId: number, kind: 'user' | 'group', peerId: number): Promise<void> {
    const sha256 = await this.avatar(avatarUrl(kind, peerId));
    if (sha256) await this.ingest.upsertPeer(qqAccountId, { kind, peerId, avatarSha256: sha256 });
    await this.markAvatarChecked(qqAccountId, kind, peerId);
  }

  /** 好友列表（带分组）与群列表（各一次请求）。返回数量。 */
  async refreshLists(qqAccountId: number): Promise<{ friends: number; groups: number }> {
    // 优先用带分组的列表；NapCat 旧版本没有时退回普通好友列表（没有分组信息）。
    // 不加 no_cache：加了 NapCat 会逐个向 QQ 拉每个好友的详细资料（几百次请求，还大量超时），正是要避免的爬取。
    const withCategory = await this.ob11<Ob11[]>(qqAccountId, 'get_friends_with_category', {}).catch(() => null);
    const categories: { id: number; name: string; sort: number; expected: number }[] = [];
    const membership = new Map<number, { categoryId: number; specialCare: boolean }>();
    let friends: Ob11[];
    if (Array.isArray(withCategory) && withCategory.length > 0) {
      const seen = new Map<number, Ob11>();
      for (const c of withCategory) {
        const id = Number(c.categoryId);
        if (!Number.isInteger(id)) continue;
        categories.push({ id, name: String(c.categoryName ?? ''), sort: Number(c.categorySortId) || 0, expected: Number(c.categoryMbCount) || 0 });
        for (const b of Array.isArray(c.buddyList) ? (c.buddyList as Ob11[]) : []) {
          const uid = num(b.user_id);
          if (!uid) continue;
          const m = membership.get(uid) ?? { categoryId: num(b.category_id) ?? 0, specialCare: false };
          if (id === SPECIAL_CARE) m.specialCare = true;
          else m.categoryId = id;
          membership.set(uid, m);
          seen.set(uid, b);
        }
      }
      friends = [...seen.values()];
    } else {
      friends = (await this.ob11<Ob11[]>(qqAccountId, 'get_friend_list', {})) ?? [];
    }

    const friendIds = new Set<number>();
    for (const f of friends) {
      const id = num(f.user_id);
      if (!id) continue;
      friendIds.add(id);
      await this.ingest.upsertPeer(qqAccountId, {
        kind: 'user',
        peerId: id,
        isFriend: true,
        ...(str(f.nickname) ? { name: str(f.nickname)! } : {}),
        ...(typeof f.remark === 'string' ? { remark: f.remark } : {}),
        ...(str(f.long_nick) ? { sign: str(f.long_nick)! } : {}),
      });
    }

    // QQ 刚登录时好友列表是一点点加载的（例如 767 个好友只返回了 3 个）：这时既不能把没列出来的人当成"不再是好友"，
    // 也不能拿残缺的分组覆盖。判断标准：比分组里报的人数、或者上次的好友数少一半以上。
    const before = await maybeOne<{ n: number }>(
      this.db,
      sql`select count(*)::int as n from peers where qq_account_id = ${qqAccountId} and kind = 'user' and is_friend`,
    );
    const expected = categories.filter((c) => c.id !== SPECIAL_CARE).reduce((sum, c) => sum + c.expected, 0);
    const complete = friendIds.size > 0 && friendIds.size >= expected * 0.9 && friendIds.size >= (before?.n ?? 0) * 0.5;
    if (!complete) {
      this.o.logger?.warn({ qqAccountId, listed: friendIds.size, expected, before: before?.n }, 'friend list looks incomplete; keeping existing friends and categories');
    } else {
      // 不再是好友的（被删、删了对方）。
      const formerly = await rows<{ peer_id: number }>(
        this.db,
        sql`select peer_id from peers where qq_account_id = ${qqAccountId} and kind = 'user' and is_friend`,
      );
      for (const p of formerly) {
        if (!friendIds.has(Number(p.peer_id))) await this.ingest.upsertPeer(qqAccountId, { kind: 'user', peerId: Number(p.peer_id), isFriend: false });
      }
      if (categories.length > 0) await this.saveCategories(qqAccountId, categories, membership);
    }

    const groups = (await this.ob11<Ob11[]>(qqAccountId, 'get_group_list', {})) ?? [];
    for (const g of groups) {
      const id = num(g.group_id);
      if (!id) continue;
      await this.ingest.upsertPeer(qqAccountId, {
        kind: 'group',
        peerId: id,
        ...(str(g.group_name) ? { name: str(g.group_name)! } : {}),
        ...(num(g.member_count) ? { memberCount: num(g.member_count)! } : {}),
      });
    }
    return { friends: friendIds.size, groups: groups.length };
  }

  // ---------- 资料 ----------

  async userProfile(accountId: number, userId: number, refresh: boolean): Promise<{ profile: UserProfile; stale: boolean }> {
    const qq = await this.qqAccountOf(accountId);
    let stale = false;
    if (refresh && (await this.due(qq, 'user', userId))) {
      try {
        await this.refreshUser(qq, userId);
      } catch (error) {
        stale = true;
        this.o.logger?.debug({ err: error, userId }, 'on-demand profile refresh failed');
      }
    }
    const row = await this.peerRow(qq, 'user', userId);
    if (!row) throw new ContactError('not_found', `user ${userId} is unknown`);
    const extra = row.extra;
    return {
      profile: {
        peer: row.peer,
        sex: typeof extra.sex === 'string' ? extra.sex : 'unknown',
        age: Number(extra.age ?? 0) || 0,
        level: Number(extra.level ?? 0) || 0,
        refreshedAt: row.refreshedAt,
      },
      stale,
    };
  }

  async groupProfile(accountId: number, groupId: number, refresh: boolean): Promise<{ profile: GroupProfile; stale: boolean }> {
    const qq = await this.qqAccountOf(accountId);
    let stale = false;
    if (refresh && (await this.due(qq, 'group', groupId))) {
      try {
        await this.refreshGroup(qq, groupId, true);
      } catch (error) {
        stale = true;
        this.o.logger?.debug({ err: error, groupId }, 'on-demand group refresh failed');
      }
    }
    const row = await this.peerRow(qq, 'group', groupId);
    if (!row) throw new ContactError('not_found', `group ${groupId} is unknown`);
    return {
      profile: {
        peer: row.peer,
        maxMemberCount: Number(row.extra.maxMemberCount ?? 0) || 0,
        ownerId: Number(row.extra.ownerId ?? 0) || 0,
        refreshedAt: row.refreshedAt,
      },
      stale,
    };
  }

  async groupMembers(
    accountId: number,
    groupId: number,
    opts: { refresh: boolean; offset: number; limit: number },
  ): Promise<{ members: GroupMemberRow[]; total: number; stale: boolean }> {
    const qq = await this.qqAccountOf(accountId);
    let stale = false;
    const known = await maybeOne<{ n: number }>(
      this.db,
      sql`select count(*)::int as n from group_members where qq_account_id = ${qq} and group_id = ${groupId}`,
    );
    if ((opts.refresh && (await this.due(qq, 'group', groupId))) || !known?.n) {
      try {
        await this.refreshGroup(qq, groupId, true);
      } catch (error) {
        stale = true;
        this.o.logger?.debug({ err: error, groupId }, 'member refresh failed');
      }
    }
    const list = await rows<{
      user_id: number;
      nickname: string | null;
      card: string | null;
      role: string;
      title: string | null;
      level: string | null;
      joined_at: Date | string | null;
      last_sent_at: Date | string | null;
    }>(
      this.db,
      sql`select user_id, nickname, card, role, title, level, joined_at, last_sent_at from group_members
           where qq_account_id = ${qq} and group_id = ${groupId}
           order by case role when 'owner' then 0 when 'admin' then 1 else 2 end, last_sent_at desc nulls last, user_id
           offset ${opts.offset} limit ${opts.limit}`,
    );
    const total = await maybeOne<{ n: number }>(
      this.db,
      sql`select count(*)::int as n from group_members where qq_account_id = ${qq} and group_id = ${groupId}`,
    );
    return {
      members: list.map((m) => ({
        userId: Number(m.user_id),
        nickname: m.nickname ?? '',
        card: m.card ?? '',
        role: m.role,
        title: m.title ?? '',
        level: m.level ?? '',
        joinedAt: m.joined_at ? new Date(m.joined_at) : null,
        lastSentAt: m.last_sent_at ? new Date(m.last_sent_at) : null,
      })),
      total: total?.n ?? 0,
      stale,
    };
  }

  async listPeers(accountId: number, kind: 'user' | 'group'): Promise<PeerRow[]> {
    const qq = await this.qqAccountOf(accountId);
    const list = await rows(
      this.db,
      sql`select ${PEER_COLUMNS} from peers where qq_account_id = ${qq} and kind = ${kind}
             ${kind === 'user' ? sql`and is_friend` : sql``}
           order by coalesce(nullif(remark, ''), name)`,
    );
    return list.map(toPeer);
  }

  /** 好友分组（按 QQ 里的顺序；特别关心在最前）。 */
  async listCategories(accountId: number): Promise<FriendCategory[]> {
    const qq = await this.qqAccountOf(accountId);
    const cats = await rows<{ category_id: number; name: string; sort: number }>(
      this.db,
      sql`select category_id, name, sort from friend_categories where qq_account_id = ${qq} order by (category_id = ${SPECIAL_CARE}) desc, sort, category_id`,
    );
    if (cats.length === 0) return [];
    const members = await rows<{ peer_id: number; category_id: number | null; special: boolean | null }>(
      this.db,
      sql`select peer_id, (extra->>'categoryId')::int as category_id, (extra->>'specialCare')::boolean as special
            from peers where qq_account_id = ${qq} and kind = 'user' and is_friend
           order by coalesce(nullif(remark, ''), name)`,
    );
    return cats.map((c) => ({
      id: c.category_id,
      name: c.name,
      sort: c.sort,
      specialCare: c.category_id === SPECIAL_CARE,
      userIds: members
        .filter((m) => (c.category_id === SPECIAL_CARE ? m.special === true : m.category_id === c.category_id))
        .map((m) => Number(m.peer_id)),
    }));
  }

  /** 删除好友：在 QQ 里删掉，再把本地标成"不是好友"（会话和聊天记录都保留）。 */
  async deleteFriend(accountId: number, userId: number): Promise<void> {
    const qq = await this.qqAccountOf(accountId);
    const res = await this.ob11<{ valid?: boolean; message?: string }>(qq, 'delete_friend', { user_id: String(userId) });
    if (res && res.valid === false) throw new ContactError('failed', res.message || 'QQ refused to delete this friend');
    await this.ingest.upsertPeer(qq, { kind: 'user', peerId: userId, isFriend: false });
  }

  private async saveCategories(
    qqAccountId: number,
    categories: { id: number; name: string; sort: number }[],
    membership: Map<number, { categoryId: number; specialCare: boolean }>,
  ): Promise<void> {
    const ids = [...membership.keys()];
    await this.db.transaction(async (tx) => {
      await tx.execute(sql`delete from friend_categories where qq_account_id = ${qqAccountId}`);
      for (const c of categories) {
        await tx.execute(
          sql`insert into friend_categories (qq_account_id, category_id, name, sort) values (${qqAccountId}, ${c.id}, ${c.name}, ${c.sort})`,
        );
      }
      if (ids.length === 0) return;
      await tx.execute(
        sql`update peers p set extra = p.extra || jsonb_build_object('categoryId', v.category_id, 'specialCare', v.special)
              from jsonb_to_recordset(${JSON.stringify(ids.map((i) => ({ peer_id: i, category_id: membership.get(i)!.categoryId, special: membership.get(i)!.specialCare })))}::jsonb)
                   as v(peer_id bigint, category_id int, special boolean)
             where p.qq_account_id = ${qqAccountId} and p.kind = 'user' and p.peer_id = v.peer_id`,
      );
    });
  }

  /** 刷新一个人的资料和头像。 */
  async refreshUser(qqAccountId: number, userId: number): Promise<void> {
    const info = await this.ob11<Ob11>(qqAccountId, 'get_stranger_info', { user_id: String(userId), no_cache: true });
    if (!info) throw new Error(`no profile for ${userId}`);
    const avatar = await this.avatar(avatarUrl('user', userId));
    await this.ingest.upsertPeer(qqAccountId, {
      kind: 'user',
      peerId: userId,
      ...(str(info.uid) ? { uid: str(info.uid)! } : {}),
      ...(str(info.nickname) ? { name: str(info.nickname)! } : {}),
      ...(typeof info.remark === 'string' && info.remark ? { remark: info.remark } : {}),
      sign: typeof info.long_nick === 'string' ? info.long_nick : '',
      ...(avatar ? { avatarSha256: avatar } : {}),
    });
    const extra = {
      sex: str(info.sex) ?? 'unknown',
      age: num(info.age) ?? 0,
      level: num(info.qqLevel ?? info.level) ?? 0,
    };
    await this.db.execute(
      sql`update peers set extra = extra || ${JSON.stringify({ ...extra, avatarCheckedAt: Date.now() })}::jsonb, profile_refreshed_at = now()
           where qq_account_id = ${qqAccountId} and kind = 'user' and peer_id = ${userId}`,
    );
  }

  /** 刷新群资料、头像，withMembers 时连同成员列表（大群一次请求可能要几秒）。 */
  /**
   * 打开群聊时：向 QQ 要一次全员禁言和自己的禁言、身份（两次很轻的调用；同一个群 30 秒内只要一次）。
   * 禁言事件实时更新这些状态，这里是兜底（App 没在线时的变化、禁言到期）。
   */
  async refreshMuteState(qqAccountId: number, groupId: number): Promise<void> {
    const key = `${qqAccountId}:${groupId}`;
    const last = this.muteCheckedAt.get(key) ?? 0;
    if (Date.now() - last < 30_000) return;
    this.muteCheckedAt.set(key, Date.now());
    try {
      const info = await this.ob11<Ob11>(qqAccountId, 'get_group_info', { group_id: String(groupId), no_cache: true });
      if (!info) return;
      const self = await this.selfMember(qqAccountId, groupId);
      await this.ingest.upsertPeer(qqAccountId, { kind: 'group', peerId: groupId, ...muteState(info, self) });
    } catch (error) {
      this.o.logger?.debug({ err: error, groupId }, 'mute state refresh failed');
    }
  }

  private readonly muteCheckedAt = new Map<string, number>();
  private readonly memberRefreshAt = new Map<string, number>();

  /**
   * 群员资料可能变了（收到群名片变化）：去 QQ 拉这个人的群名片、身份、头衔、QQ 昵称写回（后台进行）。
   * NapCat 常常连着报两次（改成空、再改回来），同一个人 30 秒内只拉一次，并且晚 3 秒再拉，等第二次也到了。
   */
  refreshMember(qqAccountId: number, groupId: number, userId: number): void {
    const key = `${qqAccountId}:${groupId}:${userId}`;
    if (Date.now() - (this.memberRefreshAt.get(key) ?? 0) < 30_000) return;
    this.memberRefreshAt.set(key, Date.now());
    if (this.memberRefreshAt.size > 5000) this.memberRefreshAt.delete(this.memberRefreshAt.keys().next().value!);
    setTimeout(() => {
      void (async () => {
        const m = await this.ob11<Ob11>(qqAccountId, 'get_group_member_info', { group_id: String(groupId), user_id: String(userId), no_cache: true });
        if (!m || !num(m.user_id)) return;
        await this.db.execute(
          sql`insert into group_members (qq_account_id, group_id, user_id, nickname, card, role, title, level, joined_at, last_sent_at)
              values (${qqAccountId}, ${groupId}, ${userId}, ${str(m.nickname) ?? null}, ${str(m.card) ?? null},
                      ${m.role === 'owner' || m.role === 'admin' ? m.role : 'member'}, ${str(m.title) ?? null},
                      ${m.level === undefined || m.level === null ? null : String(m.level)}, ${unixDate(m.join_time)}, ${unixDate(m.last_sent_time)})
              on conflict (qq_account_id, group_id, user_id) do update
                 set nickname = excluded.nickname, card = excluded.card, role = excluded.role, title = excluded.title,
                     level = excluded.level, joined_at = excluded.joined_at, last_sent_at = excluded.last_sent_at, updated_at = now()`,
        );
        if (str(m.nickname)) await this.ingest.upsertPeer(qqAccountId, { kind: 'user', peerId: userId, name: str(m.nickname)! });
        // 自己：顺带更新禁言、身份。
        const self = await maybeOne<{ uin: number }>(this.db, sql`select uin from qq_accounts where id = ${qqAccountId}`);
        if (self && Number(self.uin) === userId) {
          const until = Number(m.shut_up_timestamp ?? 0) || 0;
          await this.ingest.upsertPeer(qqAccountId, {
            kind: 'group',
            peerId: groupId,
            selfMutedUntil: until > Date.now() / 1000 ? until : 0,
            ...(m.role === 'owner' || m.role === 'admin' || m.role === 'member' ? { selfRole: m.role } : {}),
          });
        }
      })().catch((error: unknown) => this.o.logger?.debug({ err: error, groupId, userId }, 'member refresh failed'));
    }, 3000);
  }

  /** 自己在群里的成员资料（身份、禁言到期时间）。 */
  private async selfMember(qqAccountId: number, groupId: number): Promise<Ob11 | null> {
    const row = await maybeOne<{ uin: number }>(this.db, sql`select uin from qq_accounts where id = ${qqAccountId}`);
    if (!row) return null;
    return (await this.ob11<Ob11>(qqAccountId, 'get_group_member_info', { group_id: String(groupId), user_id: String(row.uin), no_cache: true })) ?? null;
  }

  async refreshGroup(qqAccountId: number, groupId: number, withMembers: boolean): Promise<void> {
    const info = await this.ob11<Ob11>(qqAccountId, 'get_group_info', { group_id: String(groupId), no_cache: true });
    if (!info) throw new Error(`no info for group ${groupId}`);
    const avatar = await this.avatar(avatarUrl('group', groupId));
    const self = await this.selfMember(qqAccountId, groupId).catch(() => null);
    await this.ingest.upsertPeer(qqAccountId, {
      kind: 'group',
      peerId: groupId,
      ...muteState(info, self),
      ...(str(info.group_name) ? { name: str(info.group_name)! } : {}),
      ...(num(info.member_count) ? { memberCount: num(info.member_count)! } : {}),
      ...(typeof info.group_memo === 'string' ? { sign: info.group_memo } : {}),
      ...(avatar ? { avatarSha256: avatar } : {}),
    });
    let ownerId = num(info.owner_id) ?? 0;
    if (withMembers) {
      const members = (await this.ob11<Ob11[]>(qqAccountId, 'get_group_member_list', { group_id: String(groupId), no_cache: true })) ?? [];
      if (members.length > 0) {
        await this.db.transaction(async (tx) => {
          await tx.execute(sql`delete from group_members where qq_account_id = ${qqAccountId} and group_id = ${groupId}`);
          for (let i = 0; i < members.length; i += 500) {
            const chunk = members.slice(i, i + 500).filter((m) => num(m.user_id));
            if (chunk.length === 0) continue;
            await tx.execute(
              sql`insert into group_members (qq_account_id, group_id, user_id, nickname, card, role, title, level, joined_at, last_sent_at)
                  values ${sql.join(
                    chunk.map(
                      (m) =>
                        sql`(${qqAccountId}, ${groupId}, ${num(m.user_id)!}, ${str(m.nickname) ?? null}, ${str(m.card) ?? null},
                             ${m.role === 'owner' || m.role === 'admin' ? m.role : 'member'}, ${str(m.title) ?? null},
                             ${m.level === undefined || m.level === null ? null : String(m.level)},
                             ${unixDate(m.join_time)}, ${unixDate(m.last_sent_time)})`,
                    ),
                    sql`, `,
                  )}
                  on conflict do nothing`,
            );
          }
        });
        ownerId = num(members.find((m) => m.role === 'owner')?.user_id) ?? ownerId;
      }
    }
    const extra = { maxMemberCount: num(info.max_member_count) ?? 0, ...(ownerId ? { ownerId } : {}), avatarCheckedAt: Date.now() };
    await this.db.execute(
      sql`update peers set extra = extra || ${JSON.stringify(extra)}::jsonb, profile_refreshed_at = now()
           where qq_account_id = ${qqAccountId} and kind = 'group' and peer_id = ${groupId}`,
    );
  }

  // ---------- 内部 ----------

  /** 下载头像并按内容去重存储；顺带生成缩略图（会话列表用）。失败返回 null，不影响资料刷新。 */
  private async avatar(url: string): Promise<string | null> {
    try {
      const data = await this.o.fetchAvatar(url);
      if (!data || data.length < 64) return null;
      const blob = await this.media.storeBlob(Readable.from([data]), { kind: 'image', maxBytes: 5 * 1024 * 1024 });
      await this.processor?.process(blob.sha256, 'image');
      return blob.sha256;
    } catch (error) {
      this.o.logger?.warn({ err: error, url }, 'avatar fetch failed');
      return null;
    }
  }

  private async markAvatarChecked(qqAccountId: number, kind: 'user' | 'group', peerId: number): Promise<void> {
    await this.db.execute(
      sql`update peers set extra = extra || ${JSON.stringify({ avatarCheckedAt: Date.now() })}::jsonb
           where qq_account_id = ${qqAccountId} and kind = ${kind} and peer_id = ${peerId}`,
    );
  }

  private async due(qqAccountId: number, kind: 'user' | 'group', peerId: number): Promise<boolean> {
    const row = await maybeOne<{ at: Date | string | null }>(
      this.db,
      sql`select profile_refreshed_at as at from peers where qq_account_id = ${qqAccountId} and kind = ${kind} and peer_id = ${peerId}`,
    );
    return !row?.at || Date.now() - new Date(row.at).getTime() > this.o.onDemandMaxAgeMs;
  }

  private async peerRow(
    qqAccountId: number,
    kind: 'user' | 'group',
    peerId: number,
  ): Promise<{ peer: PeerRow; extra: Record<string, unknown>; refreshedAt: Date | null } | null> {
    const row = await maybeOne<Record<string, unknown> & { extra: Record<string, unknown>; profile_refreshed_at: Date | string | null }>(
      this.db,
      sql`select ${PEER_COLUMNS}, extra, profile_refreshed_at from peers where qq_account_id = ${qqAccountId} and kind = ${kind} and peer_id = ${peerId}`,
    );
    if (!row) return null;
    return { peer: toPeer(row), extra: row.extra ?? {}, refreshedAt: row.profile_refreshed_at ? new Date(row.profile_refreshed_at) : null };
  }

  private async qqAccountOf(accountId: number): Promise<number> {
    const row = await maybeOne<{ id: number }>(this.db, sql`select id from qq_accounts where account_id = ${accountId} order by id limit 1`);
    if (!row) throw new ContactError('not_found', 'no QQ account is linked');
    return row.id;
  }

  private async ob11<T>(qqAccountId: number, name: string, params: Record<string, unknown>): Promise<T | null> {
    const hub = this.upstream();
    if (!hub?.isConnected(qqAccountId)) throw new Error('QQ is offline');
    return (await hub.call<T>(qqAccountId, 'ob11', { name, params }, 30_000)) ?? null;
  }
}

function avatarUrl(kind: 'user' | 'group', id: number): string {
  return kind === 'user' ? `https://q1.qlogo.cn/g?b=qq&nk=${id}&s=640` : `https://p.qlogo.cn/gh/${id}/${id}/640/`;
}

async function defaultFetchAvatar(url: string): Promise<Buffer | null> {
  const res = await fetch(url, { signal: AbortSignal.timeout(10_000), redirect: 'follow' });
  if (!res.ok) return null;
  return Buffer.from(await res.arrayBuffer());
}

/** QQ 返回的群资料 + 自己的成员资料 → 禁言状态（group_all_shut 非 0 = 全员禁言；shut_up_timestamp 是禁言到期时间）。 */
function muteState(info: Ob11, self: Ob11 | null): { muteAll: boolean; selfMutedUntil?: number; selfRole?: string } {
  const out: { muteAll: boolean; selfMutedUntil?: number; selfRole?: string } = { muteAll: Number(info.group_all_shut ?? 0) !== 0 };
  if (self) {
    const until = Number(self.shut_up_timestamp ?? 0) || 0;
    out.selfMutedUntil = until > Date.now() / 1000 ? until : 0;
    if (self.role === 'owner' || self.role === 'admin' || self.role === 'member') out.selfRole = self.role;
  }
  return out;
}

