-- 0010–0012 只改了已存档的数据，没有推进同步序号，已登录的客户端不会重新拉这些行。
-- 这里给受影响的消息和所有会话行分配新的序号；逐行递增，按序号分页时不会跳过同号的行。
WITH touched AS (
  SELECT chat_id, seq, row_number() OVER (PARTITION BY chat_id ORDER BY seq) AS rn
  FROM messages
  WHERE segments @> '[{"type":"face"}]'
     OR segments @> '[{"type":"unknown","original":"keyboard"}]'
     OR segments @> '[{"type":"markdown"}]'
), counts AS (
  SELECT chat_id, count(*) AS n FROM touched GROUP BY chat_id
), bumped AS (
  UPDATE chats c SET chat_pts = c.chat_pts + k.n
  FROM counts k
  WHERE c.id = k.chat_id
  RETURNING c.id, c.chat_pts - k.n AS base
)
UPDATE messages m SET version = b.base + t.rn
FROM touched t JOIN bumped b ON b.id = t.chat_id
WHERE m.chat_id = t.chat_id AND m.seq = t.seq;
--> statement-breakpoint
WITH s AS (
  SELECT account_id, pts FROM sync_state FOR UPDATE
), d AS (
  SELECT c.id, q.account_id, row_number() OVER (PARTITION BY q.account_id ORDER BY c.id) AS rn
  FROM chats c JOIN qq_accounts q ON q.id = c.qq_account_id
), upd AS (
  UPDATE chats c SET dialog_pts = s.pts + d.rn
  FROM d JOIN s ON s.account_id = d.account_id
  WHERE c.id = d.id
  RETURNING d.account_id
)
UPDATE sync_state st
SET pts = st.pts + (SELECT count(*) FROM upd u WHERE u.account_id = st.account_id)
WHERE st.account_id IN (SELECT account_id FROM upd);
