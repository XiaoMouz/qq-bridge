// 媒体原件保留策略（docs/design.md 4.6）。
// 规则分三层：单个会话 > 会话类型 > 全局默认；一个媒体被多个会话引用时，取保留最久的那个。

import type { Scene } from './types.ts';

export interface RetentionRule {
  /** 原件保留天数：null = 永久，0 = 只保留缩略图/预览，正数 = N 天。 */
  keepOriginalDays: number | null;
}

export interface PolicyRecord {
  scope: 'global' | 'scene' | 'chat';
  scene?: Scene | null;
  chatId?: number | null;
  rule: RetentionRule;
}

export const DEFAULT_RULE: RetentionRule = { keepOriginalDays: null };

export interface ScopedValue<T> {
  scope: 'global' | 'scene' | 'chat';
  scene?: Scene | null;
  chatId?: number | null;
  value: T;
}

/** 三层策略的通用优先级：单个会话 > 会话类型 > 全局；都没有时返回 undefined。 */
export function resolveScoped<T>(records: readonly ScopedValue<T>[], chat: { chatId: number; scene: Scene }): T | undefined {
  return (
    records.find((r) => r.scope === 'chat' && r.chatId === chat.chatId) ??
    records.find((r) => r.scope === 'scene' && r.scene === chat.scene) ??
    records.find((r) => r.scope === 'global')
  )?.value;
}

/** 找出某个会话生效的保留规则：会话级 > 场景级 > 全局 > 默认（永久保留）。 */
export function resolveRule(policies: readonly PolicyRecord[], chat: { chatId: number; scene: Scene }): RetentionRule {
  return resolveScoped(policies.map((p) => ({ ...p, value: p.rule })), chat) ?? DEFAULT_RULE;
}

export interface RefRetention {
  /** 媒体出现的时间（unix 秒）。 */
  time: number;
  /** 引用级覆盖（例如"清理该会话 90 天前的视频原件"会把对应引用设为 false）；null 表示按规则。 */
  override: boolean | null;
  rule: RetentionRule;
}

/** 这一处引用是否仍需要原件。 */
export function refKeepsOriginal(ref: RefRetention, nowSec: number): boolean {
  if (ref.override !== null) return ref.override;
  const days = ref.rule.keepOriginalDays;
  if (days === null) return true;
  if (days <= 0) return false;
  return nowSec - ref.time < days * 86_400;
}

/**
 * 一个媒体的原件能否删除：只有所有引用方都不再需要原件时才能删（保留最久者优先）。
 * 没有任何引用的媒体（孤儿）可以删除——变体文件的引用关系由调用方单独排除。
 */
export function originalPurgeable(refs: readonly RefRetention[], nowSec: number): boolean {
  return refs.every((ref) => !refKeepsOriginal(ref, nowSec));
}
