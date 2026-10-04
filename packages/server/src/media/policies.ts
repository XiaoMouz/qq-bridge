// 存储策略（三层：全局 / 会话类型 / 单个会话，越具体越优先），每个字段各自继承：
//   keep_original_days：null = 继承上一层（全局也没设 = 永久）；-1 = 永久；0 = 只保留缩略图和预览图；N = 保留 N 天
//   auto_fetch_max_bytes：null = 继承上一层（全局也没设 = 默认上限）
//   cold_after_days：多少天没被访问就把原件下沉到冷存储；null = 继承（全局也没设 = 180 天）；-1 = 永不下沉
//   cold_min_bytes：只下沉不小于这个大小的原件；null = 继承（全局也没设 = 1 MiB）
//   hot_quota_bytes：会话 / 会话类型层 = 每个会话独占原件的热存储上限；全局层 = 整个账号的热存储上限（不往下继承）
// 这样给某个会话单独调整自动下载上限，不会顺带改掉它的原件保留期。
import type { PolicyRecord, Scene } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { maybeOne, rows, type Db, type Queryable } from '../db/client.ts';
import { sqlList } from '../sync/rows.ts';

export const KEEP_FOREVER = -1;

export type PolicyScope = 'global' | 'scene' | 'chat';

export interface StoragePolicyRow {
  scope: PolicyScope;
  scene: Scene | null;
  chatId: number | null;
  keepOriginalDays: number | null;
  autoFetchMaxBytes: number | null;
  coldAfterDays: number | null;
  coldMinBytes: number | null;
  hotQuotaBytes: number | null;
}

export const DEFAULT_COLD_AFTER_DAYS = 180;
export const DEFAULT_COLD_MIN_BYTES = 1024 * 1024;

/** 一个会话最终采用的分层规则。 */
export interface TieringRule {
  /** null = 永不下沉。 */
  coldAfterDays: number | null;
  coldMinBytes: number;
  /** 本会话独占原件的热存储上限；null = 不限。 */
  hotQuotaBytes: number | null;
}

/** 按"会话 > 会话类型 > 全局 > 默认值"逐字段解析分层规则。返回 (chatId, scene) → 规则，以及全局热存储上限。 */
export async function tieringRules(
  db: Queryable,
  accountId: number,
): Promise<{ forChat: (chatId: number, scene: Scene) => TieringRule; globalHotQuotaBytes: number | null }> {
  const list = await rows<{ scope: PolicyScope; scene: Scene | null; chat_id: number | null; cold_after_days: number | null; cold_min_bytes: number | null; hot_quota_bytes: number | null }>(
    db,
    sql`select scope, scene, chat_id, cold_after_days, cold_min_bytes, hot_quota_bytes from storage_policies where account_id = ${accountId}`,
  );
  const global = list.find((p) => p.scope === 'global');
  const scenes = new Map(list.filter((p) => p.scope === 'scene').map((p) => [p.scene, p]));
  const chats = new Map(list.filter((p) => p.scope === 'chat').map((p) => [Number(p.chat_id), p]));
  const pick = <K extends 'cold_after_days' | 'cold_min_bytes' | 'hot_quota_bytes'>(chatId: number, scene: Scene, key: K, withGlobal: boolean) => {
    const value = chats.get(chatId)?.[key] ?? scenes.get(scene)?.[key] ?? (withGlobal ? global?.[key] : null) ?? null;
    return value === null ? null : Number(value);
  };
  return {
    forChat: (chatId, scene) => {
      const days = pick(chatId, scene, 'cold_after_days', true) ?? DEFAULT_COLD_AFTER_DAYS;
      return {
        coldAfterDays: days === KEEP_FOREVER ? null : days,
        coldMinBytes: pick(chatId, scene, 'cold_min_bytes', true) ?? DEFAULT_COLD_MIN_BYTES,
        hotQuotaBytes: pick(chatId, scene, 'hot_quota_bytes', false),
      };
    },
    globalHotQuotaBytes: global?.hot_quota_bytes === null || global?.hot_quota_bytes === undefined ? null : Number(global.hot_quota_bytes),
  };
}

export class PolicyError extends Error {
  constructor(
    readonly code: 'invalid' | 'not_found',
    message: string,
  ) {
    super(message);
  }
}

/** 各账号参与原件保留判断的策略（没设保留天数的层不参与，等于继承上一层）。 */
export async function retentionPolicies(db: Queryable, accountIds: readonly number[]): Promise<Map<number, PolicyRecord[]>> {
  const byAccount = new Map<number, PolicyRecord[]>();
  if (accountIds.length === 0) return byAccount;
  const list = await rows<{ account_id: number; scope: PolicyScope; scene: Scene | null; chat_id: number | null; keep_original_days: number }>(
    db,
    sql`select account_id, scope, scene, chat_id, keep_original_days from storage_policies
         where account_id in ${sqlList([...accountIds])} and keep_original_days is not null`,
  );
  for (const p of list) {
    const records = byAccount.get(p.account_id) ?? [];
    records.push({
      scope: p.scope,
      scene: p.scene,
      chatId: p.chat_id,
      rule: { keepOriginalDays: p.keep_original_days === KEEP_FOREVER ? null : p.keep_original_days },
    });
    byAccount.set(p.account_id, records);
  }
  return byAccount;
}

export async function listPolicies(db: Db, accountId: number): Promise<StoragePolicyRow[]> {
  const list = await rows<{
    scope: PolicyScope;
    scene: Scene | null;
    chat_id: number | null;
    keep_original_days: number | null;
    auto_fetch_max_bytes: number | null;
    cold_after_days: number | null;
    cold_min_bytes: number | null;
    hot_quota_bytes: number | null;
  }>(
    db,
    sql`select scope, scene, chat_id, keep_original_days, auto_fetch_max_bytes, cold_after_days, cold_min_bytes, hot_quota_bytes
          from storage_policies
         where account_id = ${accountId}
         order by case scope when 'global' then 0 when 'scene' then 1 else 2 end, scene, chat_id`,
  );
  return list.map((p) => ({
    scope: p.scope,
    scene: p.scene,
    chatId: p.chat_id,
    keepOriginalDays: p.keep_original_days,
    autoFetchMaxBytes: p.auto_fetch_max_bytes,
    coldAfterDays: p.cold_after_days,
    coldMinBytes: p.cold_min_bytes === null ? null : Number(p.cold_min_bytes),
    hotQuotaBytes: p.hot_quota_bytes === null ? null : Number(p.hot_quota_bytes),
  }));
}

export type StoragePolicyInput = Omit<StoragePolicyRow, 'coldAfterDays' | 'coldMinBytes' | 'hotQuotaBytes'> &
  Partial<Pick<StoragePolicyRow, 'coldAfterDays' | 'coldMinBytes' | 'hotQuotaBytes'>>;

/** 设置某一层的策略（整层覆盖：没给的字段表示继承上一层）。 */
export async function setPolicy(db: Db, accountId: number, input: StoragePolicyInput): Promise<void> {
  const policy: StoragePolicyRow = { coldAfterDays: null, coldMinBytes: null, hotQuotaBytes: null, ...input };
  const key = await validateScope(db, accountId, policy);
  if (policy.keepOriginalDays !== null && !(Number.isInteger(policy.keepOriginalDays) && policy.keepOriginalDays >= KEEP_FOREVER)) {
    throw new PolicyError('invalid', 'keep_original_days must be -1 (forever), 0 or a positive number of days');
  }
  for (const [name, value] of [
    ['auto_fetch_max_bytes', policy.autoFetchMaxBytes],
    ['cold_min_bytes', policy.coldMinBytes],
    ['hot_quota_bytes', policy.hotQuotaBytes],
  ] as const) {
    if (value !== null && !(Number.isSafeInteger(value) && value >= 0)) throw new PolicyError('invalid', `${name} must be a non-negative number`);
  }
  if (policy.coldAfterDays !== null && !(Number.isInteger(policy.coldAfterDays) && policy.coldAfterDays >= KEEP_FOREVER)) {
    throw new PolicyError('invalid', 'cold_after_days must be -1 (never), 0 or a positive number of days');
  }
  await db.execute(
    sql`insert into storage_policies (account_id, scope, scene, chat_id, keep_original_days, auto_fetch_max_bytes, cold_after_days, cold_min_bytes, hot_quota_bytes)
        values (${accountId}, ${key.scope}, ${key.scene}, ${key.chatId}, ${policy.keepOriginalDays}, ${policy.autoFetchMaxBytes},
                ${policy.coldAfterDays}, ${policy.coldMinBytes}, ${policy.hotQuotaBytes})
        on conflict on constraint storage_policies_scope_unique do update
           set keep_original_days = excluded.keep_original_days,
               auto_fetch_max_bytes = excluded.auto_fetch_max_bytes,
               cold_after_days = excluded.cold_after_days,
               cold_min_bytes = excluded.cold_min_bytes,
               hot_quota_bytes = excluded.hot_quota_bytes`,
  );
}

export async function deletePolicy(db: Db, accountId: number, scope: Pick<StoragePolicyRow, 'scope' | 'scene' | 'chatId'>): Promise<boolean> {
  const key = await validateScope(db, accountId, scope);
  const res = await db.execute(
    sql`delete from storage_policies
         where account_id = ${accountId} and scope = ${key.scope}
           and scene is not distinct from ${key.scene} and chat_id is not distinct from ${key.chatId}`,
  );
  return (res.rowCount ?? 0) > 0;
}

async function validateScope(
  db: Db,
  accountId: number,
  p: Pick<StoragePolicyRow, 'scope' | 'scene' | 'chatId'>,
): Promise<{ scope: PolicyScope; scene: Scene | null; chatId: number | null }> {
  switch (p.scope) {
    case 'global':
      return { scope: 'global', scene: null, chatId: null };
    case 'scene':
      if (p.scene !== 'friend' && p.scene !== 'group' && p.scene !== 'temp') throw new PolicyError('invalid', 'scene is required');
      return { scope: 'scene', scene: p.scene, chatId: null };
    case 'chat': {
      if (!p.chatId) throw new PolicyError('invalid', 'chat_id is required');
      const chat = await maybeOne(
        db,
        sql`select 1 as x from chats c join qq_accounts q on q.id = c.qq_account_id where c.id = ${p.chatId} and q.account_id = ${accountId}`,
      );
      if (!chat) throw new PolicyError('not_found', `chat ${p.chatId} not found`);
      return { scope: 'chat', scene: null, chatId: p.chatId };
    }
    default:
      throw new PolicyError('invalid', 'unknown policy scope');
  }
}

/** 某个会话最终生效的全部策略（客户端"存储管理"页展示用）。 */
export async function effectivePolicy(
  db: Queryable,
  accountId: number,
  chatId: number,
  scene: Scene,
  defaultAutoFetchMaxBytes: number,
): Promise<{ keepOriginalDays: number; autoFetchMaxBytes: number; coldAfterDays: number; coldMinBytes: number; hotQuotaBytes: number | null }> {
  const list = await rows<{ scope: PolicyScope; scene: Scene | null; chat_id: number | null; keep_original_days: number | null; auto_fetch_max_bytes: number | null }>(
    db,
    sql`select scope, scene, chat_id, keep_original_days, auto_fetch_max_bytes from storage_policies
         where account_id = ${accountId} and (scope = 'global' or (scope = 'scene' and scene = ${scene}) or (scope = 'chat' and chat_id = ${chatId}))`,
  );
  const layer = (scope: PolicyScope) => list.find((p) => p.scope === scope);
  const pick = <K extends 'keep_original_days' | 'auto_fetch_max_bytes'>(key: K) =>
    layer('chat')?.[key] ?? layer('scene')?.[key] ?? layer('global')?.[key] ?? null;
  const tiering = (await tieringRules(db, accountId)).forChat(chatId, scene);
  const keep = pick('keep_original_days');
  const fetch = pick('auto_fetch_max_bytes');
  return {
    keepOriginalDays: keep === null ? KEEP_FOREVER : Number(keep),
    autoFetchMaxBytes: fetch === null ? defaultAutoFetchMaxBytes : Number(fetch),
    coldAfterDays: tiering.coldAfterDays ?? KEEP_FOREVER,
    coldMinBytes: tiering.coldMinBytes,
    hotQuotaBytes: tiering.hotQuotaBytes,
  };
}
