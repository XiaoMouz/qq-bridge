// 单写者：同一服务端账号的所有写操作串行执行，每个操作一个事务，提交后再把更新发布到总线。
// pts 用 sync_state 行锁分配、chat_pts 用 chats 行锁分配，锁一直持有到提交，
// 所以"序号顺序 = 提交顺序"，客户端按序号增量拉取不会漏（即使将来有多个进程写入也成立）。
// 加锁顺序固定为：先 chats 行，再 sync_state 行，避免死锁。
//
// 不变式（由这里统一保证，写操作不必各自维护）：一次写操作里动过的会话行（包括分配了 chat_pts），
// 提交前都会分配新的 dialog_pts 并推送一次会话更新——否则客户端的会话快照（含 chat_pts）会与服务端不一致。
import { sql } from 'drizzle-orm';
import { one, type Db, type Tx } from '../db/client.ts';
import type { UpdateBus } from './bus.ts';
import { loadDialogs } from './difference.ts';
import type { Update } from './rows.ts';

export class WriteContext {
  private readonly touchedChats = new Set<number>();

  constructor(
    readonly tx: Tx,
    readonly accountId: number,
    private readonly pending: Update[],
  ) {}

  /** 声明本次操作改动了会话行（未读、已读位置、顶部消息等）；提交前统一分配 dialog_pts。 */
  touchDialog(chatId: number): void {
    this.touchedChats.add(chatId);
  }

  /** 由 AccountWriter 在操作结束、提交之前调用。 */
  async flushDialogs(): Promise<void> {
    for (const chatId of [...this.touchedChats].sort((a, b) => a - b)) {
      const pts = await this.allocPts();
      await this.tx.execute(sql`update chats set dialog_pts = ${pts} where id = ${chatId}`);
      const [dialog] = await loadDialogs(this.tx, [chatId]);
      if (dialog) this.pending.push({ type: 'dialog', pts, dialog });
    }
    this.touchedChats.clear();
  }

  /** 分配 n 个连续的全局 pts，返回第一个。 */
  async allocPts(n = 1): Promise<number> {
    const row = await one<{ pts: number }>(
      this.tx,
      sql`update sync_state set pts = pts + ${n} where account_id = ${this.accountId} returning pts`,
    );
    return row.pts - n + 1;
  }

  /** 分配会话内的下一个 chat_pts（会话行随之变化，所以也会触发会话更新）。 */
  async allocChatPts(chatId: number): Promise<number> {
    const row = await one<{ chat_pts: number }>(
      this.tx,
      sql`update chats set chat_pts = chat_pts + 1 where id = ${chatId} returning chat_pts`,
    );
    this.touchedChats.add(chatId);
    return row.chat_pts;
  }

  /** 登记一条待发布的更新；事务提交后才真正发布。 */
  emit(update: Update): void {
    this.pending.push(update);
  }
}

export class AccountWriter {
  private tail: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly db: Db,
    private readonly bus: UpdateBus,
    readonly accountId: number,
  ) {}

  run<T>(fn: (w: WriteContext) => Promise<T>): Promise<T> {
    const task = this.tail.then(async () => {
      const pending: Update[] = [];
      const result = await this.db.transaction(async (tx) => {
        const w = new WriteContext(tx, this.accountId, pending);
        const value = await fn(w);
        await w.flushDialogs();
        return value;
      });
      for (const update of pending) this.bus.publish(this.accountId, update);
      return result;
    });
    this.tail = task.catch(() => undefined);
    return task;
  }
}

export class WriterRegistry {
  private readonly writers = new Map<number, AccountWriter>();

  constructor(
    private readonly db: Db,
    private readonly bus: UpdateBus,
  ) {}

  forAccount(accountId: number): AccountWriter {
    let writer = this.writers.get(accountId);
    if (!writer) this.writers.set(accountId, (writer = new AccountWriter(this.db, this.bus, accountId)));
    return writer;
  }

  /** 直接推送临时事件（不写库、不占序号），例如"对方正在输入"。 */
  publishEphemeral(accountId: number, update: Update): void {
    this.bus.publish(accountId, update);
  }
}
