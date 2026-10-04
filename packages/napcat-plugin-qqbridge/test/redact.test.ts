import { describe, expect, it } from 'vitest';
import { redactDeep, redactUrl, summarizeValue } from '../src/redact.js';

describe('redaction', () => {
  it('summarizes shapes without leaking string contents or sensitive keys', () => {
    const summary = summarizeValue({ uid: 'u_abc', authTicket: 'secret', nested: [1, 'x'] });
    expect(JSON.stringify(summary)).not.toContain('u_abc');
    expect(JSON.stringify(summary)).not.toContain('secret');
    expect(summary).toMatchObject({
      type: 'object',
      keys: [
        { key: 'uid', value: { type: 'string', length: 5 } },
        { key: 'authTicket', value: '[REDACTED]' },
        { key: 'nested', value: { type: 'array', length: 2 } },
      ],
    });
  });

  it('keeps values but masks sensitive keys in deep redaction', () => {
    expect(redactDeep({ a: 1, sessionKey: 'k', list: [{ cookie: 'c', ok: true }] })).toEqual({
      a: 1,
      sessionKey: '[REDACTED]',
      list: [{ cookie: '[REDACTED]', ok: true }],
    });
  });

  it('masks rkey in media URLs but keeps the parameter name', () => {
    const out = redactUrl('https://multimedia.nt.qq.com.cn/download?appid=1407&fileid=abc&rkey=SECRET');
    expect(out).toContain('rkey=%5BREDACTED%5D');
    expect(out).toContain('fileid=abc');
    expect(out).not.toContain('SECRET');
  });
});
