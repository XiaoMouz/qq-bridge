#!/usr/bin/env node
// P0 采样分析：读取插件写出的 JSONL，回答 docs/design.md 第 7 节 P0 的几个问题。
//   node tools/analyze-capture.mjs [采样目录]
// 默认目录：deploy/data/napcat-config/plugins/napcat-plugin-qqbridge/capture
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = path.resolve(process.argv[2] ?? path.join(root, 'deploy/data/napcat-config/plugins/napcat-plugin-qqbridge/capture'));

function readStream(prefix) {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((name) => name.startsWith(`${prefix}-`) && name.endsWith('.jsonl'))
    .sort()
    .flatMap((name) =>
      fs
        .readFileSync(path.join(dir, name), 'utf8')
        .split('\n')
        .filter(Boolean)
        .map((line) => {
          try {
            return JSON.parse(line);
          } catch {
            return null;
          }
        })
        .filter(Boolean),
    );
}

const count = (map, key) => map.set(key, (map.get(key) ?? 0) + 1);
const print = (title, map) => {
  console.log(`\n## ${title}`);
  if (map.size === 0) console.log('  (无)');
  for (const [key, value] of [...map.entries()].sort((a, b) => b[1] - a[1])) console.log(`  ${key}: ${value}`);
};

const events = readStream('events').map((r) => r.event).filter(Boolean);
console.log(`# 采样目录 ${dir}`);
console.log(`事件总数：${events.length}`);

// 1. 事件类型分布
const kinds = new Map();
for (const e of events) count(kinds, [e.post_type, e.message_type ?? e.notice_type ?? e.request_type ?? e.meta_event_type, e.sub_type].filter(Boolean).join('/'));
print('事件类型', kinds);

// 2. 本人消息（message_sent）：包括本插件发出的，以及在手机等其他设备上发出的
const selfMessages = events.filter((e) => e.post_type === 'message_sent');
console.log(`\n## 本人发出的消息（message_sent）：${selfMessages.length} 条`);

// 3. seq 语义：同一会话内是否唯一、是否按到达顺序单调
const messages = events.filter((e) => (e.post_type === 'message' || e.post_type === 'message_sent') && e.raw);
const byPeer = new Map();
for (const e of messages) {
  const raw = e.raw;
  const key = `${raw.chatType}:${raw.peerUin || raw.peerUid}`;
  if (!byPeer.has(key)) byPeer.set(key, []);
  byPeer.get(key).push({ seq: BigInt(raw.msgSeq ?? 0), msgId: raw.msgId, self: e.post_type === 'message_sent', time: Number(raw.msgTime) });
}
console.log('\n## seq 语义（每个会话：消息数 / 重复 seq / 逆序到达 / 相邻 seq 最大间隔）');
for (const [key, list] of byPeer) {
  const seen = new Map();
  let duplicates = 0;
  let outOfOrder = 0;
  let maxSeq = -1n;
  let maxGap = 0n;
  let prev = null;
  for (const m of list) {
    if (seen.has(m.seq) && seen.get(m.seq) !== m.msgId) duplicates += 1;
    seen.set(m.seq, m.msgId);
    if (m.seq < maxSeq) outOfOrder += 1;
    if (m.seq > maxSeq) maxSeq = m.seq;
    if (prev !== null && m.seq > prev && m.seq - prev > maxGap) maxGap = m.seq - prev;
    prev = m.seq;
  }
  const selfCount = list.filter((m) => m.self).length;
  console.log(`  ${key}: ${list.length} 条（本人 ${selfCount}）/ 重复 ${duplicates} / 逆序 ${outOfOrder} / 最大间隔 ${maxGap}`);
}

// 4. 元素类型与媒体去重字段（md5 等）是否齐全
const elementKinds = new Map();
const mediaFields = new Map();
const MEDIA_KEYS = {
  picElement: ['md5HexStr', 'fileUuid', 'fileSize', 'picWidth', 'picHeight'],
  pttElement: ['md5HexStr', 'fileUuid', 'fileSize', 'duration'],
  videoElement: ['videoMd5', 'fileUuid', 'fileSize', 'fileTime'],
  fileElement: ['fileMd5', 'file10MMd5', 'fileSha', 'fileUuid', 'fileSize', 'fileName'],
  marketFaceElement: ['emojiId', 'key'],
};
for (const e of messages) {
  for (const el of e.raw.elements ?? []) {
    for (const [name, value] of Object.entries(el)) {
      if (!name.endsWith('Element') || value === null || value === undefined) continue;
      count(elementKinds, `${name} (elementType=${el.elementType})`);
      for (const field of MEDIA_KEYS[name] ?? []) {
        const v = value[field];
        count(mediaFields, `${name}.${field}: ${v === undefined || v === null || v === '' || v === '0' ? '缺失' : '有'}`);
      }
    }
  }
}
print('NT 元素类型', elementKinds);
print('媒体去重字段覆盖情况', mediaFields);

// 5. 媒体链接有效期
const probes = readStream('url-probes');
const probeStatus = new Map();
for (const p of probes) {
  const minutes = Math.round(p.offsetMs / 60000);
  count(probeStatus, `${p.segmentType} @${minutes}min → ${p.status ?? `ERR ${p.error}`}`);
}
print('媒体链接有效期探测（类型 @ 收到后分钟数 → HTTP 状态）', probeStatus);

// 6. 通话引擎事件
const avsdk = readStream('avsdk');
const avKinds = new Map();
for (const r of avsdk) count(avKinds, r.dir === 'kernel' ? `kernel ${r.name}` : `${r.dir} cmd=${r.command}`);
print('通话：内核回调 / AVSDK 输出 / 发给 AVSDK 的指令', avKinds);

const calls = readStream('calls');
if (calls.length) {
  console.log('\n## 通话阶段变化');
  for (const r of calls) console.log(`  ${r.capturedAt} ${r.call.callId?.slice(0, 8) ?? '-'} ${r.call.phase} caller=${r.call.callerUin ?? '?'} endReason=${r.call.endReason ?? '-'}`);
}
