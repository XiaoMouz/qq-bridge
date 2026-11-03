import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { sql } from 'drizzle-orm';
import pino from 'pino';
import { afterAll, beforeAll, expect, it } from 'vitest';
import { createDeps } from '../src/app.ts';
import { rows, type Db } from '../src/db/client.ts';
import { BackupApplier, type ExportRecord } from '../src/imports/apply.ts';
import { HoleFiller } from '../src/upstream/history.ts';
import { InboxProcessor } from '../src/upstream/inbox.ts';
import { createTestAccount, type TestAccount } from './helpers/fixtures.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';

const GROUP = 900001;
const FRIEND = 900002;
const T0 = 1_791_000_000;
const PNG = Buffer.from('89504e470d0a1a0a0000000d4948445200000001000000010806000000', 'hex');
const PNG_SHA = createHash('sha256').update(PNG).digest('hex');

let t: TestDb;
let db: Db;
let deps: ReturnType<typeof createDeps>;
let acc: TestAccount;
let work: string;

/** 和 importer.py 输出同形状的一条备份记录（nt 是 NT 原始消息，record 是匹配器用的解析结果）。 */
function text(table: string, seq: number, random: number, time: number, sender: number, body: string): ExportRecord {
  const scene = table.startsWith('msg_1_') ? 'group' : 'friend';
  const peer = table.split('_')[2]!;
  return {
    sourceKey: [table, time, String(seq), String(random)], kind: 'message', scene, sendStatus: 2, media: {},
    nt: {
      msgSeq: String(seq), msgRandom: String(random), msgTime: String(time), chatType: scene === 'group' ? 2 : 1,
      senderUid: `u_${sender}`, senderUin: String(sender), peerUin: peer, sendStatus: 2,
      elements: [{ elementType: 1, elementId: '0', textElement: { content: body, atType: 0 } }],
      backupSource: { table, time, seq: String(seq), random: String(random) },
    } as ExportRecord['nt'],
    record: {
      table, sourceKey: [table, time, String(seq), String(random)], scene, peer, seq: String(seq), clientSeq: null, random: String(random),
      time, senderUid: `u_${sender}`, senderUin: String(sender), sendStatus: 2, identityDisagreement: false,
      elements: [{ type: 1, kind: 'text', text: body }], nodes: [],
    },
  };
}
function tip(table: string, seq: number, time: number, gray: Record<string, unknown>, kind = 'system'): ExportRecord {
  const r = text(table, seq, 0, time, 0, '');
  return { ...r, kind: 'tip', nt: { ...r.nt, senderUin: '0', elements: [{ elementType: 8, elementId: '0', grayTipElement: gray }] },
    tips: [{ type: 8, kind, grayTip: gray, savedText: null, recalled: [] }] };
}

/** 假的 importer.py：按表给出一批记录；游标、meta、媒体提取都在内存里。 */
function fakeReader(tables: Record<string, ExportRecord[]>, payloads: Record<string, Buffer>) {
  const done = new Set<string>();
  const meta = new Map<string, unknown>();
  return {
    async request(req: any): Promise<any> {
      switch (req.command) {
        case 'open': return { tables: Object.keys(tables).length };
        case 'next': {
          const table = Object.keys(tables).find((k) => !done.has(k));
          if (!table) return { table: null, records: [], cursor: null, tableDone: true, finished: true };
          done.add(table);
          return { table, records: tables[table], cursor: [0, 0, 0], tableDone: true };
        }
        case 'commit': return { ok: true };
        case 'meta_get': return { value: meta.get(req.key) ?? null };
        case 'meta_set': meta.set(req.key, req.value); return { ok: true };
        case 'extract': {
          const bytes = payloads[req.sha256];
          if (!bytes) return { missing: 'payload_not_in_scan' };
          await fs.writeFile(req.path, bytes);
          return { sha256: req.sha256, size: bytes.length };
        }
        default: throw new Error(req.command);
      }
    },
    async stop() {},
  };
}

async function runImport(tables: Record<string, ExportRecord[]>, payloads: Record<string, Buffer> = {}, dryRun = false) {
  const applier = new BackupApplier(db, deps.ingest, deps.media, deps.processor, 'python3', '', pino({ level: 'silent' }), () => fakeReader(tables, payloads));
  return applier.run({
    backupPath: '', keysPath: '', scanPath: '', statePath: '', reportPath: path.join(work, 'report.jsonl'), stagingDir: path.join(work, 'staging'),
    qqAccountId: acc.qqAccountId, dryRun,
  });
}

const message = (chatScene: string, peer: number, seq: number) => rows<{ seq: number; version: number; state: string; source: string; raw: any; segments: any[] }>(
  db,
  sql`select m.seq, m.version, m.state, m.source, m.raw, m.segments from messages m join chats c on c.id = m.chat_id
       where c.qq_account_id = ${acc.qqAccountId} and c.scene = ${chatScene} and c.peer_id = ${peer} and m.seq = ${seq}`,
);

beforeAll(async () => {
  t = await startTestDb();
  db = t.db;
  work = await fs.mkdtemp(path.join(os.tmpdir(), 'qq-import-apply-'));
  deps = createDeps(db, { mediaRoot: path.join(work, 'media'), mediaUrlSecret: 'x'.repeat(32), logLevel: 'silent' });
  acc = await createTestAccount(db, deps.ingest);
  // 生产已有的群聊：seq 100–105 缺 103（生产离线期间），104 是另一条消息（备份里同 seq 的是重新编号前的老消息）。
  for (const seq of [100, 101, 102, 104, 105]) {
    const r = text(`msg_1_${GROUP}`, seq, 7000 + seq, T0 + seq * 10, 2001, `live ${seq}`);
    await deps.ingest.ingestMessage(acc.qqAccountId, {
      scene: 'group', peerId: GROUP, seq, senderId: 2001, time: T0 + seq * 10, random: 7000 + seq,
      segments: [{ type: 'text', text: `live ${seq}` }], media: [], self: false, source: 'realtime', raw: r.nt,
    });
  }
  await db.execute(sql`insert into peers (qq_account_id, kind, peer_id, uid, pts) values (${acc.qqAccountId}, 'user', 2001, 'u_2001', 1)`);
  await deps.ingest.addChatEvent(acc.qqAccountId, { scene: 'group', peerId: GROUP, kind: 'poke', time: T0 + 1020, actorId: 2001 });
}, 120_000);

afterAll(async () => {
  await t?.stop();
  await fs.rm(work, { recursive: true, force: true });
});

it('只写生产没有的：老历史不进增量、补洞分配 chat_pts、同 seq 的另一条换替代 seq', async () => {
  const g = `msg_1_${GROUP}`;
  const image: ExportRecord = {
    ...text(g, 40, 9040, T0 - 500, 2001, ''),
    media: { ':0': { status: 'resolved', sha256: PNG_SHA } },
  };
  image.nt.elements = [{ elementType: 2, elementId: '0', picElement: { fileName: 'a.png', fileSize: String(PNG.length), md5HexStr: createHash('md5').update(PNG).digest('hex') } }];
  image.record.elements = [{ type: 2, kind: 'image' }];
  const recallTip = tip(g, 60, T0 - 300, { subElementType: 1, revokeElement: { operatorUid: 'u_2001', origMsgSenderUid: 'u_2001' } });
  const tables = {
    [g]: [
      image,
      text(g, 50, 9050, T0 - 400, 2001, 'old history'),
      recallTip,
      text(g, 101, 7101, T0 + 1010, 2001, 'live 101'),          // 生产已有
      tip(g, 1020, T0 + 1020, { subElementType: 12, xmlElement: { content: '<gtip><qq uin="u_2001"/><nor txt="拍了拍"/></gtip>' } }, 'poke'),
      tip(g, 1031, T0 + 1031, { subElementType: 12, xmlElement: { content: '<gtip><qq uin="u_2001"/><nor txt="拍了拍"/></gtip>' } }, 'poke'),
      text(g, 103, 9103, T0 + 1030, 2001, 'gap 103'),            // 生产离线漏掉的
      text(g, 104, 9104, T0 - 9_000_000, 2001, 'old era 104'),   // 和生产 seq 104 撞号
    ],
    [`msg_3_${FRIEND}`]: [1, 2, 3].map((seq) => text(`msg_3_${FRIEND}`, seq, 500 + seq, T0 + seq, FRIEND, `new chat ${seq}`)),
  };

  const dry = await runImport(tables, { [PNG_SHA]: PNG }, true);
  expect(dry).toMatchObject({ duplicate: 1, would_insert_gap: 1, media_would_copy: 1, poke_duplicate: 1 });
  expect((await rows(db, sql`select 1 from messages where seq = 50`)).length).toBe(0);

  const summary = await runImport(tables, { [PNG_SHA]: PNG });
  expect(summary).toMatchObject({ duplicate: 1, inserted_gap: 1, media_copied: 1, poke_duplicate: 1, poke_inserted: 1, recall_inserted: 1 });

  const [history] = await message('group', GROUP, 50);
  expect(history).toMatchObject({ version: 0, source: 'backfill', state: 'normal' });
  const [gap] = await message('group', GROUP, 103);
  expect(gap!.version).toBeGreaterThan(0);
  const [recalled] = await message('group', GROUP, 60);
  expect(recalled).toMatchObject({ version: 0, state: 'recalled' });
  const [live104] = await message('group', GROUP, 104);
  expect(live104!.segments).toEqual([{ type: 'text', text: 'live 104' }]);
  const reassigned = await rows<{ seq: number; raw: any }>(db, sql`select seq, raw from messages where seq < 0`);
  expect(reassigned).toHaveLength(1);
  expect(reassigned[0]!.raw.backupSource).toMatchObject({ seq: '104', seqReassigned: true });

  const [img] = await message('group', GROUP, 40);
  expect(img!.segments[0]).toMatchObject({ type: 'image', media: { state: 'stored', sha256: PNG_SHA } });
  const refs = await rows<{ fetch_state: string; sha256: string | null }>(db, sql`select fetch_state, sha256 from media_refs where message_seq = 40`);
  expect(refs).toEqual([{ fetch_state: 'stored', sha256: PNG_SHA }]);

  const pokes = await rows<{ time: Date; version: number }>(db, sql`select time, version from chat_events where kind = 'poke' order by time`);
  expect(pokes).toHaveLength(2);

  // 新会话：最新一页进增量同步，已读到最新，没有未读。
  const [chat] = await rows<{ chat_pts: number; read_inbox_max_seq: number; unread_count: number; top_seq: number }>(
    db, sql`select chat_pts, read_inbox_max_seq, unread_count, top_seq from chats where scene = 'friend' and peer_id = ${FRIEND}`);
  expect(chat).toMatchObject({ chat_pts: 3, read_inbox_max_seq: 3, unread_count: 0, top_seq: 3 });
  const versions = await rows<{ version: number }>(db, sql`select m.version from messages m join chats c on c.id = m.chat_id where c.peer_id = ${FRIEND} order by m.seq`);
  expect(versions.map((v) => v.version)).toEqual([1, 2, 3]);

  // 导入覆盖的老历史段记为已核对（缺口补齐不去追这段）；生产原有范围不动。
  const [ranges] = await rows<{ group_ranges: string; friend_ranges: string }>(db, sql`select
    (select verified_ranges::text from chats where scene = 'group' and peer_id = ${GROUP}) as group_ranges,
    (select verified_ranges::text from chats where scene = 'friend' and peer_id = ${FRIEND}) as friend_ranges`);
  expect(ranges).toEqual({ group_ranges: '{[40,100)}', friend_ranges: '{[1,4)}' });
  // 生产原有范围里 103 补上了，老历史段已核对，负数替代 seq 不算：没有缺口可补。
  const filler = new HoleFiller(db, { call: async () => { throw new Error('should not call QQ'); } }, new InboxProcessor(db, deps.ingest), null);
  expect(await filler.holes(acc.qqAccountId)).toEqual([]);

  // 再跑一遍：全部认出是已有的，不重复写。
  const before = await rows<{ n: number }>(db, sql`select count(*)::int as n from messages`);
  const again = await runImport(tables, { [PNG_SHA]: PNG });
  expect(again.inserted_gap ?? 0).toBe(0);
  expect(again.inserted_history ?? 0).toBe(0);
  expect(again.recall_known).toBe(1);
  expect(again.poke_duplicate).toBe(2);
  expect(await rows(db, sql`select count(*)::int as n from messages`)).toEqual(before);
}, 120_000);
