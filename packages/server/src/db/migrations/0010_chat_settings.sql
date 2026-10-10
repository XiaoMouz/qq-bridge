ALTER TABLE "chats" ADD COLUMN "unread_mention_all" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "unread_replies" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "pinned_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "mention_all_notify" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "pinned_local" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "notify_local" boolean DEFAULT false NOT NULL;--> statement-breakpoint
-- 回复段补上被回复的人（以前误读了 senderUin，号码其实在原始消息的 replyElement.senderUid 里）。
UPDATE "messages" m SET "segments" = (
  SELECT jsonb_agg(
    CASE WHEN s->>'type' = 'reply' AND NOT (s ? 'senderId') AND (
           SELECT e->'replyElement'->>'senderUid' FROM jsonb_array_elements(m.raw->'elements') e
            WHERE jsonb_typeof(e->'replyElement') = 'object' LIMIT 1) ~ '^[1-9][0-9]{4,11}$'
         THEN s || jsonb_build_object('senderId', (
           SELECT (e->'replyElement'->>'senderUid')::bigint FROM jsonb_array_elements(m.raw->'elements') e
            WHERE jsonb_typeof(e->'replyElement') = 'object' LIMIT 1))
         ELSE s END ORDER BY ord)
  FROM jsonb_array_elements(m.segments) WITH ORDINALITY AS t(s, ord))
WHERE m.raw IS NOT NULL AND m.segments @> '[{"type":"reply"}]';
--> statement-breakpoint
-- "回复我"标志位（256）。
UPDATE "messages" m SET "flags" = m.flags | 256
  FROM "chats" c JOIN "qq_accounts" q ON q.id = c.qq_account_id
 WHERE c.id = m.chat_id AND m.segments @> jsonb_build_array(jsonb_build_object('type', 'reply', 'senderId', q.uin));
--> statement-breakpoint
-- 三种未读分开计数（@我 不再包含 @全体成员）。
UPDATE "chats" c SET
  "unread_mentions" = (SELECT count(*)::int FROM "messages" m WHERE m.chat_id = c.id AND m.seq > c.read_inbox_max_seq
                        AND m.sender_uin <> q.uin AND m.state = 'normal' AND (m.flags & 32) <> 0),
  "unread_mention_all" = (SELECT count(*)::int FROM "messages" m WHERE m.chat_id = c.id AND m.seq > c.read_inbox_max_seq
                        AND m.sender_uin <> q.uin AND m.state = 'normal' AND (m.flags & 64) <> 0 AND (m.flags & 32) = 0),
  "unread_replies" = (SELECT count(*)::int FROM "messages" m WHERE m.chat_id = c.id AND m.seq > c.read_inbox_max_seq
                        AND m.sender_uin <> q.uin AND m.state = 'normal' AND (m.flags & 256) <> 0)
  FROM "qq_accounts" q WHERE q.id = c.qq_account_id;
