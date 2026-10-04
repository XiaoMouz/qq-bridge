// 媒体下载地址的来源。QQ 的链接带 rkey 会过期，过期或失效时要向上游（NapCat 插件）换新链接；
// 上游适配器实现 refresher，下载任务本身不关心具体是哪个框架。
export interface PendingRef {
  id: number;
  chatId: number;
  kind: string;
  url: string | null;
  urlExpiresAt: Date | null;
  size: number | null;
  name: string | null;
  mime: string | null;
  qqMd5: string | null;
  qqFileUuid: string | null;
  qqResourceId: string | null;
  qqFileId: string | null;
  /** 上游定位信息（见 IncomingMedia.locator）。 */
  locator: Record<string, unknown> | null;
  attempts: number;
}

/** 来源暂时不可用（例如上游插件不在线）：下载任务推迟重试，不消耗重试次数。 */
export class SourceUnavailableError extends Error {}

export interface FetchTarget {
  url: string;
  headers?: Record<string, string>;
}

export interface MediaSource {
  /**
   * 给出下载地址。forceRefresh = true 表示上一次的地址已经失效（403/404/410），需要向上游重新获取。
   * 返回 null 表示这份媒体在上游已经拿不到了。
   */
  resolve(ref: PendingRef, forceRefresh: boolean): Promise<FetchTarget | null>;
}

/** 优先用入库时记下的链接；过期或失效时调用 refresher 向上游换新链接（没有 refresher 就视为拿不到）。 */
export class StoredUrlSource implements MediaSource {
  constructor(private readonly refresher?: (ref: PendingRef) => Promise<string | null>) {}

  async resolve(ref: PendingRef, forceRefresh: boolean): Promise<FetchTarget | null> {
    const fresh = ref.url && (!ref.urlExpiresAt || ref.urlExpiresAt.getTime() > Date.now());
    if (!forceRefresh && fresh) return { url: ref.url! };
    if (!this.refresher) return null;
    const url = await this.refresher(ref);
    return url ? { url } : null;
  }
}
