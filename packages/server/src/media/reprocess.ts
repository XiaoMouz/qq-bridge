// 补处理已存档的媒体（`cli media:reprocess`）：
// 1. 按文件头重新识别类型，纠正以前按 QQ 给的 Content-Type 存错的（视频 octet-stream、AMR 标成 mp3 等）；
// 2. 补生成派生版本（图片 / 视频封面缺缩略图、语音缺可播放版本），并更新引用它们的消息。
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { rows, type Db } from '../db/client.ts';
import type { IngestService } from '../ingest/service.ts';
import type { MediaProcessor } from './processing.ts';
import type { MediaService } from './service.ts';
import { SNIFF_BYTES, sniffMime } from './sniff.ts';

export interface ReprocessReport {
  mimeFixed: number;
  processed: number;
  messagesUpdated: number;
}

export async function reprocessMedia(
  deps: { db: Db; media: MediaService; processor: MediaProcessor; ingest: IngestService },
  logger?: Logger,
): Promise<ReprocessReport> {
  const report: ReprocessReport = { mimeFixed: 0, processed: 0, messagesUpdated: 0 };

  // 1. 重新识别类型（只读每个文件的开头）。
  let after = '';
  for (;;) {
    const page = await rows<{ sha256: string; mime: string | null }>(
      deps.db,
      sql`select sha256, mime from blobs where state = 'present' and sha256 > ${after} order by sha256 limit 500`,
    );
    if (page.length === 0) break;
    after = page[page.length - 1]!.sha256;
    for (const b of page) {
      const blob = await deps.media.getBlob(b.sha256);
      if (!blob) continue;
      const chunks: Buffer[] = [];
      for await (const chunk of await deps.media.openBlob(blob, { start: 0, end: SNIFF_BYTES - 1 })) chunks.push(chunk as Buffer);
      const sniffed = sniffMime(Buffer.concat(chunks));
      if (sniffed && sniffed !== b.mime) {
        await deps.db.execute(sql`update blobs set mime = ${sniffed} where sha256 = ${b.sha256}`);
        report.mimeFixed += 1;
      }
    }
  }

  // 2. 补派生版本：已存好、但还没有对应派生信息的内容。
  const pending = await rows<{ sha256: string; kind: string }>(
    deps.db,
    sql`select distinct on (r.sha256) r.sha256, r.kind
          from media_refs r join blobs b on b.sha256 = r.sha256
         where b.state = 'present' and r.kind in ('image', 'sticker', 'audio', 'video')
           and exists (
             select 1 from unnest(case r.kind when 'audio' then array['playable']
                                              when 'video' then array['thumb', 'playable']
                                              else array['thumb'] end) need(variant)
              where not exists (select 1 from blob_variants v where v.sha256 = r.sha256 and v.variant = need.variant))
         order by r.sha256`,
  );
  for (const { sha256, kind } of pending) {
    const derived = await deps.processor.process(sha256, kind);
    if (Object.keys(derived).length === 0) continue;
    report.processed += 1;
    report.messagesUpdated += await deps.ingest.patchMediaBySha(sha256, derived);
  }
  logger?.info(report, 'media reprocess finished');
  return report;
}
