import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { UpstreamQueue } from '../src/upstream/queue.js';

let dir: string;
beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qqbridge-queue-'));
});
afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

const cursors = (list: { c: number }[]) => list.map((e) => e.c);
const segments = () => fs.readdirSync(dir).filter((f) => f.startsWith('seg-')).sort();

describe('UpstreamQueue', () => {
  it('assigns increasing cursors and reads from any position, across segments and from memory', () => {
    const q = UpstreamQueue.open(dir, { segmentBytes: 200, memoryTail: 5 });
    for (let i = 1; i <= 30; i++) expect(q.append({ n: i }).c).toBe(i);
    expect(q.last).toBe(30);
    expect(q.first).toBe(1);
    expect(segments().length).toBeGreaterThan(3);

    expect(cursors(q.read(0, 4))).toEqual([1, 2, 3, 4]); // 从文件读
    expect(cursors(q.read(12, 100))).toEqual(Array.from({ length: 18 }, (_, i) => 13 + i)); // 跨分段
    expect(cursors(q.read(27, 10))).toEqual([28, 29, 30]); // 从内存读
    expect(q.read(30, 10)).toEqual([]);
    expect(q.read(5, 1)[0]).toMatchObject({ c: 6, e: { n: 6 } });
    q.close();
  });

  it('drops fully acknowledged segments but keeps the active one, and survives a restart', () => {
    const q = UpstreamQueue.open(dir, { segmentBytes: 200 });
    for (let i = 1; i <= 30; i++) q.append({ n: i });
    const before = segments().length;
    q.ack(20);
    expect(segments().length).toBeLessThan(before);
    expect(q.first).toBeLessThanOrEqual(21); // 未确认的一条都不能丢
    expect(cursors(q.read(20, 100))).toEqual(Array.from({ length: 10 }, (_, i) => 21 + i));
    q.ack(30);
    expect(segments()).toHaveLength(1); // 正在写的分段保留
    q.close();

    const reopened = UpstreamQueue.open(dir, { segmentBytes: 200 });
    expect(reopened.id).toBe(q.id);
    expect(reopened.acked).toBe(30);
    expect(reopened.last).toBe(30);
    expect(reopened.append({ n: 31 }).c).toBe(31);
    reopened.close();
  });

  it('truncates a half-written last line left by a crash', () => {
    const q = UpstreamQueue.open(dir);
    for (let i = 1; i <= 3; i++) q.append({ n: i });
    q.close();
    const file = path.join(dir, segments()[0]!);
    fs.appendFileSync(file, '{"c":4,"at":1,"e":{"n"');

    const reopened = UpstreamQueue.open(dir);
    expect(reopened.last).toBe(3);
    expect(reopened.append({ n: 4 }).c).toBe(4);
    expect(cursors(reopened.read(0, 10))).toEqual([1, 2, 3, 4]);
    reopened.close();
    expect(fs.readFileSync(file, 'utf8').trim().split('\n')).toHaveLength(4);
  });

  it('caps the total size by dropping the oldest unacknowledged segments, and reports the gap', () => {
    const dropped: { from: number; to: number }[] = [];
    const q = UpstreamQueue.open(dir, { segmentBytes: 300, maxBytes: 1000, onDrop: (d) => dropped.push(d) });
    for (let i = 1; i <= 100; i++) q.append({ payload: 'x'.repeat(40), n: i });
    expect(q.bytes).toBeLessThanOrEqual(1000 + 300);
    expect(dropped.length).toBeGreaterThan(0);
    expect(dropped[0]!.from).toBe(1);
    expect(q.first).toBe(dropped[dropped.length - 1]!.to + 1);
    expect(cursors(q.read(0, 1))).toEqual([q.first]);
    q.close();
  });

  it('starts a new queue id on reset without losing local events', () => {
    const q = UpstreamQueue.open(dir);
    for (let i = 1; i <= 3; i++) q.append({ n: i });
    q.ack(2);
    const oldId = q.id;
    q.reset();
    expect(q.id).not.toBe(oldId);
    expect(q.acked).toBe(0);
    expect(cursors(q.read(0, 10))).toEqual([1, 2, 3]);
    q.close();
    expect(UpstreamQueue.open(dir).id).toBe(q.id);
  });
});
