// 按会话的存储占用统计（docs/design.md 4.6）。
// 这里是"全量计算"的参考实现：服务端在单写者里做增量维护，并定期用全量结果校正；属性测试用它做判定基准。

export interface ChatUsage {
  chatId: number;
  sha256: string;
  size: number;
  /** 原件是否还在（已清理的原件不再占空间，也不计入数量）。默认 true。 */
  present?: boolean;
}

export interface ChatStorage {
  /** 本会话引用的、原件还在的不同媒体的大小之和（原件已清理的不再占空间）。 */
  logicalBytes: number;
  /** 只被本会话引用的媒体之和：清理本会话能真正腾出的空间。 */
  exclusiveBytes: number;
  blobCount: number;
}

export function computeChatStorage(usages: readonly ChatUsage[]): Map<number, ChatStorage> {
  const chatsByBlob = new Map<string, Set<number>>();
  const sizeByBlob = new Map<string, number>();
  for (const u of usages) {
    sizeByBlob.set(u.sha256, u.present === false ? 0 : u.size);
    let chats = chatsByBlob.get(u.sha256);
    if (!chats) chatsByBlob.set(u.sha256, (chats = new Set()));
    chats.add(u.chatId);
  }
  const result = new Map<number, ChatStorage>();
  for (const [sha256, chats] of chatsByBlob) {
    const size = sizeByBlob.get(sha256) ?? 0;
    const present = usages.find((u) => u.sha256 === sha256)?.present !== false;
    for (const chatId of chats) {
      const s = result.get(chatId) ?? { logicalBytes: 0, exclusiveBytes: 0, blobCount: 0 };
      if (present) {
        s.logicalBytes += size;
        s.blobCount += 1;
        // "独占"看的是引用关系（被几个会话引用），与原件在不在无关；原件不在时大小为 0。
        if (chats.size === 1) s.exclusiveBytes += size;
      }
      result.set(chatId, s);
    }
  }
  return result;
}
