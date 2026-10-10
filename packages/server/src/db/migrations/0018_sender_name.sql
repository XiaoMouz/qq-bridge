-- 消息带上发送者当时的显示名（群名片，没有就昵称），会话列表预览"某某：内容"用。
ALTER TABLE "messages" ADD COLUMN "sender_name" text;
--> statement-breakpoint
UPDATE messages
SET sender_name = coalesce(nullif(raw->>'sendMemberName', ''), nullif(raw->>'sendNickName', ''))
WHERE raw IS NOT NULL;
--> statement-breakpoint
-- 推进所有会话行的 dialog_pts，客户端重新拉会话列表（顶部消息带上名字）。
WITH d AS (
  SELECT c.id, q.account_id, row_number() OVER (PARTITION BY q.account_id ORDER BY c.id) AS rn
  FROM chats c JOIN qq_accounts q ON q.id = c.qq_account_id
), upd AS (
  UPDATE chats c SET dialog_pts = s.pts + d.rn
  FROM d JOIN sync_state s ON s.account_id = d.account_id
  WHERE c.id = d.id
  RETURNING d.account_id
)
UPDATE sync_state st
SET pts = st.pts + (SELECT count(*) FROM upd u WHERE u.account_id = st.account_id)
WHERE st.account_id IN (SELECT account_id FROM upd);
