-- 状态页只计待下载与异常引用，下载认领也只需要 pending / failed；排除已存和按需媒体。
-- 2026-10-23 实测：原状态统计并行扫描整张媒体表，认领也出现超过 15 秒的磁盘预取等待。
CREATE INDEX IF NOT EXISTS "media_refs_attention_idx"
  ON "media_refs" ("fetch_state", "next_attempt_at", "chat_id")
  WHERE "fetch_state" IN ('pending', 'failed', 'expired');
