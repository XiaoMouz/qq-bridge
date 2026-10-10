// 图片派生版本：缩略图（约 320px）、预览图（约 1280px）、thumbhash 占位图（docs/design.md 4.6 / 6.3）。
// 客户端默认只拉这些小文件，原件按需下载，所以手机本地缓存可以保持很小。
import sharp, { type Metadata } from 'sharp';
import { rgbaToThumbHash } from 'thumbhash';

export const THUMB_PX = 320;
export const PREVIEW_PX = 1280;
/** 超过这个大小的图片不做派生（避免一次解码吃掉大量内存）。 */
export const MAX_DERIVE_BYTES = 50 * 1024 * 1024;

export interface ImageDerivatives {
  width: number;
  height: number;
  thumbhash: string;
  thumb: Buffer;
  /** 原图本身不大于缩略图时没有预览图。 */
  preview: Buffer | null;
}

export async function deriveImage(input: Buffer): Promise<ImageDerivatives | null> {
  let meta: Metadata;
  try {
    meta = await sharp(input, { animated: false }).metadata();
  } catch {
    return null; // 不是能解码的图片（或者是损坏的文件）
  }
  if (!meta.width || !meta.height) return null;
  // EXIF 方向 5–8 表示需要旋转 90°，宽高互换。
  const rotated = (meta.orientation ?? 1) >= 5;
  const width = rotated ? meta.height : meta.width;
  const height = rotated ? meta.width : meta.height;
  // failOn: 'none'：下载不完整的 JPEG 也照样出图（缺的部分是灰的），和 QQ 自己的显示一致。
  const base = () => sharp(input, { animated: false, failOn: 'none' }).rotate();

  const thumb = await base()
    .resize({ width: THUMB_PX, height: THUMB_PX, fit: 'inside', withoutEnlargement: true })
    .webp({ quality: 70 })
    .toBuffer();
  const preview =
    Math.max(width, height) > THUMB_PX
      ? await base()
          .resize({ width: PREVIEW_PX, height: PREVIEW_PX, fit: 'inside', withoutEnlargement: true })
          .webp({ quality: 80 })
          .toBuffer()
      : null;
  const { data, info } = await base()
    .resize({ width: 100, height: 100, fit: 'inside' })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const hash = rgbaToThumbHash(info.width, info.height, data);
  return { width, height, thumbhash: Buffer.from(hash).toString('base64'), thumb, preview };
}
