// 发出去但迟迟没收到自己那条消息的，单独向 QQ 要回来。
// 2026-10-25 实测：往群里发 2 MB 文件，send_msg 返回了 seq 5611，get_msg 也查得到（文件已传完、带下载链接），
// 但 NapCat 一直没推 message_sent 事件，消息就永远不入库，客户端一直显示发送中的气泡。小文件、图片都正常推。
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { rows, type Db } from '../db/client.ts';

export interface SentConfirmerDeps {
  ensureMessage(chatId: number, seq: number): Promise<boolean>;
}

export class SentConfirmer {
  /** 每条只补一次：要不回来（QQ 那边也没有）就交给缺口补齐。 */
  private readonly tried = new Set<string>();

  constructor(
    private readonly db: Db,
    private readonly history: () => SentConfirmerDeps | null,
    private readonly opts: { graceMs?: number; windowMs?: number; logger?: Logger } = {},
  ) {}

  async runOnce(): Promise<number> {
    const history = this.history();
    if (!history) return 0;
    const graceMs = this.opts.graceMs ?? 10_000;
    const windowMs = this.opts.windowMs ?? 30 * 60_000;
    const missing = await rows<{ chat_id: number; result_seq: number }>(
      this.db,
      sql`select o.chat_id, o.result_seq from outbox o
           where o.state = 'sent' and o.result_seq is not null
             and o.updated_at < now() - make_interval(secs => ${graceMs / 1000})
             and o.updated_at > now() - make_interval(secs => ${windowMs / 1000})
             and not exists (select 1 from messages m where m.chat_id = o.chat_id and m.seq = o.result_seq)
           order by o.id limit 20`,
    );
    let recovered = 0;
    for (const m of missing) {
      const key = `${m.chat_id}:${m.result_seq}`;
      if (this.tried.has(key)) continue;
      this.tried.add(key);
      try {
        if (await history.ensureMessage(Number(m.chat_id), Number(m.result_seq))) recovered += 1;
      } catch (error) {
        this.opts.logger?.warn({ err: error, chatId: m.chat_id, seq: m.result_seq }, 'confirm sent message failed');
      }
    }
    if (this.tried.size > 1000) this.tried.clear();
    if (recovered > 0) this.opts.logger?.info({ recovered }, 'fetched sent messages QQ never pushed');
    return recovered;
  }
}
