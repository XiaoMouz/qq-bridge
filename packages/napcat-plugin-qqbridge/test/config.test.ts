import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { loadConfig, readOverrides } from '../src/config.js';

let dir: string | null = null;
afterEach(() => {
  if (dir) fs.rmSync(dir, { recursive: true, force: true });
  dir = null;
});

function overridesFile(text: string): string {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qqbridge-cfg-'));
  const file = path.join(dir, 'qqbridge.env');
  fs.writeFileSync(file, text);
  return file;
}

const base = { QQBRIDGE_CONTROL_TOKEN: 'x'.repeat(32) };

describe('runtime switch file', () => {
  it('overrides call and research switches, last line wins, comments ignored', () => {
    const file = overridesFile('# 通话验证\nQQBRIDGE_CALLS=0\nQQBRIDGE_CALLS = 1\nQQBRIDGE_CAPTURE_AVSDK_VALUES=true\n');
    const cfg = loadConfig({ ...base, QQBRIDGE_CALLS: '0', QQBRIDGE_OVERRIDES_FILE: file });
    expect(cfg).toMatchObject({ calls: true, captureAvsdkValues: true, autoAccept: false });
  });

  it('cannot change connection settings or secrets', () => {
    const file = overridesFile('QQBRIDGE_UPSTREAM_URL=ws://evil.example/\nQQBRIDGE_CONTROL_TOKEN=short\n');
    expect(readOverrides(file)).toEqual({});
    const cfg = loadConfig({ ...base, QQBRIDGE_OVERRIDES_FILE: file });
    expect(cfg.upstreamUrl).toBeNull();
    expect(cfg.token).toBe(base.QQBRIDGE_CONTROL_TOKEN);
  });

  it('falls back to the environment when the file is missing', () => {
    const cfg = loadConfig({ ...base, QQBRIDGE_CALLS: '1', QQBRIDGE_OVERRIDES_FILE: '/nonexistent/qqbridge.env' });
    expect(cfg.calls).toBe(true);
  });
});
