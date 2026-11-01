import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CaptureWriter } from '../src/capture.js';

describe('CaptureWriter', () => {
  let tmpDir: string;
  let errors: unknown[];

  beforeEach(async () => {
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-capture-'));
    errors = [];
  });

  afterEach(async () => {
    vi.useRealTimers();
    await fs.rm(tmpDir, { recursive: true, force: true });
  });

  const list = async () => (await fs.readdir(path.join(tmpDir, 'capture'))).sort();

  it('只保留当天的采样文件', async () => {
    const dir = path.join(tmpDir, 'capture');
    await fs.mkdir(dir, { recursive: true });
    for (const name of ['events-2026-10-30.jsonl', 'avsdk-log-2026-10-31.jsonl', 'events-2026-11-01.jsonl', 'notes.txt']) {
      await fs.writeFile(path.join(dir, name), '{}\n');
    }
    vi.useFakeTimers({ toFake: ['Date'], now: new Date('2026-11-01T10:00:00Z') });

    const capture = new CaptureWriter(tmpDir, true, (error) => errors.push(error));
    capture.write('events', { n: 1 });
    await capture.flush();

    expect(await list()).toEqual(['events-2026-11-01.jsonl', 'notes.txt']);
    expect((await fs.readFile(path.join(dir, 'events-2026-11-01.jsonl'), 'utf8')).trim().split('\n')).toHaveLength(2);
    expect(errors).toEqual([]);
  });

  it('跨天后删掉前一天的文件', async () => {
    vi.useFakeTimers({ toFake: ['Date'], now: new Date('2026-11-01T23:59:00Z') });
    const capture = new CaptureWriter(tmpDir, true, (error) => errors.push(error));
    capture.write('events', { n: 1 });
    capture.write('url-probes', { n: 2 });
    await capture.flush();
    expect(await list()).toEqual(['events-2026-11-01.jsonl', 'url-probes-2026-11-01.jsonl']);

    vi.setSystemTime(new Date('2026-11-02T00:01:00Z'));
    capture.write('events', { n: 3 });
    await capture.flush();

    expect(await list()).toEqual(['events-2026-11-02.jsonl']);
    expect(errors).toEqual([]);
  });
});
