-- 状态页只需要最新接收时间和待处理/异常计数，不应反复读取带原始 JSON 的全部历史。
-- 运行中的实例可先并发建立并检查索引有效性，再由迁移登记；新实例直接建立。
CREATE INDEX IF NOT EXISTS "upstream_events_account_received_idx"
  ON "upstream_events" ("qq_account_id", "received_at" DESC);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "upstream_events_attention_idx"
  ON "upstream_events" ("qq_account_id", "state", "received_at")
  WHERE "state" IN ('pending', 'failed', 'ignored');
