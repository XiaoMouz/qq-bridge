-- 预检任务只写自己的状态；不分配消息同步版本、不产生历史未读或推送。
CREATE TABLE backup_import_jobs (
  id uuid PRIMARY KEY,
  account_id bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  qq_account_id bigint NOT NULL REFERENCES qq_accounts(id) ON DELETE CASCADE,
  source_path text NOT NULL,
  keys_path text NOT NULL,
  batch_size integer NOT NULL CHECK (batch_size BETWEEN 1 AND 500),
  state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','running','pausing','paused','completed','failed')),
  desired_state text NOT NULL DEFAULT 'running' CHECK (desired_state IN ('running','paused')),
  summary jsonb NOT NULL DEFAULT '{}',
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
--> statement-breakpoint
CREATE INDEX backup_import_jobs_pending_idx ON backup_import_jobs(created_at) WHERE state IN ('queued','running','pausing');
--> statement-breakpoint
-- 候选只读取同会话 seq 或同一秒消息，不扫描整个 raw JSON。
-- 2026-11-03：messages 约 140 万行、2 GB 在 USB 2.0 盘上，启动迁移里直接建会锁写入且拖住启动；
-- 运行实例先 CONCURRENTLY 建立并验证有效性，再由迁移登记。
CREATE INDEX IF NOT EXISTS messages_chat_time_idx ON messages(chat_id,time);
