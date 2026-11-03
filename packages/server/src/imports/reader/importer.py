"""备份导入的读取端：按会话、按主键顺序读出备份消息，转成 NT 原始消息交给服务端（imports/apply.ts）。

和 worker.py 一样走 stdin/stdout 的逐行 JSON：open → next → commit（游标与本批写库成功后才前进）；
extract 把一份媒体内容解密写到服务端给的暂存路径，由服务端照常入媒体库（去重、派生版本）。
媒体在备份里对应哪个文件用预检（worker.py 的 scan.sqlite）的关联结论，不在这里重新判断。
"""
import base64
import hashlib
import json
from pathlib import Path
import re
import signal
import sqlite3
import sys

from msg0 import open_backup
from parser import parse_record, children, compact
from ntraw import nt_raw, nt_node, element
from wire import parse_fields, first, values

MAIN = 'B31DB6832ED65FD588CF1F41904F3F33'
TABLE = re.compile(r'^msg_(1|3)_\d+$')
SERVICE = (8, 21, 26)
STOP = False


def stop(*_):
    global STOP
    STOP = True


def dumps(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')


def has_forward(elements):
    return any(e['type'] == 16 or (e['type'] == 10 and e.get('app') == 'com.tencent.multimsg') for e in elements)


class Exporter:
    def __init__(self, cfg):
        self.root = Path(cfg['backupPath']).resolve(strict=True)
        self.keys = {}
        for entry in json.loads(Path(cfg['keysPath']).read_text()):
            name = Path(entry['file']).name
            if not re.fullmatch(r'[A-F0-9]{32}', name): raise ValueError('invalid_key_file_entry')
            self.keys[name] = entry['key'].encode('ascii')
        self.source = open_backup(self.root / MAIN, self.keys[MAIN], cache_mb=32)
        self.source.set_progress_handler(lambda: bool(STOP), 10000)
        only = set(cfg.get('tables') or [])
        self.tables = [r[0] for r in self.source.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
                       if TABLE.fullmatch(r[0]) and (not only or r[0] in only)]
        self.scan = sqlite3.connect(Path(cfg['scanPath']).resolve().as_uri() + '?mode=ro', uri=True)
        self.state = sqlite3.connect(cfg['statePath'])
        self.state.executescript('''
          PRAGMA journal_mode=WAL;
          CREATE TABLE IF NOT EXISTS cursors (tbl TEXT PRIMARY KEY, time INTEGER, seq INTEGER, random INTEGER, done INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE IF NOT EXISTS occ (tbl TEXT, time INTEGER, seq TEXT, random TEXT, path TEXT, element INTEGER,
            status TEXT, sha256 TEXT);
          CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
        ''')
        self.index_occurrences()
        self.media = None

    def index_occurrences(self):
        """预检的 occurrences 没按消息建索引：第一次打开时抄一份 (消息, 节点路径, 元素) → 关联结论。
        引用快照、撤回原文里的媒体不随消息导入（它们是别的消息的副本），只取消息本身和合并转发节点里的。"""
        if self.state.execute("SELECT 1 FROM meta WHERE k='occ_indexed'").fetchone(): return
        self.state.execute('DELETE FROM occ')
        batch = []
        for source, status, resolution in self.scan.execute('SELECT source, link_status, resolution FROM occurrences'):
            s = json.loads(source)
            if 'quoteElement' in s or 'embeddedPath' in s: continue
            table, ts, seq, rnd = s['key']
            sha = json.loads(resolution or '{}').get('preferredSha256') if status == 'resolved' else None
            batch.append((table, ts, str(seq), str(rnd), '.'.join(map(str, s['path'])), s['element'], status, sha))
            if len(batch) >= 50000:
                self.state.executemany('INSERT INTO occ VALUES (?,?,?,?,?,?,?,?)', batch); batch = []
        if batch: self.state.executemany('INSERT INTO occ VALUES (?,?,?,?,?,?,?,?)', batch)
        self.state.execute('CREATE INDEX IF NOT EXISTS occ_message ON occ(tbl,time,seq,random)')
        self.state.execute("INSERT OR REPLACE INTO meta VALUES ('occ_indexed','1')")
        self.state.commit()

    def media_of(self, table, ts, seq, rnd):
        out = {}
        for path, element, status, sha in self.state.execute(
                'SELECT path, element, status, sha256 FROM occ WHERE tbl=? AND time=? AND seq=? AND random=?', (table, ts, str(seq), str(rnd))):
            out[f'{path}:{element}'] = {'status': status, 'sha256': sha}
        return out

    def cursor(self, table):
        r = self.state.execute('SELECT time, seq, random, done FROM cursors WHERE tbl=?', (table,)).fetchone()
        return (r[0], r[1], r[2]) if r and r[0] is not None else None, bool(r and r[3])

    def next(self, limit):
        for table in self.tables:
            cur, done = self.cursor(table)
            if done: continue
            where = 'WHERE (msgTime,msgSeq,msgRandom) > (?,?,?)' if cur else ''
            rows = list(self.source.execute(f'''SELECT _id,msgTime,msgSeq,msgRandom,extensionData,NULL FROM "{table}" {where}
                ORDER BY msgTime,msgSeq,msgRandom LIMIT ?''', [*(cur or ()), limit]))
            if not rows: return {'table': table, 'records': [], 'cursor': None, 'tableDone': True}
            return {'table': table, 'records': [self.record(table, row) for row in rows],
                    'cursor': list(rows[-1][1:4]), 'tableDone': False}
        return {'table': None, 'records': [], 'cursor': None, 'tableDone': True, 'finished': True}

    def record(self, table, row):
        _, ts, seq, rnd, raw, _ = row
        key = [table, ts, str(seq), str(rnd)]
        try:
            rec = parse_record(table, row)
        except (ValueError, TypeError, RecursionError) as e:
            return {'sourceKey': key, 'kind': 'unparsed', 'reason': str(e)[:200]}
        types = [e['type'] for e in rec['elements']]
        kind = ('call' if types and all(t == 21 for t in types) else 'tip' if types and all(t in SERVICE for t in types)
                else 'message' if rec['sendStatus'] == 2 else 'unsent')
        out = {'sourceKey': key, 'kind': kind, 'scene': rec['scene'], 'sendStatus': rec['sendStatus'],
               'nt': nt_raw(table, row, rec), 'media': self.media_of(table, ts, seq, rnd)}
        if kind in ('tip', 'call'):
            out['tips'] = [{'type': e['type'], 'kind': e['kind'], 'grayTip': e.get('grayTip'), 'savedText': e.get('savedText'),
                            'interaction': e.get('interaction'), 'dynamic': e.get('dynamic'),
                            # 撤回提示里存的原消息片段：转成 NT 元素，补写「已撤回」的消息时带上原文。
                            'recalled': [element(frag, rec['scene'], None, i) for i, frag in
                                         enumerate(values(parse_fields(base64.b64decode(e['raw']['base64'])), 47710, 2))] if e.get('recalledElements') else []}
                           for e in rec['elements']]
        # 40900 子节点既可能是合并转发的内容，也可能是被回复消息的本地缓存（2026-11-04 实测：一批 400 条里 34 条
        # 带子节点的全是回复）；只有本身含合并转发元素的消息，子节点才是转发内容。
        if kind == 'message' and rec['nodes'] and has_forward(rec['elements']):
            out['forward'] = self.forward_nodes(raw, rec, table)
        # 匹配器（imports/matcher.ts）用解析后的记录判断是不是生产已有的同一条；节点只用于绑定发送者，导入时不需要。
        out['record'] = compact({**rec, 'nodes': []})
        return out

    def forward_nodes(self, raw, rec, table):
        """合并转发节点（不含引用快照），按 forward_bundles 的 path（"0.2"）逐层展开；media 的键是 节点路径:元素下标。"""
        envelope = parse_fields(raw or b'')
        body = first(envelope, 5)
        chat_type = first(parse_fields(body), 40010)
        peer = table.split('_')[2]

        def level(body_bytes, parsed_nodes, path):
            raws = list(children(parse_fields(body_bytes)))
            nodes, nested = [], []
            for i, (node_raw, node) in enumerate(zip(raws, parsed_nodes)):
                if node.get('nodeScope') != 'forward_node': continue
                index = len(nodes)
                nodes.append({'sourcePath': list(node['path']), 'nt': nt_node(node_raw, node, rec['scene'], peer, chat_type)})
                if node['nodes'] and has_forward(node['elements']): nested.extend(level(node_raw, node['nodes'], [*path, index]))
            return ([{'path': '.'.join(map(str, path)), 'nodes': nodes}] if nodes else []) + nested
        return level(body, rec['nodes'], [])

    def commit(self, table, cursor, table_done):
        if table_done:
            self.state.execute('INSERT INTO cursors(tbl,done) VALUES (?,1) ON CONFLICT(tbl) DO UPDATE SET done=1', (table,))
        else:
            self.state.execute('''INSERT INTO cursors(tbl,time,seq,random,done) VALUES (?,?,?,?,0)
              ON CONFLICT(tbl) DO UPDATE SET time=excluded.time, seq=excluded.seq, random=excluded.random''', (table, *cursor))
        self.state.commit()
        return {'ok': True}

    def extract(self, sha256, path):
        """按预检算出的 sha256 找一个可读的源资源，解密写到 path，重新校验 sha256。"""
        from media import MediaReader
        if self.media is None: self.media = MediaReader(self.root, self.keys, lambda: None)
        rows = self.scan.execute("SELECT res_id FROM objects WHERE sha256=? AND status='available' ORDER BY res_id LIMIT 4", (sha256,)).fetchall()
        if not rows: raise FileNotFoundError('payload_not_in_scan')
        columns = ['rowid'] + [r[1] for r in self.source.execute('PRAGMA table_info(filecontext)')]
        for (res_id,) in rows:
            r = dict(zip(columns, self.source.execute('SELECT rowid,* FROM filecontext WHERE rowid=?', (int(res_id),)).fetchone()))
            digest = hashlib.sha256(); size = 0
            try:
                with open(path, 'wb') as f:
                    for block in self.media.stream(r):
                        if STOP: raise InterruptedError('paused')
                        digest.update(block); size += len(block); f.write(block)
            except (FileNotFoundError, ValueError, OSError):
                continue
            if digest.hexdigest() == sha256: return {'sha256': sha256, 'size': size}
        raise ValueError('payload_hash_mismatch')

    def close(self):
        self.source.close(); self.scan.close(); self.state.close()
        if self.media: self.media.close()


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    exporter = None
    try:
        for line in sys.stdin:
            req = json.loads(line)
            command = req['command']
            if command == 'open':
                exporter = Exporter(req['config']); response = {'tables': len(exporter.tables)}
            elif command == 'next': response = exporter.next(int(req.get('limit', 200)))
            elif command == 'commit': response = exporter.commit(req['table'], req.get('cursor'), bool(req.get('tableDone')))
            elif command == 'meta_get':
                row = exporter.state.execute('SELECT v FROM meta WHERE k=?', (req['key'],)).fetchone()
                response = {'value': json.loads(row[0]) if row else None}
            elif command == 'meta_set':
                exporter.state.execute('INSERT OR REPLACE INTO meta VALUES (?,?)', (req['key'], dumps(req['value']))); exporter.state.commit()
                response = {'ok': True}
            elif command == 'media_list':
                # 媒体预取（apply.ts prefetchMedia）：预检里唯一对应到文件的内容，按 sha256 首位十六进制分片，sha256 顺序分页。
                exporter.state.execute('CREATE INDEX IF NOT EXISTS occ_sha ON occ(sha256) WHERE sha256 IS NOT NULL')
                shard, shards = int(req['shard']), int(req['shards'])
                rows = exporter.state.execute("SELECT DISTINCT sha256 FROM occ WHERE sha256 > ? ORDER BY sha256 LIMIT ?",
                                              (req.get('after') or '', int(req.get('limit', 500)) * shards)).fetchall()
                items = []
                for (sha,) in rows:
                    if int(sha[0], 16) % shards != shard: continue
                    mime = exporter.scan.execute('SELECT mime FROM objects WHERE sha256=? LIMIT 1', (sha,)).fetchone()
                    items.append({'sha256': sha, 'mime': mime[0] if mime else None})
                response = {'items': items, 'after': rows[-1][0] if rows else None}
            elif command == 'extract':
                # 单个媒体读不出来不影响整个导入：消息照常写，媒体记为拿不到。
                try: response = exporter.extract(req['sha256'], req['path'])
                except (FileNotFoundError, ValueError, OSError) as e: response = {'missing': str(e)[:200]}
            else: raise ValueError('unknown_command')
            print(dumps(response), flush=True)
    except InterruptedError:
        pass
    except Exception as e:
        # 不回传 key、路径、原始正文或 traceback。
        print(dumps({'error': type(e).__name__, 'reason': str(e)[:200]}), flush=True)
        sys.exit(1)
    finally:
        if exporter: exporter.close()


if __name__ == '__main__': main()
