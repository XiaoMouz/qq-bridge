-- 2026-10-23：无到期策略时，定时清理仍按 sha256 随机回表扫描所有媒体，空结果也会占盘数分钟。
-- 单独索引已标记不需要原件的引用，让空清理直接结束；不改变原件保留和共享引用的判断。
-- 运行实例可先 CONCURRENTLY 建立并验证有效性，再由迁移登记。
CREATE INDEX IF NOT EXISTS "media_refs_discarded_sha256_idx"
  ON "media_refs" ("sha256") WHERE "keep_original" = false;
