-- 小黄脸带上 QQ 给的表情名（faceElement.faceText，如 "/微笑"），客户端本地没有这个表情时显示名字。
-- 补已存档的消息：按 faceIndex 从原始元素里找名字。
UPDATE messages m
SET segments = (
  SELECT jsonb_agg(
    CASE
      WHEN s->>'type' = 'face' AND NOT s ? 'name' THEN
        s || COALESCE((
          SELECT jsonb_build_object('name', regexp_replace(e->'faceElement'->>'faceText', '^/', ''))
          FROM jsonb_array_elements(m.raw->'elements') e
          WHERE (e->'faceElement'->>'faceIndex') = s->>'faceId'
            AND COALESCE(e->'faceElement'->>'faceText', '') <> ''
          LIMIT 1
        ), '{}'::jsonb)
      ELSE s
    END
    ORDER BY ord
  )
  FROM jsonb_array_elements(m.segments) WITH ORDINALITY AS t(s, ord)
)
WHERE m.segments @> '[{"type":"face"}]'
  AND jsonb_typeof(m.raw->'elements') = 'array';
