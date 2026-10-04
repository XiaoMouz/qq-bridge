// NapCat 的媒体下载地址：优先用入库时 OneBot 事件里给的现成链接；没有、过期或已失效（403/404/410）时，
// 带着 media_refs.locator 请插件现换一个（x.media_url）。插件不在线时抛 UpstreamOfflineError，
// 下载任务会推迟重试而不消耗重试次数。
import { sql } from 'drizzle-orm';
import { maybeOne, type Db } from '../../db/client.ts';
import type { FetchTarget, MediaSource, PendingRef } from '../../media/source.ts';
import { UpstreamOfflineError, type UpstreamHub } from '../hub.ts';

export class NapcatMediaSource implements MediaSource {
  private readonly accountOfChat = new Map<number, number>();

  constructor(
    private readonly db: Db,
    private readonly hub: Pick<UpstreamHub, 'call' | 'isConnected'>,
  ) {}

  async resolve(ref: PendingRef, forceRefresh: boolean): Promise<FetchTarget | null> {
    const fresh = ref.url && (!ref.urlExpiresAt || ref.urlExpiresAt.getTime() > Date.now());
    if (!forceRefresh && fresh) return { url: ref.url! };
    if (!ref.locator) return null; // 例如商城表情：固定链接，失效就是真没了
    const qqAccountId = await this.qqAccountOf(ref.chatId);
    if (!this.hub.isConnected(qqAccountId)) throw new UpstreamOfflineError(qqAccountId);
    const res = await this.hub.call<{ url?: string | null }>(qqAccountId, 'x.media_url', ref.locator);
    return res?.url ? { url: res.url } : null;
  }

  private async qqAccountOf(chatId: number): Promise<number> {
    const cached = this.accountOfChat.get(chatId);
    if (cached) return cached;
    const row = await maybeOne<{ qq_account_id: number }>(this.db, sql`select qq_account_id from chats where id = ${chatId}`);
    if (!row) throw new Error(`chat ${chatId} not found`);
    this.accountOfChat.set(chatId, row.qq_account_id);
    return row.qq_account_id;
  }
}
