// 找人：好友、库里有资料的人、所有群的群成员（2026-11-13 用户要求搜索和「只看 / 排除」能选到群里的人，
// 并且能用拼音、首字母搜中文名字）。
// 群成员 5.6 万行、peers 1.9 万行（2026-11-13），名字转拼音全部算一遍约 0.3 秒，所以在内存里建索引，
// 超过 INDEX_TTL_MS 后下次搜索时在后台重建，重建期间照旧用旧索引（新入群的人最多晚几分钟搜得到）。
import { sql } from 'drizzle-orm';
import { pinyin } from 'pinyin-pro';
import { rows, type Db } from '../db/client.ts';

const INDEX_TTL_MS = 5 * 60_000;

export interface PersonHit {
  userId: number;
  /** 显示名：备注 > 昵称 > 群名片 > 号码。 */
  name: string;
  /** 补充说明：好友 / 群名片和所在的群。 */
  detail: string;
  isFriend: boolean;
  avatarSha256: string;
  /** 匹配到的群（按群名片匹配时）或所在的第一个群；不在群里为 0。 */
  groupId: number;
}

interface Membership {
  groupId: number;
  groupName: string;
  card: string;
  nickname: string;
}

interface Entry {
  userId: number;
  remark: string;
  name: string;
  isFriend: boolean;
  avatar: string;
  groups: Membership[];
  /** 每个名字的检索键：原文（小写）、全拼、首字母。 */
  keys: { text: string; source: string; full: string; initials: string }[];
}

interface Index {
  builtAt: number;
  entries: Entry[];
}

/** 名字的拼音检索键。非中文部分原样保留（小写），每段取首字母。 */
export function pinyinKeys(text: string): { full: string; initials: string } {
  const parts = pinyin(text, { toneType: 'none', type: 'array', nonZh: 'consecutive' })
    .map((p) => p.toLowerCase().replace(/\s+/g, ''))
    .filter(Boolean);
  return { full: parts.join(''), initials: parts.map((p) => p[0]).join('') };
}

/** 越小越靠前；不匹配为 null。 */
export function matchScore(key: { text: string; full: string; initials: string }, q: string): number | null {
  if (key.text === q) return 0;
  if (key.text.startsWith(q)) return 1;
  if (key.text.includes(q)) return 2;
  // 拼音只认字母（用户输入「zhangsan」「zs」）；带中文的词已经在上面按原文比过了。
  if (!/^[a-z0-9]+$/.test(q)) return null;
  if (key.full.startsWith(q)) return 3;
  if (key.initials.startsWith(q)) return 4;
  if (key.full.includes(q)) return 5;
  if (q.length >= 2 && key.initials.includes(q)) return 6;
  return null;
}

export class PeopleSearch {
  private readonly indexes = new Map<number, Index>();
  private readonly building = new Map<number, Promise<Index>>();

  constructor(private readonly db: Db) {}

  async search(qqAccountId: number, query: string, opts: { limit: number; groupIds?: number[] }): Promise<PersonHit[]> {
    const q = query.trim().toLowerCase().replace(/\s+/g, '');
    if (!q) return [];
    const index = await this.index(qqAccountId);
    const only = opts.groupIds?.length ? new Set(opts.groupIds) : null;
    const hits: { entry: Entry; score: number; via: string; groupId: number }[] = [];
    for (const entry of index.entries) {
      if (only && !entry.groups.some((g) => only.has(g.groupId))) continue;
      let best: { score: number; via: string } | null = null;
      for (const key of entry.keys) {
        const score = matchScore(key, q);
        if (score !== null && (!best || score < best.score)) best = { score, via: key.source };
      }
      if (!best && /^\d{3,}$/.test(q) && String(entry.userId).includes(q)) best = { score: String(entry.userId) === q ? 0 : 7, via: '' };
      if (!best) continue;
      const group =
        entry.groups.find((g) => (!only || only.has(g.groupId)) && (g.card === best.via || g.nickname === best.via)) ??
        entry.groups.find((g) => !only || only.has(g.groupId));
      hits.push({ entry, score: best.score, via: best.via, groupId: group?.groupId ?? 0 });
    }
    hits.sort((a, b) => a.score - b.score || Number(b.entry.isFriend) - Number(a.entry.isFriend) || b.entry.groups.length - a.entry.groups.length);
    return hits.slice(0, opts.limit).map(({ entry, via, groupId }) => {
      const group = entry.groups.find((g) => g.groupId === groupId);
      const name = entry.remark || entry.name || group?.card || group?.nickname || entry.groups[0]?.card || entry.groups[0]?.nickname || String(entry.userId);
      let detail: string;
      if (entry.isFriend) detail = entry.remark && entry.name && entry.name !== entry.remark ? `好友 · ${entry.name}` : '好友';
      else if (group) {
        const others = entry.groups.length > 1 ? ` 等 ${entry.groups.length} 个群` : '';
        const alias = via && via !== name ? `「${via}」· ` : '';
        detail = `${alias}${group.groupName || `群 ${group.groupId}`}${others}`;
      } else detail = `QQ ${entry.userId}`;
      return { userId: entry.userId, name, detail, isFriend: entry.isFriend, avatarSha256: entry.avatar, groupId };
    });
  }

  private async index(qqAccountId: number): Promise<Index> {
    const current = this.indexes.get(qqAccountId);
    if (current && Date.now() - current.builtAt < INDEX_TTL_MS) return current;
    let pending = this.building.get(qqAccountId);
    if (!pending) {
      pending = this.build(qqAccountId).finally(() => this.building.delete(qqAccountId));
      this.building.set(qqAccountId, pending);
      pending.then((index) => this.indexes.set(qqAccountId, index)).catch(() => {});
    }
    // 有旧索引就先用旧的（重建在后台），第一次才等。
    return current ?? pending;
  }

  private async build(qqAccountId: number): Promise<Index> {
    const peers = await rows<{ id: string; name: string | null; remark: string | null; friend: boolean; avatar: string | null }>(
      this.db,
      sql`select peer_id as id, name, remark, is_friend as friend, avatar_sha256 as avatar
            from peers where qq_account_id = ${qqAccountId} and kind = 'user'`,
    );
    const members = await rows<{ gid: string; uid: string; card: string | null; nickname: string | null; gname: string | null }>(
      this.db,
      sql`select m.group_id as gid, m.user_id as uid, m.card, m.nickname, g.name as gname
            from group_members m
            left join peers g on g.qq_account_id = m.qq_account_id and g.kind = 'group' and g.peer_id = m.group_id
           where m.qq_account_id = ${qqAccountId}
           order by m.last_sent_at desc nulls last`,
    );
    const byUser = new Map<number, Entry>();
    const entry = (userId: number) => {
      let e = byUser.get(userId);
      if (!e) {
        e = { userId, remark: '', name: '', isFriend: false, avatar: '', groups: [], keys: [] };
        byUser.set(userId, e);
      }
      return e;
    };
    for (const p of peers) {
      const e = entry(Number(p.id));
      e.remark = p.remark ?? '';
      e.name = p.name ?? '';
      e.isFriend = p.friend;
      e.avatar = p.avatar ?? '';
    }
    for (const m of members) {
      entry(Number(m.uid)).groups.push({ groupId: Number(m.gid), groupName: m.gname ?? '', card: m.card ?? '', nickname: m.nickname ?? '' });
    }
    // 只有在 peers 里、既不是好友也不在任何群里的人（陌生人、群事件里的人）也能搜到，只是排在后面。
    const cache = new Map<string, { full: string; initials: string }>();
    for (const e of byUser.values()) {
      const texts = new Set([e.remark, e.name, ...e.groups.flatMap((g) => [g.card, g.nickname])].filter(Boolean));
      for (const source of texts) {
        let keys = cache.get(source);
        if (!keys) {
          keys = pinyinKeys(source);
          cache.set(source, keys);
        }
        e.keys.push({ text: source.toLowerCase(), source, ...keys });
      }
    }
    return { builtAt: Date.now(), entries: [...byUser.values()] };
  }
}
