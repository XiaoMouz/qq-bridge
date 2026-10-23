import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { drizzle, type NodePgDatabase } from 'drizzle-orm/node-postgres';
import { migrate } from 'drizzle-orm/node-postgres/migrator';
import type { SQL } from 'drizzle-orm';
import * as schema from './schema.ts';

// int8 一律解析成 number：id、pts、seq、QQ 号、字节数都远小于 2^53。
// 一旦出现超范围的值就直接报错，而不是静默丢精度（NT msgId 等 64 位标识按文本存）。
pg.types.setTypeParser(pg.types.builtins.INT8, (value: string) => {
  const n = Number(value);
  if (!Number.isSafeInteger(n)) throw new Error(`int8 value ${value} exceeds Number.MAX_SAFE_INTEGER`);
  return n;
});

export type Db = NodePgDatabase<typeof schema> & { $client: pg.Pool };
export type Tx = Parameters<Parameters<Db['transaction']>[0]>[0];
export type Queryable = Db | Tx;

export function createDb(
  connectionString: string,
  poolSize = 10,
  onError: (error: Error) => void = (error) => console.error('[db] connection error:', error.message),
): Db {
  const pool = new pg.Pool({ connectionString, max: poolSize });
  // 2026-10-24 实测：数据库重启时，借出未在查询中的连接（例如事务两条语句之间）发出 error 事件，
  // 没人监听就让整个进程退出，launchd 再拉起要约 40 秒。正在跑的查询照样经自己的回调失败，坏连接由连接池丢弃。
  pool.on('error', onError);
  pool.on('connect', (client) => client.on('error', onError));
  return drizzle(pool, { schema }) as Db;
}

export async function runMigrations(db: Db): Promise<void> {
  await migrate(db, { migrationsFolder: fileURLToPath(new URL('./migrations', import.meta.url)) });
}

/** 执行原生 SQL 并返回行（复杂查询都走这里，见 docs/design.md 4.1）。 */
export async function rows<T = Record<string, unknown>>(db: Queryable, query: SQL): Promise<T[]> {
  const result = await db.execute(query);
  return result.rows as T[];
}

export async function one<T = Record<string, unknown>>(db: Queryable, query: SQL): Promise<T> {
  const list = await rows<T>(db, query);
  if (list.length === 0) throw new Error('expected one row, got none');
  return list[0]!;
}

export async function maybeOne<T = Record<string, unknown>>(db: Queryable, query: SQL): Promise<T | null> {
  const list = await rows<T>(db, query);
  return list[0] ?? null;
}

/** 驱动可能把 timestamptz 返回成字符串或 Date，这里统一成 Date。 */
export function toDate(value: unknown): Date | null {
  if (value === null || value === undefined) return null;
  return value instanceof Date ? value : new Date(String(value));
}
