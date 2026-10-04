import type { IncomingMedia, IncomingMessage, Scene, Segment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { one, type Db } from '../../src/db/client.ts';
import { IngestService } from '../../src/ingest/service.ts';
import { UpdateBus } from '../../src/sync/bus.ts';
import { WriterRegistry } from '../../src/sync/writer.ts';

let uinCounter = 100_000;

export interface TestAccount {
  accountId: number;
  qqAccountId: number;
  uin: number;
}

/** 直接插入一个服务端账号和一个 QQ 号（跳过 argon2，测试更快）。 */
export async function createTestAccount(db: Db, ingest: IngestService): Promise<TestAccount> {
  const uin = uinCounter++;
  const { id } = await one<{ id: number }>(
    db,
    sql`insert into accounts (username, password_hash) values (${`user-${uin}`}, 'x') returning id`,
  );
  await db.execute(sql`insert into sync_state (account_id) values (${id})`);
  const qqAccountId = await ingest.registerQqAccount(id, uin, `qq-${uin}`);
  return { accountId: id, qqAccountId, uin };
}

export function services(db: Db) {
  const bus = new UpdateBus();
  const writers = new WriterRegistry(db, bus);
  const ingest = new IngestService(db, writers);
  return { bus, writers, ingest };
}

export function textMessage(
  scene: Scene,
  peerId: number,
  seq: number,
  senderId: number,
  opts: { text?: string; self?: boolean; source?: IncomingMessage['source']; time?: number; extra?: Segment[] } = {},
): IncomingMessage {
  return {
    scene,
    peerId,
    seq,
    senderId,
    time: opts.time ?? 1_800_000_000 + seq,
    segments: [...(opts.extra ?? []), { type: 'text', text: opts.text ?? `msg ${seq}` }],
    media: [],
    self: opts.self ?? false,
    source: opts.source ?? 'realtime',
  };
}

export function imageMessage(
  scene: Scene,
  peerId: number,
  seq: number,
  senderId: number,
  media: Omit<IncomingMedia, 'ord' | 'kind' | 'role'>,
  opts: { time?: number } = {},
): IncomingMessage {
  return {
    scene,
    peerId,
    seq,
    senderId,
    time: opts.time ?? 1_800_000_000 + seq,
    segments: [{ type: 'image', media: { ord: 0, state: 'pending' } }],
    media: [{ ord: 0, kind: 'image', role: 'attachment', ...media }],
    self: false,
    source: 'realtime',
  };
}
