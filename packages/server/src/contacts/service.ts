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

export class ContactError extends Error {
  constructor(
    readonly code: 'not_found',
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

  /** 只下载头像（不经 QQ 协议，直接从头像服务取），变了才更新。 */
  async refreshAvatar(qqAccountId: number, kind: 'user' | 'group', peerId: number): Promise<void> {
    const sha256 = await this.avatar(avatarUrl(kind, peerId));
    if (sha256) await this.ingest.upsertPeer(qqAccountId, { kind, peerId, avatarSha256: sha256 });
    await this.markAvatarChecked(qqAccountId, kind, peerId);
  }

  /** 好友列表与群列表（各一次请求）。返回数量。 */
  async refreshLists(qqAccountId: number): Promise<{ friends: number; groups: number }> {
    const friends = (await this.ob11<Ob11[]>(qqAccountId, 'get_friend_list', { no_cache: true })) ?? [];
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
    // 不再是好友的（被删、删了对方）。
    if (friends.length > 0) {
      const formerly = await rows<{ peer_id: number }>(
        this.db,
        sql`select peer_id from peers where qq_account_id = ${qqAccountId} and kind = 'user' and is_friend`,
      );
      for (const p of formerly) {
        if (!friendIds.has(Number(p.peer_id))) await this.ingest.upsertPeer(qqAccountId, { kind: 'user', peerId: Number(p.peer_id), isFriend: false });
      }
    }
    const groups = (await this.ob11<Ob11[]>(qqAccountId, 'get_group_list', { no_cache: true })) ?? [];
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
  async refreshGroup(qqAccountId: number, groupId: number, withMembers: boolean): Promise<void> {
    const info = await this.ob11<Ob11>(qqAccountId, 'get_group_info', { group_id: String(groupId), no_cache: true });
    if (!info) throw new Error(`no info for group ${groupId}`);
    const avatar = await this.avatar(avatarUrl('group', groupId));
    await this.ingest.upsertPeer(qqAccountId, {
      kind: 'group',
      peerId: groupId,
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
      this.o.logger?.debug({ err: error, url }, 'avatar fetch failed');
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
