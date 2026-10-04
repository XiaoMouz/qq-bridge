import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { rows } from '../src/db/client.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';

let t: TestDb;

beforeAll(async () => {
  t = await startTestDb();
});

afterAll(async () => {
  await t?.stop();
});

describe('migrations', () => {
  it('create every table and the PGroonga full-text index', async () => {
    const tables = await rows<{ table_name: string }>(
      t.db,
      sql`select table_name from information_schema.tables where table_schema = 'public' order by table_name`,
    );
    expect(tables.map((r) => r.table_name)).toEqual(
      expect.arrayContaining([
        'accounts',
        'blob_variants',
        'blobs',
        'chat_blob_usage',
        'chat_storage',
        'chats',
        'devices',
        'media_refs',
        'messages',
        'outbox',
        'peers',
        'qq_accounts',
        'storage_policies',
        'sync_state',
        'tombstones',
      ]),
    );
    const indexes = await rows<{ indexdef: string }>(
      t.db,
      sql`select indexdef from pg_indexes where indexname = 'messages_text_pgroonga_idx'`,
    );
    expect(indexes[0]?.indexdef).toContain('USING pgroonga');
  });

  it('parses int8 columns as numbers', async () => {
    const [row] = await rows<{ n: unknown }>(t.db, sql`select 9007199254740991::int8 as n`);
    expect(row?.n).toBe(Number.MAX_SAFE_INTEGER);
    // drizzle 会把驱动错误包一层 "Failed query"，原始原因在 cause 里。
    const error = (await rows(t.db, sql`select 9007199254740993::int8 as n`).catch((e: unknown) => e)) as Error & {
      cause?: Error;
    };
    expect(error.cause?.message ?? error.message).toMatch(/MAX_SAFE_INTEGER/);
  });
});
