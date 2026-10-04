// 同步收敛的属性测试（docs/design.md 第 8 节）：随机的服务端写入 + 随机丢更新、随机断线的客户端，
// 客户端最终用 getDifference / getChatDifference 追平后，状态必须与服务端完全一致。
import { classifyUpdate, type Scene } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import fc from 'fast-check';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { rows, type Db } from '../src/db/client.ts';
import { getChatDifference, getDifference, getHistory } from '../src/sync/difference.ts';
import type { DialogRow, MessageRow, PeerRow, Update } from '../src/sync/rows.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage } from './helpers/fixtures.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

const CHATS: { scene: Scene; peerId: number }[] = [
  { scene: 'group', peerId: 1001 },
  { scene: 'group', peerId: 1002 },
  { scene: 'friend', peerId: 2001 },
];
const PEER_NAMES = ['甲', '乙', '丙'];

type Command =
  | { op: 'msg'; chat: number; who: 'other' | 'self' | 'mention'; backfill: boolean; skip: boolean }
  | { op: 'recall'; chat: number; pick: number }
  | { op: 'markRead'; chat: number }
  | { op: 'peer'; peer: number; name: number }
  | { op: 'deliver'; count: number; dropBits: number }
  | { op: 'pull' }
  | { op: 'open'; chat: number };

const chatIdx = fc.integer({ min: 0, max: CHATS.length - 1 });
const commandArb: fc.Arbitrary<Command> = fc.oneof(
  { weight: 6, arbitrary: fc.record({ op: fc.constant('msg' as const), chat: chatIdx, who: fc.constantFrom('other', 'self', 'mention'), backfill: fc.boolean(), skip: fc.boolean() }) },
  { weight: 2, arbitrary: fc.record({ op: fc.constant('recall' as const), chat: chatIdx, pick: fc.nat() }) },
  { weight: 2, arbitrary: fc.record({ op: fc.constant('markRead' as const), chat: chatIdx }) },
  { weight: 1, arbitrary: fc.record({ op: fc.constant('peer' as const), peer: fc.integer({ min: 0, max: 2 }), name: fc.integer({ min: 0, max: 2 }) }) },
  { weight: 5, arbitrary: fc.record({ op: fc.constant('deliver' as const), count: fc.integer({ min: 1, max: 6 }), dropBits: fc.nat({ max: 63 }) }) },
  { weight: 1, arbitrary: fc.record({ op: fc.constant('pull' as const) }) },
  { weight: 2, arbitrary: fc.record({ op: fc.constant('open' as const), chat: chatIdx }) },
);

/** 客户端模型：严格按 Telegram 规则应用更新，发现空洞就拉差量。 */
class SimClient {
  pts = 0;
  readonly dialogs = new Map<number, DialogRow>();
  readonly peers = new Map<string, PeerRow>();
  readonly chats = new Map<number, { chatPts: number; messages: Map<number, MessageRow> }>();

  constructor(
    private readonly db: Db,
    private readonly accountId: number,
  ) {}

  async pullDifference(): Promise<void> {
    for (;;) {
      const diff = await getDifference(this.db, this.accountId, this.pts, 3);
      for (const dialog of diff.dialogs) this.dialogs.set(dialog.chatId, dialog);
      for (const peer of diff.peers) this.peers.set(peerKey(peer), peer);
      this.pts = diff.pts;
      if (diff.final) break;
    }
  }

  async openChat(chatId: number): Promise<void> {
    const history = await getHistory(this.db, this.accountId, chatId, { direction: 'older', limit: 200 });
    this.chats.set(chatId, { chatPts: history.chatPts, messages: new Map(history.messages.map((m) => [m.seq, m])) });
  }

  async pullChat(chatId: number): Promise<void> {
    const chat = this.chats.get(chatId);
    if (!chat) return;
    for (;;) {
      const diff = await getChatDifference(this.db, this.accountId, chatId, chat.chatPts, 2);
      if (diff.tooLong) chat.messages.clear();
      for (const message of diff.messages) chat.messages.set(message.seq, message);
      chat.chatPts = diff.chatPts;
      if (diff.final) break;
    }
  }

  async applyLive(update: Update): Promise<void> {
    if (update.type === 'chatMessage') {
      const chat = this.chats.get(update.chatId);
      if (!chat) return;
      const decision = classifyUpdate(chat.chatPts, update.chatPts);
      if (decision === 'apply') {
        chat.messages.set(update.message.seq, update.message);
        chat.chatPts = update.chatPts;
      } else if (decision === 'gap') {
        await this.pullChat(update.chatId);
      }
      return;
    }
    if (!('pts' in update)) return; // 服务事件 / 临时事件不在这个模型里
    const decision = classifyUpdate(this.pts, update.pts);
    if (decision === 'gap') return this.pullDifference();
    if (decision === 'skip') return;
    if (update.type === 'dialog') {
      this.dialogs.set(update.dialog.chatId, update.dialog);
      const chat = this.chats.get(update.dialog.chatId);
      // 会话行显示这个会话的消息流比本地新：说明丢过 chatMessage 更新，补拉。
      if (chat && update.dialog.chatPts > chat.chatPts) await this.pullChat(update.dialog.chatId);
    } else if (update.type === 'peer') {
      this.peers.set(peerKey(update.peer), update.peer);
    }
    this.pts = update.pts;
  }
}

function peerKey(p: PeerRow): string {
  return `${p.qqAccountId}:${p.kind}:${p.peerId}`;
}

describe('sync convergence (property)', () => {
  it('a lossy client always converges to the server state', async () => {
    await fc.assert(
      fc.asyncProperty(fc.array(commandArb, { minLength: 5, maxLength: 45 }), async (commands) => {
        const { ingest, bus } = services(t.db);
        const acc = await createTestAccount(t.db, ingest);
        const inbox: Update[] = [];
        const unsubscribe = bus.subscribe(acc.accountId, (u) => inbox.push(u));
        const client = new SimClient(t.db, acc.accountId);
        const seqs = CHATS.map(() => [] as number[]);
        const chatIds = new Map<number, number>();

        try {
          for (const cmd of commands) {
            switch (cmd.op) {
              case 'msg': {
                const known = seqs[cmd.chat]!;
                const max = known.length ? Math.max(...known) : 100;
                const min = known.length ? Math.min(...known) : 100;
                const backfill = cmd.backfill && known.length > 0 && min > 1;
                const seq = backfill ? min - 1 : max + (cmd.skip ? 2 : 1);
                const { scene, peerId } = CHATS[cmd.chat]!;
                const self = cmd.who === 'self';
                const message = textMessage(scene, peerId, seq, self ? acc.uin : 7, {
                  self,
                  source: backfill ? 'backfill' : self ? 'self' : 'realtime',
                  extra: cmd.who === 'mention' ? [{ type: 'mention', userId: acc.uin }] : [],
                });
                const res = await ingest.ingestMessage(acc.qqAccountId, message);
                chatIds.set(cmd.chat, res.chatId);
                known.push(seq);
                break;
              }
              case 'recall': {
                const known = seqs[cmd.chat]!;
                if (known.length === 0) break;
                const { scene, peerId } = CHATS[cmd.chat]!;
                await ingest.recall(acc.qqAccountId, scene, peerId, known[cmd.pick % known.length]!, 7, 1_900_000_000);
                break;
              }
              case 'markRead': {
                const chatId = chatIds.get(cmd.chat);
                const known = seqs[cmd.chat]!;
                if (chatId === undefined || known.length === 0) break;
                await ingest.markRead(acc.accountId, chatId, Math.max(...known));
                break;
              }
              case 'peer':
                await ingest.upsertPeer(acc.qqAccountId, { kind: 'user', peerId: 7 + cmd.peer, name: PEER_NAMES[cmd.name]! });
                break;
              case 'deliver':
                for (let i = 0; i < cmd.count && inbox.length > 0; i++) {
                  const update = inbox.shift()!;
                  if ((cmd.dropBits >> i) & 1) continue; // 模拟丢包 / 断线
                  await client.applyLive(update);
                }
                break;
              case 'pull':
                await client.pullDifference();
                for (const chatId of client.chats.keys()) await client.pullChat(chatId);
                break;
              case 'open': {
                const chatId = chatIds.get(cmd.chat);
                if (chatId !== undefined) await client.openChat(chatId);
                break;
              }
            }
          }

          // 最终追平：任何丢失的更新都必须能通过差量补回。
          await client.pullDifference();
          for (const chatId of client.chats.keys()) await client.pullChat(chatId);

          const server = await getDifference(t.db, acc.accountId, 0, 10_000);
          expect(client.pts).toBe(server.pts);
          expect(new Map(server.dialogs.map((d) => [d.chatId, d]))).toEqual(client.dialogs);
          expect(new Map(server.peers.map((p) => [peerKey(p), p]))).toEqual(client.peers);
          for (const [chatId, chat] of client.chats) {
            const history = await getHistory(t.db, acc.accountId, chatId, { direction: 'older', limit: 200 });
            expect(chat.chatPts).toBe(history.chatPts);
            expect(chat.messages).toEqual(new Map(history.messages.map((m) => [m.seq, m])));
          }

          // 增量维护的未读数必须等于全量定义。
          const mismatched = await rows(
            t.db,
            sql`select c.id from chats c
                 where c.qq_account_id = ${acc.qqAccountId}
                   and c.unread_count <> (select count(*) from messages m
                                           where m.chat_id = c.id and m.seq > c.read_inbox_max_seq
                                             and m.sender_uin <> ${acc.uin} and m.state = 'normal')`,
          );
          expect(mismatched).toEqual([]);
        } finally {
          unsubscribe();
        }
      }),
      { numRuns: Number(process.env.PROPERTY_RUNS ?? 40) },
    );
  });
});
