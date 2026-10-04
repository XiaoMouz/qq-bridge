// PostgreSQL 的 text 和 jsonb 都存不了 NUL（U+0000）：jsonb 报 "unsupported Unicode escape sequence"，
// text 报 "invalid byte sequence"。QQ 消息里偶尔会带（卡片消息、某些昵称），入库前统一去掉。

/** 深拷贝并去掉所有字符串（含对象键）里的 NUL；没有 NUL 时原样返回同一个对象。 */
export function stripNul<T>(value: T): T {
  if (typeof value === 'string') return (value.includes('\0') ? value.replaceAll('\0', '') : value) as T;
  if (Array.isArray(value)) {
    let changed = false;
    const out = value.map((v) => {
      const s = stripNul(v);
      if (s !== v) changed = true;
      return s;
    });
    return (changed ? out : value) as T;
  }
  if (value && typeof value === 'object' && Object.getPrototypeOf(value) === Object.prototype) {
    let changed = false;
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      const key = stripNul(k);
      const s = stripNul(v);
      if (key !== k || s !== v) changed = true;
      out[key] = s;
    }
    return (changed ? out : value) as T;
  }
  return value;
}

/** 写进 jsonb 列用的 JSON 文本（去掉 NUL）。 */
export function pgJson(value: unknown): string {
  return JSON.stringify(stripNul(value));
}
