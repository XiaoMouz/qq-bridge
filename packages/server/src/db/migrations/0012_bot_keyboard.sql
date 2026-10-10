-- 机器人消息：按钮（NT 元素 17）改记为 unknown/keyboard，预览里不显示；markdown 开头的空链接元数据去掉。
UPDATE messages m
SET segments = (
  SELECT jsonb_agg(
    CASE
      WHEN s->>'type' = 'unknown' AND s->>'original' = 'nt:17' THEN jsonb_set(s, '{original}', '"keyboard"')
      WHEN s->>'type' = 'markdown' THEN jsonb_set(s, '{content}', to_jsonb(regexp_replace(s->>'content', '^\[\]\([^)]*\)\s*', '')))
      ELSE s
    END
    ORDER BY ord
  )
  FROM jsonb_array_elements(m.segments) WITH ORDINALITY AS t(s, ord)
),
text = regexp_replace(replace(m.text, '[nt:17]', ''), '^\[\]\([^)]*\)\s*', '')
WHERE m.segments @> '[{"type":"unknown","original":"nt:17"}]'
   OR m.segments @> '[{"type":"markdown"}]';
