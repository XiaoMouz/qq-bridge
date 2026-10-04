// 客户端应用更新的规则（与 Telegram 相同，见 docs/design.md 4.7）：
// 本地序号 + 本次占用的序号数 == 更新携带的序号 → 应用；更小 → 已处理过，忽略；更大 → 有空洞，需要拉差量。

export type UpdateDecision = 'apply' | 'skip' | 'gap';

export function classifyUpdate(localPts: number, pts: number, ptsCount = 1): UpdateDecision {
  if (localPts + ptsCount === pts) return 'apply';
  if (localPts + ptsCount > pts) return 'skip';
  return 'gap';
}

/** 发现空洞后先等这么久：乱序到达的更新可能自己补上空洞。 */
export const GAP_WAIT_MS = 500;
