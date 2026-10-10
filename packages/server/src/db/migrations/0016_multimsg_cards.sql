-- 用卡片（com.tencent.multimsg）发来的合并转发：以前记成卡片，改成能点开的聊天记录段（同 napcat/map.ts multiMsgArk）。
WITH cards AS (
  SELECT m.chat_id, m.seq, t.ord, (t.s->>'json')::jsonb AS card
  FROM messages m, jsonb_array_elements(m.segments) WITH ORDINALITY AS t(s, ord)
  WHERE m.segments @> '[{"type":"light_app","appName":"com.tencent.multimsg"}]'
    AND t.s->>'type' = 'light_app' AND t.s->>'appName' = 'com.tencent.multimsg'
    AND ((t.s->>'json')::jsonb #>> '{meta,detail,resid}') IS NOT NULL
), fixed AS (
  SELECT chat_id, seq, ord,
         jsonb_strip_nulls(jsonb_build_object(
           'type', 'forward',
           'forwardId', card #>> '{meta,detail,resid}',
           'title', card #>> '{meta,detail,source}',
           'summary', card #>> '{meta,detail,summary}',
           'preview', (SELECT jsonb_agg(n->>'text') FROM (SELECT n FROM jsonb_array_elements(card #> '{meta,detail,news}') n LIMIT 4) x)
         )) AS seg,
         row_number() OVER (PARTITION BY chat_id ORDER BY seq, ord) AS rn
  FROM cards
), counts AS (
  SELECT chat_id, count(*) AS n FROM fixed GROUP BY chat_id
), bumped AS (
  UPDATE chats c SET chat_pts = c.chat_pts + k.n FROM counts k WHERE c.id = k.chat_id
  RETURNING c.id, c.chat_pts - k.n AS base
)
UPDATE messages m
SET segments = jsonb_set(m.segments, ARRAY[(f.ord - 1)::text], f.seg),
    text = '[聊天记录] ' || coalesce(f.seg->>'title', ''),
    version = b.base + f.rn
FROM fixed f JOIN bumped b ON b.id = f.chat_id
WHERE m.chat_id = f.chat_id AND m.seq = f.seq;
