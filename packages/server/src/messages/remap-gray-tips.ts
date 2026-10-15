// 以前认不得的 QQ 灰色提示（存成了 unknown nt:8）按原始消息重新映射成系统提示。
// 只改映射后整条都是认得的灰条的；原文仍在 raw 里，映射以后改进了可以重跑（已是系统提示的按新映射重写）。
import { sql } from 'drizzle-orm';
import { rows, type Db } from '../db/client.ts';
import type { IngestService } from '../ingest/service.ts';
import { mapRawMessage } from '../upstream/napcat/map.ts';
import type { NtRawMessage } from '../upstream/napcat/types.ts';

export async function remapGrayTips(db: Db, ingest: IngestService): Promise<{ scanned: number; rewritten: number }> {
  const found = await rows<{ chat_id: number; seq: number; uin: number; raw: NtRawMessage }>(
    db,
    sql`select m.chat_id, m.seq, q.uin, m.raw
          from messages m join chats c on c.id = m.chat_id join qq_accounts q on q.id = c.qq_account_id
         where m.raw is not null
           and (m.kind = 'service' or m.segments @> '[{"type":"unknown","original":"nt:8"}]'::jsonb)
         order by m.chat_id, m.seq`,
  );
  let rewritten = 0;
  for (const m of found) {
    const action = mapRawMessage(m.raw, { selfUin: Number(m.uin), source: 'backfill' });
    if (action.type !== 'message' || action.message.kind !== 'service') continue;
    if (await ingest.rewriteAsServiceTip(Number(m.chat_id), Number(m.seq), action.message.segments)) rewritten++;
  }
  return { scanned: found.length, rewritten };
}
