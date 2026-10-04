import type { NtRawMessage } from '../../src/upstream/napcat/types.ts';
import { el, raw } from './napcat.ts';

/** 假的 QQ：每个会话一段连续的消息；按插件 x.history 的语义分页（从 fromSeq 往前，含 fromSeq）。 */
export class FakeQq {
  readonly calls: { action: string; params: any }[] = [];
  private readonly chats = new Map<string, { chatType: 1 | 2; peer: string; messages: NtRawMessage[] }>();

  constructor(private readonly selfUin: number) {}

  /** missing：QQ 那边也没有的 seq（被删除等）。 */
  chat(chatType: 1 | 2, peer: string, upTo: number, sender: (seq: number) => string, missing: (seq: number) => boolean = () => false) {
    const messages = Array.from({ length: upTo }, (_, i) =>
      raw({ chatType, peer, seq: i + 1, sender: sender(i + 1), elements: [el.text(`${peer}#${i + 1}`)] }),
    ).filter((m) => !missing(Number(m.msgSeq)));
    this.chats.set(peer, { chatType, peer, messages });
  }

  async call<T = unknown>(qq: number, action: string, params: any): Promise<T> {
    return this.handle(qq, action, params) as T;
  }

  private handle(_qq: number, action: string, params: any): unknown {
    this.calls.push({ action, params });
    if (action === 'x.recent_contacts') {
      return [...this.chats.values()].map((c) => ({
        chatType: c.chatType,
        peerUid: c.chatType === 2 ? c.peer : `u_${c.peer}`,
        peerUin: c.peer,
        latest: c.messages[c.messages.length - 1] ?? null,
      }));
    }
    if (action === 'x.history') {
      const chat = this.chats.get(params.peerUin)!;
      const from = Number(params.fromSeq);
      const upper = params.includeCurrent ? from : from - 1;
      // 返回顺序故意打乱为升序，验证服务端不依赖顺序。
      // 语义同 getMsgsBySeqAndCount：upper 及之前的 count 条（跳过不存在的 seq）。
      return { messages: chat.messages.filter((m) => Number(m.msgSeq) <= upper).slice(-params.count) };
    }
    throw new Error(`unexpected ${action} (self ${this.selfUin})`);
  }
}
