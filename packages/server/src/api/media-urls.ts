// 媒体下载用的短期签名链接：/media/<sha256>?exp=<unix秒>&sig=<HMAC>。
// 签发时校验账号确实引用了这份内容；链接本身就是有时效的访问凭证，AVPlayer 等不方便带请求头的场景也能用。
import { createHmac, timingSafeEqual } from 'node:crypto';

export class MediaUrlSigner {
  private readonly key: Buffer;

  constructor(
    secret: string,
    private readonly ttlSec = 3600,
  ) {
    if (Buffer.byteLength(secret, 'utf8') < 32) throw new Error('media URL secret must be at least 32 bytes');
    this.key = Buffer.from(secret, 'utf8');
  }

  sign(sha256: string, nowSec = Math.floor(Date.now() / 1000)): { url: string; expiresAt: number } {
    const expiresAt = nowSec + this.ttlSec;
    return { url: `/media/${sha256}?exp=${expiresAt}&sig=${this.signature(sha256, expiresAt)}`, expiresAt };
  }

  /** 带文件名的链接 /media/<sha256>/<文件名>?…：给需要靠扩展名识别类型的下载方（例如 NapCat 发送媒体时）。 */
  signNamed(sha256: string, name: string, nowSec = Math.floor(Date.now() / 1000)): { url: string; expiresAt: number } {
    const expiresAt = nowSec + this.ttlSec;
    const query = `exp=${expiresAt}&sig=${this.signature(sha256, expiresAt)}`;
    return { url: `/media/${sha256}/${encodeURIComponent(name)}?${query}`, expiresAt };
  }

  verify(sha256: string, exp: string | undefined, sig: string | undefined, nowSec = Math.floor(Date.now() / 1000)): boolean {
    if (!exp || !sig || !/^\d+$/.test(exp)) return false;
    const expiresAt = Number(exp);
    if (expiresAt < nowSec) return false;
    const expected = Buffer.from(this.signature(sha256, expiresAt));
    const supplied = Buffer.from(sig);
    return expected.length === supplied.length && timingSafeEqual(expected, supplied);
  }

  private signature(sha256: string, expiresAt: number): string {
    return createHmac('sha256', this.key).update(`${sha256}.${expiresAt}`).digest('base64url');
  }
}

/** 解析单段 Range 头（bytes=a-b / bytes=a- / bytes=-n）；不合法或多段时返回 'invalid'。 */
export function parseRange(header: string | undefined, size: number): { start: number; end: number } | null | 'invalid' {
  if (!header) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match) return 'invalid';
  const [, a = '', b = ''] = match;
  if (a === '' && b === '') return 'invalid';
  let start: number;
  let end: number;
  if (a === '') {
    const suffix = Number(b);
    if (suffix === 0) return 'invalid';
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(a);
    end = b === '' ? size - 1 : Math.min(Number(b), size - 1);
  }
  if (start > end || start >= size) return 'invalid';
  return { start, end };
}
