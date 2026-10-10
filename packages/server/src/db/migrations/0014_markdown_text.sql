-- 机器人 markdown 消息的纯文本（预览、检索）改成去掉链接和标记后的文字，规则同 domain/markdownText。
-- 推进这些消息的 chat_pts，让已登录的客户端重新拉取。
CREATE TEMP TABLE md_fix ON COMMIT DROP AS
SELECT chat_id, seq,
  btrim(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(
              regexp_replace(text, '!\[[^\]]*\]\([^)]*\)', '[图片]', 'g'),
              '\[([^\]]*)\]\([^)]*\)', '\1', 'g'),
            '^[ \t]{0,3}#{1,6}[ \t]+', '', 'gn'),
          '^[ \t]{0,3}>[ \t]?', '', 'gn'),
        '(\*\*|__|~~|`)', '', 'g'),
      '\n{3,}', E'\n\n', 'g'),
    E' \t\n') AS new_text,
  row_number() OVER (PARTITION BY chat_id ORDER BY seq) AS rn
FROM messages
WHERE segments @> '[{"type":"markdown"}]';
--> statement-breakpoint
DELETE FROM md_fix f USING messages m WHERE m.chat_id = f.chat_id AND m.seq = f.seq AND m.text = f.new_text;
--> statement-breakpoint
WITH counts AS (
  SELECT chat_id, count(*) AS n FROM md_fix GROUP BY chat_id
), bumped AS (
  UPDATE chats c SET chat_pts = c.chat_pts + k.n FROM counts k WHERE c.id = k.chat_id
  RETURNING c.id, c.chat_pts - k.n AS base
)
UPDATE messages m SET text = f.new_text, version = b.base + f.rn
FROM md_fix f JOIN bumped b ON b.id = f.chat_id
WHERE m.chat_id = f.chat_id AND m.seq = f.seq;
