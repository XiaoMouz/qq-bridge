// 采样落盘前的脱敏工具。
// 通话相关负载里会出现鉴权票据、会话密钥，默认只保留结构摘要；消息采样保留原文（仅本机研究用）。

export const SENSITIVE_KEY =
  /(auth|ticket|token|sign|open_?key|^d2$|^a2$|cookie|session_?key|credential|password|secret|rkey)/i;

export type ValueSummary =
  | null
  | { type: 'undefined' | 'function' | 'symbol' | 'bigint' }
  | { type: 'binary'; length: number }
  | { type: 'array'; length: number; items: ValueSummary[] }
  | { type: 'object'; keys: { key: string; value: ValueSummary | '[REDACTED]' }[] }
  | { type: 'string'; length: number }
  | { type: 'number'; value: number }
  | { type: 'boolean'; value: boolean }
  | { type: 'truncated'; of: string };

/** 只保留类型与形状，不保留字符串内容；用于记录 AVSDK 事件而不泄露票据。 */
export function summarizeValue(value: unknown, depth = 0): ValueSummary {
  if (value === null) return null;
  if (value === undefined) return { type: 'undefined' };
  if (depth > 3) return { type: 'truncated', of: typeof value };
  if (value instanceof Uint8Array) return { type: 'binary', length: value.byteLength };
  if (Array.isArray(value)) {
    return {
      type: 'array',
      length: value.length,
      items: value.slice(0, 16).map((item) => summarizeValue(item, depth + 1)),
    };
  }
  switch (typeof value) {
    case 'object':
      return {
        type: 'object',
        keys: Object.keys(value as object)
          .slice(0, 48)
          .map((key) => ({
            key,
            value: SENSITIVE_KEY.test(key)
              ? ('[REDACTED]' as const)
              : summarizeValue((value as Record<string, unknown>)[key], depth + 1),
          })),
      };
    case 'string':
      return { type: 'string', length: value.length };
    case 'number':
      return { type: 'number', value };
    case 'boolean':
      return { type: 'boolean', value };
    case 'bigint':
      return { type: 'bigint' };
    case 'function':
      return { type: 'function' };
    default:
      return { type: 'symbol' };
  }
}

/** 深拷贝并把敏感键的值替换掉；保留其他内容。用于需要看到具体取值的研究采样。 */
export function redactDeep(value: unknown, depth = 0): unknown {
  if (depth > 12 || value === null || typeof value !== 'object') {
    return typeof value === 'bigint' ? value.toString() : value;
  }
  if (value instanceof Uint8Array) return { binaryLength: value.byteLength };
  if (Array.isArray(value)) return value.map((item) => redactDeep(item, depth + 1));
  const out: Record<string, unknown> = {};
  for (const [key, inner] of Object.entries(value as Record<string, unknown>)) {
    out[key] = SENSITIVE_KEY.test(key) ? '[REDACTED]' : redactDeep(inner, depth + 1);
  }
  return out;
}

/** URL 里的 rkey 等查询参数也是凭据，记录链接时去掉它们的值但保留参数名。 */
export function redactUrl(url: string): string {
  try {
    const parsed = new URL(url);
    for (const key of [...parsed.searchParams.keys()]) {
      if (SENSITIVE_KEY.test(key)) parsed.searchParams.set(key, '[REDACTED]');
    }
    return parsed.toString();
  } catch {
    return '[unparseable-url]';
  }
}
