// 新版 QQ 的部分视频（多见于手机发的）fileUuid 形如 "NTV2COMPAT.<base64url>"：后面是一段 protobuf，
// 里面依次放着原件和缩略图各自的普通 fileUuid。NapCat 的 getVideoUrlPacket 直接把整串当 protobuf 解析，
// 会报 "illegal tag"。这里取出原件那一个（没有 field 2 的条目；缩略图条目 field 2 = 100）。

const PREFIX = 'NTV2COMPAT.';

export function unwrapFileUuid(uuid: string): string {
  if (!uuid.startsWith(PREFIX)) return uuid;
  try {
    const entries = readMessage(Buffer.from(uuid.slice(PREFIX.length), 'base64url'))
      .filter((f) => f.no === 1 && f.bytes)
      .map((f) => readMessage(f.bytes!));
    const pick = entries.find((e) => !e.some((f) => f.no === 2)) ?? entries[0];
    const inner = pick?.find((f) => f.no === 3 && f.bytes)?.bytes?.toString('utf8');
    return inner || uuid;
  } catch {
    return uuid;
  }
}

interface Field {
  no: number;
  value?: number;
  bytes?: Buffer;
}

function readMessage(buf: Buffer): Field[] {
  const out: Field[] = [];
  let i = 0;
  const varint = (): number => {
    let result = 0;
    let shift = 0;
    for (;;) {
      if (i >= buf.length) throw new Error('truncated varint');
      const b = buf[i++]!;
      result += (b & 0x7f) * 2 ** shift;
      shift += 7;
      if (b < 0x80) return result;
    }
  };
  while (i < buf.length) {
    const key = varint();
    const no = Math.floor(key / 8);
    const type = key & 7;
    if (type === 0) out.push({ no, value: varint() });
    else if (type === 2) {
      const len = varint();
      if (i + len > buf.length) throw new Error('truncated field');
      out.push({ no, bytes: buf.subarray(i, i + len) });
      i += len;
    } else throw new Error(`unsupported wire type ${type}`);
  }
  return out;
}
