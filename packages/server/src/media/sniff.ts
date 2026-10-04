// 按内容判断媒体类型。QQ 下载接口给的 Content-Type 经常不对（视频给 application/octet-stream，AMR 语音给 audio/mp3），
// 而 iPhone 的播放器靠类型决定怎么解码，所以入库时以文件头为准。

/** 需要的文件头长度。 */
export const SNIFF_BYTES = 64;

export function sniffMime(head: Buffer): string | null {
  const ascii = (start: number, end: number) => head.subarray(start, end).toString('latin1');
  if (head.length >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return 'image/jpeg';
  if (head.length >= 8 && head.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (ascii(0, 4) === 'GIF8') return 'image/gif';
  if (ascii(0, 4) === 'RIFF' && ascii(8, 12) === 'WEBP') return 'image/webp';
  if (ascii(0, 4) === 'RIFF' && ascii(8, 12) === 'WAVE') return 'audio/wav';
  if (ascii(0, 2) === 'BM') return 'image/bmp';
  if (ascii(0, 6) === '#!AMR\n') return 'audio/amr';
  if (ascii(0, 9) === '#!AMR-WB\n') return 'audio/amr-wb';
  // QQ 的 SILK 语音前面常有一个 0x02 字节。
  if (ascii(0, 9) === '#!SILK_V3' || ascii(1, 10) === '#!SILK_V3') return 'audio/silk';
  if (ascii(0, 4) === 'OggS') return 'audio/ogg';
  if (ascii(0, 4) === 'fLaC') return 'audio/flac';
  if (ascii(0, 3) === 'ID3' || (head.length >= 2 && head[0] === 0xff && (head[1]! & 0xe0) === 0xe0 && (head[1]! & 0x06) !== 0)) {
    return 'audio/mpeg';
  }
  if (ascii(0, 4) === '%PDF') return 'application/pdf';
  if (ascii(0, 4) === 'PK\x03\x04') return 'application/zip';
  if (ascii(4, 8) === 'ftyp') return isoBrandMime(ascii(8, 12));
  return null;
}

/** ISO 媒体文件（MP4 / MOV / M4A / HEIC / AVIF）按主品牌区分。 */
function isoBrandMime(brand: string): string {
  switch (brand) {
    case 'heic':
    case 'heix':
    case 'hevc':
    case 'heim':
    case 'heis':
    case 'mif1':
    case 'msf1':
      return 'image/heic';
    case 'avif':
    case 'avis':
      return 'image/avif';
    case 'M4A ':
    case 'M4B ':
      return 'audio/mp4';
    case 'qt  ':
      return 'video/quicktime';
    default:
      return 'video/mp4';
  }
}

/** 文件头识别不出来时，是否沿用下载方/上传方声明的类型（只信具体的类型，不信 octet-stream 之类的笼统类型）。 */
export function chooseMime(sniffed: string | null, declared: string | null | undefined): string | null {
  if (sniffed) return sniffed;
  if (!declared || declared === 'application/octet-stream' || declared === 'binary/octet-stream') return null;
  return declared;
}
