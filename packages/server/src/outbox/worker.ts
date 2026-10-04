// 发送任务：把发件箱里的条目经上游（NapCat 插件 x.send）发往 QQ。
// - 同一会话严格按顺序：前一条还没发完（含退避等待中），后面的就等着；
// - QQ（插件）不在线：条目保持 pending，不消耗重试次数，插件连上后立即开始；
// - 超时：重试（插件按 client_random_id 去重，不会发出两条）；插件明确返回失败：直接判失败，用户可以手动重试。
import { outgoingMedia, type OutgoingMessage } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import type { MediaUrlSigner } from '../api/media-urls.ts';
import { rows, type Db } from '../db/client.ts';
import { sqlList } from '../sync/rows.ts';
import { UpstreamCallError, UpstreamOfflineError, type UpstreamHub } from '../upstream/hub.ts';
import { toOb11 } from './ob11.ts';
import type { OutboxService } from './service.ts';

export interface OutboxWorkerOptions {
  /** 插件访问服务端媒体的地址前缀（QQ 容器视角），例如 http://host.internal:8080。 */
  mediaBaseUrl: string;
  sendTimeoutMs?: number;
  maxAttempts?: number;
  retryDelaysMs?: number[];
  pollMs?: number;
  logger?: Logger;
}

interface Claimed {
  id: number;
  account_id: number;
  client_random_id: number;
  content: OutgoingMessage;
  attempts: number;
  scene: string;
  peer_id: number;
  qq_account_id: number;
}

export interface SendResult {
  messageId?: number;
  msgSeq?: string;
  msgId?: string;
}

export class OutboxWorker {
  private running = false;
  private loop: Promise<void> | null = null;
  private wake: (() => void) | null = null;
  private readonly o: Required<Omit<OutboxWorkerOptions, 'logger'>> & Pick<OutboxWorkerOptions, 'logger'>;

  constructor(
    private readonly db: Db,
    private readonly outbox: OutboxService,
    private readonly upstream: Pick<UpstreamHub, 'call' | 'isConnected'>,
    private readonly signer: MediaUrlSigner,
    opts: OutboxWorkerOptions,
  ) {
    this.o = { sendTimeoutMs: 180_000, maxAttempts: 3, retryDelaysMs: [5_000, 30_000, 120_000], pollMs: 5_000, ...opts };
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.loop = (async () => {
      while (this.running) {
        const n = await this.runOnce().catch((error: unknown) => {
          this.o.logger?.error({ err: error }, 'outbox round failed');
          return 0;
        });
        if (n === 0 && this.running) await this.sleep(this.o.pollMs);
      }
    })();
  }

  poke(): void {
    this.wake?.();
  }

  async stop(): Promise<void> {
    this.running = false;
    this.poke();
    await this.loop;
  }

  /** 处理一轮：每个会话取最早的一条待发送条目，依次发送；返回处理了多少条。 */
  async runOnce(): Promise<number> {
    const due = await rows<Claimed>(
      this.db,
      sql`select o.id, o.account_id, o.client_random_id, o.content, o.attempts, c.scene, c.peer_id, c.qq_account_id
            from outbox o join chats c on c.id = o.chat_id
           where o.state = 'pending'
             and (o.next_attempt_at is null or o.next_attempt_at <= now())
             and not exists (
               select 1 from outbox earlier
                where earlier.chat_id = o.chat_id and earlier.id < o.id and earlier.state in ('pending', 'sending'))
           order by o.id
           limit 50`,
    );
    let processed = 0;
    for (const entry of due) {
      if (!this.running && this.loop) break;
      if (!this.upstream.isConnected(entry.qq_account_id)) continue; // 等插件连上
      await this.send(entry);
      processed += 1;
    }
    return processed;
  }

  private async send(entry: Claimed): Promise<void> {
    const attempts = entry.attempts + 1;
    const claimed = await this.outbox.update(entry.account_id, entry.id, { state: 'sending', attempts, error: null }, 'pending');
    if (!claimed) return; // 已被别的处理轮次认领
    try {
      const message = await this.ob11Message(entry.content);
      const result = await this.upstream.call<SendResult>(
        entry.qq_account_id,
        'x.send',
        {
          clientRandomId: String(entry.client_random_id),
          chatType: entry.scene === 'group' ? 2 : 1,
          peerUin: String(entry.peer_id),
          message,
        },
        this.o.sendTimeoutMs,
      );
      const seq = Number(result?.msgSeq);
      await this.outbox.update(entry.account_id, entry.id, {
        state: 'sent',
        resultSeq: Number.isSafeInteger(seq) && seq > 0 ? seq : null,
        qqMsgId: result?.msgId ?? null,
        error: null,
        nextAttemptAt: null,
      });
    } catch (error) {
      const text = error instanceof Error ? error.message : String(error);
      if (error instanceof UpstreamOfflineError) {
        // 插件断开：不算一次尝试，等它连上再发。
        await this.outbox.update(entry.account_id, entry.id, { state: 'pending', attempts: entry.attempts, error: null });
        return;
      }
      const permanent = error instanceof UpstreamCallError || attempts >= this.o.maxAttempts;
      const delay = this.o.retryDelaysMs[Math.min(attempts - 1, this.o.retryDelaysMs.length - 1)] ?? 60_000;
      await this.outbox.update(entry.account_id, entry.id, {
        state: permanent ? 'failed' : 'pending',
        error: text,
        nextAttemptAt: permanent ? null : new Date(Date.now() + delay),
      });
      this.o.logger?.warn({ id: entry.id, attempts, permanent, err: text }, 'outbox send failed');
    }
  }

  private async ob11Message(content: OutgoingMessage) {
    const shas = outgoingMedia(content.segments);
    const mimes = new Map<string, string | null>();
    if (shas.length > 0) {
      for (const r of await rows<{ sha256: string; mime: string | null }>(
        this.db,
        sql`select sha256, mime from blobs where sha256 in ${sqlList(shas)}`,
      )) {
        mimes.set(r.sha256, r.mime);
      }
    }
    const base = this.o.mediaBaseUrl.replace(/\/+$/, '');
    return toOb11(content, (sha, name) => base + this.signer.signNamed(sha, name).url, mimes);
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(done, ms);
      const self = this;
      function done() {
        clearTimeout(timer);
        if (self.wake === done) self.wake = null;
        resolve();
      }
      this.wake = done;
    });
  }
}
