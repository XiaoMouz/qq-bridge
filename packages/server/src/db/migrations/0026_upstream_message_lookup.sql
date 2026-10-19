-- 撤回等通知没有 seq 时按 NapCat 短 id 查原事件；未命中也不能扫描全部 JSON，
-- 否则一条通知会阻塞同账号后续所有消息（2026-10-19 Ext1 迁移后实测）。
CREATE INDEX "upstream_events_message_id_idx"
  ON "upstream_events" ("qq_account_id", ("payload"->>'message_id'), "id" DESC)
  WHERE "payload" ? 'raw';
