// 媒体下载地址的来源。QQ 的链接带 rkey 会过期，过期或失效时要向上游（NapCat 插件）换新链接；
// 上游适配器实现 refresher，下载任务本身不关心具体是哪个框架。
export interface PendingRef {
  id: number;
  chatId: number;
  kind: string;
  /** qq_thumb = QQ 自带的缩略图（只取 spec=720 那档，存进消息的缩略图）；其余都是原件。 */
  role?: string;
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
  /** 客户端主动要的（点开看）：不受自动下载的大小上限限制。 */
  requested?: boolean;
}

/** 来源暂时不可用（例如上游插件不在线）：下载任务推迟重试，不消耗重试次数。 */
export class SourceUnavailableError extends Error {}

export interface FetchTarget {
  url: string;
  headers?: Record<string, string>;
}

export interface MediaSource {
  /**
   * 给出下载地址。forceRefresh = true 表示上一次的地址已经失效（400/401/403/404/410），需要向上游重新获取。
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

/**
 * QQ 图片链接换成缩略图档：spec=0 原图、720 长边约 1280px、198 长边约 300px（GIF 的缩略档只有第一帧）。
 * 认不出的链接返回 null。
 */
export function qqThumbUrl(url: string, spec = 720): string | null {
  try {
    const u = new URL(url);
    if (u.pathname.endsWith('/download') && u.searchParams.has('fileid')) {
      u.searchParams.set('spec', String(spec));
      return u.toString();
    }
    // 旧版链接 …/gchatpic_new/…/0?term=…：最后一段是档位。
    if (/\/(0|198|720)$/.test(u.pathname)) {
      u.pathname = u.pathname.replace(/\/(0|198|720)$/, `/${spec}`);
      return u.toString();
    }
  } catch {
    return null;
  }
  return null;
}
