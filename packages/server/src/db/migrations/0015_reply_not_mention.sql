-- 回复我的消息不再同时算 @我（QQ 的回复自带 "@被回复人"），按新规则重算各会话的未读分类，推进 dialog_pts 让客户端拿到新数字。
WITH acc AS (
  SELECT q.id AS qq_account_id, q.account_id, q.uin FROM qq_accounts q
), recalced AS (
  UPDATE chats c SET
    unread_mentions = (SELECT count(*)::int FROM messages m WHERE m.chat_id = c.id AND m.seq > c.read_inbox_max_seq
                         AND m.sender_uin <> a.uin AND m.state = 'normal' AND (m.flags & 32) <> 0 AND (m.flags & 256) = 0),
    unread_mention_all = (SELECT count(*)::int FROM messages m WHERE m.chat_id = c.id AND m.seq > c.read_inbox_max_seq
                         AND m.sender_uin <> a.uin AND m.state = 'normal' AND (m.flags & 64) <> 0 AND (m.flags & 288) = 0)
  FROM acc a
  WHERE a.qq_account_id = c.qq_account_id AND (c.unread_mentions > 0 OR c.unread_mention_all > 0)
  RETURNING c.id, a.account_id
), numbered AS (
  SELECT id, account_id, row_number() OVER (PARTITION BY account_id ORDER BY id) AS rn FROM recalced
), bumped AS (
  UPDATE chats c SET dialog_pts = s.pts + n.rn FROM numbered n JOIN sync_state s ON s.account_id = n.account_id
  WHERE c.id = n.id RETURNING n.account_id
)
UPDATE sync_state st SET pts = st.pts + (SELECT count(*) FROM bumped b WHERE b.account_id = st.account_id)
WHERE st.account_id IN (SELECT account_id FROM bumped);
