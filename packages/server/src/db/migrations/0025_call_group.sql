-- 群语音（多人通话）所在的群号；1 对 1 通话为 null。
ALTER TABLE "calls" ADD COLUMN "group_id" bigint;
