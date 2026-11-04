"""补图用的对照表：QQ 协议 md5 → 备份里能读出的那份内容（apply.ts repairMedia）。

2026-11-04 实测（和余涛的聊天，2025-10-25 的合并转发）：手机把合并转发节点里的图存在原始群的资源表里，
msgSeq / msgRandom 为 0、msgType 4，路径 image_big/<协议 MD5>.png（手机重新压过的大图）和 image_thumbnail/<同名>，
内容哈希与协议 md5 对不上，预检按哈希和按消息都关联不上，但文件名就是协议 md5。
另一类是预检只关联到预览图的（原图手机没存）：用预览图。同一个 md5 有多份时优先原图，再取最大的一份。
用法：python media_names.py <scan.sqlite> <输出 jsonl>
"""
import json
import re
import sqlite3
import sys
from pathlib import Path

ROLE_RANK = {'original': 0, 'preview': 1, 'poster': 2}


def main(scan_path, out_path):
    db = sqlite3.connect(Path(scan_path).resolve().as_uri() + '?mode=ro', uri=True)
    avail = {r[0]: (r[1], r[2], r[3]) for r in db.execute(
        "SELECT source_res_id, sha256, size, mime FROM objects WHERE status='available' AND source_res_id IS NOT NULL AND size > 1")}
    best = {}

    def offer(md5, role, sha, size, mime, source):
        rank = (ROLE_RANK.get(role, 3), -(size or 0))
        if md5 not in best or rank < best[md5][0]:
            best[md5] = (rank, {'md5': md5, 'sha256': sha, 'size': size, 'mime': mime, 'role': role, 'source': source})

    for filename, resource, role in db.execute('SELECT filename, resource, role FROM native_refs WHERE filename IS NOT NULL'):
        m = re.fullmatch(r'([0-9A-Fa-f]{32})(?:\.\w+)?', filename.rsplit('/', 1)[-1])
        if m and resource in avail:
            offer(m.group(1).lower(), role, *avail[resource], 'filename')

    elements = {}
    for key, descriptor in db.execute('SELECT key, descriptor FROM media_elements'):
        d = json.loads(descriptor)
        elements[key] = [i['value'] for i in d.get('identifiers', []) if i.get('algorithm') == 'md5' and i.get('role') == 'main']
    for key, payloads in db.execute("SELECT element_key, payloads FROM occurrences WHERE link_status = 'preview_only'"):
        for c in json.loads(payloads or '[]'):
            if c.get('sha256') and c.get('role') in ('preview', 'poster'):
                obj = db.execute("SELECT size, mime FROM objects WHERE sha256=? AND status='available' LIMIT 1", (c['sha256'],)).fetchone()
                if obj:
                    for md5 in elements.get(key, []): offer(md5, c['role'], c['sha256'], obj[0], obj[1], 'preview_only')

    with open(out_path, 'w') as f:
        for _, v in best.values(): f.write(json.dumps(v) + '\n')
    print(json.dumps({'md5': len(best), 'byRole': {r: sum(1 for _, v in best.values() if v['role'] == r) for r in ROLE_RANK},
                      'bySource': {s: sum(1 for _, v in best.values() if v['source'] == s) for s in ('filename', 'preview_only')}}), flush=True)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
