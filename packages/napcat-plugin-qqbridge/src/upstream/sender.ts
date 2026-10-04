// 发送消息（服务端发件箱 → 插件 x.send → NapCat send_*_msg）。
// 按 client_random_id 去重：服务端超时重试、插件重启后重试都只会发出一条——
// 进行中的请求共用同一个结果，已完成的结果落盘保留最近 2000 条。
import fs from 'node:fs';
import path from 'node:path';
import type { NapCatPluginContext, PluginLogger } from '../napcat.js';
import { callAction } from './actions.js';
import type { RecalledKey } from './forwarder.js';

export interface SendParams {
  clientRandomId: string;
  chatType: number;
  peerUin: string;
  message: unknown[];
}

export interface SendResult {
  messageId: number;
  msgSeq?: string;
  msgId?: string;
}

const KEEP = 2000;

export class Sender {
  private readonly inflight = new Map<string, Promise<SendResult>>();
  private readonly done = new Map<string, SendResult>();
  private readonly file: string;

  constructor(
    private readonly ctx: NapCatPluginContext,
    private readonly keys: { lookup(shortId: number): RecalledKey | undefined },
    dataDir: string,
    private readonly logger: PluginLogger,
  ) {
    this.file = path.join(dataDir, 'sent.json');
    try {
      const saved = JSON.parse(fs.readFileSync(this.file, 'utf8')) as [string, SendResult][];
      for (const [id, result] of saved) this.done.set(id, result);
    } catch {
      // 第一次运行
    }
  }

  send(params: SendParams): Promise<SendResult> {
    const id = String(params?.clientRandomId ?? '');
    if (!id) return Promise.reject(new Error('x.send: clientRandomId is required'));
    const finished = this.done.get(id);
    if (finished) return Promise.resolve(finished);
    const running = this.inflight.get(id);
    if (running) return running;
    const task = this.doSend(params)
      .then((result) => {
        this.done.set(id, result);
        while (this.done.size > KEEP) this.done.delete(this.done.keys().next().value!);
        this.persist();
        return result;
      })
      .finally(() => this.inflight.delete(id));
    this.inflight.set(id, task);
    return task;
  }

  private async doSend(p: SendParams): Promise<SendResult> {
    if (!Array.isArray(p.message) || p.message.length === 0) throw new Error('x.send: message is empty');
    const group = Number(p.chatType) === 2;
    const peer = Number(p.peerUin);
    if (!Number.isSafeInteger(peer) || peer <= 0) throw new Error('x.send: invalid peer');
    const data = (await callAction(
      this.ctx,
      group ? 'send_group_msg' : 'send_private_msg',
      group ? { group_id: peer, message: p.message } : { user_id: peer, message: p.message },
    )) as { message_id?: unknown } | null;
    const messageId = Number(data?.message_id);
    if (!Number.isFinite(messageId)) throw new Error('send succeeded without a message_id');
    // 真实 seq：发送成功时 NapCat 通常已经上报了 message_sent 事件（插件记得短 id → seq）；没有再查 get_msg。
    let key = this.keys.lookup(messageId);
    if (!key) {
      try {
        const msg = (await callAction(this.ctx, 'get_msg', { message_id: messageId })) as { real_seq?: unknown } | null;
        if (msg?.real_seq) key = { msgSeq: String(msg.real_seq) };
      } catch (error) {
        this.logger.warn('[qqbridge] sent, but cannot resolve seq:', error instanceof Error ? error.message : error);
      }
    }
    return { messageId, ...(key?.msgSeq ? { msgSeq: key.msgSeq } : {}), ...(key?.msgId ? { msgId: key.msgId } : {}) };
  }

  private persist(): void {
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      const tmp = `${this.file}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify([...this.done.entries()]));
      fs.renameSync(tmp, this.file);
    } catch (error) {
      this.logger.warn('[qqbridge] cannot persist sent ids:', error instanceof Error ? error.message : error);
    }
  }
}
