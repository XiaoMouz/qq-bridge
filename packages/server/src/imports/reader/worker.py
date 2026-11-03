"""独立进程的分批扫描器；next/commit 两阶段，每批结果与游标在同一 SQLite 事务落盘。

sqlite3 属于任务状态库，APSW 只读加密源：pending-byte 修正不会污染状态库。
"""
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import sys
import time

VERSION = 6
MAIN = 'B31DB6832ED65FD588CF1F41904F3F33'
TABLE = re.compile(r'^msg_(1|3)_\d+$')
STOP = False


def stop(*_):
    global STOP
    STOP = True


def check():
    if STOP: raise InterruptedError('paused')


def dumps(value):
    # Node 26 readline 还会按 U+2028/U+2029 切行；必须转义，解析后正文保持原样。
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')


def connect(path):
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.executescript('''
      PRAGMA journal_mode=WAL;
      PRAGMA synchronous=FULL;
      PRAGMA cache_size=-8192;
      CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS inventory (name TEXT PRIMARY KEY, total INTEGER, first INTEGER, last INTEGER);
      CREATE TABLE IF NOT EXISTS stats (scope TEXT, kind TEXT, chat TEXT, sender_uid TEXT, sender_uin TEXT,
        count INTEGER, first INTEGER, last INTEGER, PRIMARY KEY(scope,kind,chat,sender_uid,sender_uin));
      CREATE TABLE IF NOT EXISTS seqs (seq TEXT PRIMARY KEY, count INTEGER);
      CREATE TABLE IF NOT EXISTS details (id INTEGER PRIMARY KEY, kind TEXT, value TEXT);
      CREATE INDEX IF NOT EXISTS details_kind ON details(kind,id);
      CREATE TABLE IF NOT EXISTS occurrences (id INTEGER PRIMARY KEY, kind TEXT, scope TEXT,
        time INTEGER, sender_uid TEXT, sender_uin TEXT, source TEXT, identifiers TEXT,
        link_status TEXT NOT NULL DEFAULT 'unscanned', payloads TEXT NOT NULL DEFAULT '[]');
      CREATE TABLE IF NOT EXISTS bindings (chat TEXT,sender_uid TEXT,sender_uin TEXT,chat_id INTEGER,status TEXT,user_id TEXT,evidence TEXT,count INTEGER,PRIMARY KEY(chat,sender_uid,sender_uin));
      CREATE TABLE IF NOT EXISTS aliases (res_id TEXT,algorithm TEXT,digest TEXT,PRIMARY KEY(res_id,algorithm,digest));
      CREATE INDEX IF NOT EXISTS aliases_digest ON aliases(algorithm,digest,res_id);
      CREATE TABLE IF NOT EXISTS objects (res_id TEXT PRIMARY KEY, sha256 TEXT, md5 TEXT, sha1 TEXT, size INTEGER,
        mime TEXT, status TEXT, target TEXT, source_res_id TEXT);
      CREATE INDEX IF NOT EXISTS objects_sha256 ON objects(sha256);
      CREATE INDEX IF NOT EXISTS objects_md5 ON objects(md5);
      CREATE INDEX IF NOT EXISTS objects_sha1 ON objects(sha1);
    ''')
    return db


class Reader:
    def __init__(self, cfg):
        from msg0 import open_backup
        self.cfg = cfg
        self.root = Path(cfg['backupPath']).resolve(strict=True)
        self.account = str(cfg['accountUin'])
        entries = json.loads(Path(cfg['keysPath']).read_text())
        self.keys = {}
        for entry in entries:
            name = Path(entry['file']).name
            if not re.fullmatch(r'[A-F0-9]{32}', name): raise ValueError('invalid_key_file_entry')
            key = entry['key'].encode('ascii')
            if len(key) != 16: raise ValueError('invalid_key_length')
            self.keys[name] = key
        if MAIN not in self.keys: raise ValueError('main_database_key_missing')
        self.signatures = {}
        for name in self.keys:
            p = self.root / name
            if p.is_symlink() or not p.is_file(): raise ValueError('source_database_missing_or_symlink')
            s = p.stat()
            self.signatures[name] = [str(s.st_size), str(s.st_mtime_ns), str(s.st_ino), str(s.st_dev)]
        self.source = open_backup(self.root / MAIN, self.keys[MAIN], cache_mb=16)
        # SQLite 页缓存与 VFS 页缓存分别限额；不能让默认缓存随大库增长。
        self.source.execute('PRAGMA cache_size=-8192')
        self.source.set_progress_handler(lambda: bool(STOP), 10000)
        self.tables = [r[0] for r in self.source.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") if TABLE.fullmatch(r[0])]
        if not self.tables: raise ValueError('message_tables_missing')
        self.db = connect(cfg['statePath'])
        current = self.db.execute('SELECT value FROM state WHERE id=1').fetchone()
        self.state = json.loads(current[0]) if current else {
            'version': VERSION, 'signatures': self.signatures, 'accountUin': self.account,
            'phase': 'inventory', 'tableIndex': 0, 'cursor': None, 'processed': 0,
            'totalMessages': 0, 'firstTime': None, 'lastTime': None, 'resourceTotal': None,
            'resourcesProcessed': 0, 'resourceCursor': 0, 'linkCursor': 0, 'linkedOccurrences': 0, 'counts': {}, 'elementCounts': {}, 'messageKinds': {},
            'mediaBytes': 0, 'mediaOccurrences': 0, 'nestedNodes': 0, 'parseErrors': 0,
            'subtypeCounts': {}, 'matches': {}, 'accountEvidence': 0, 'accountEvidenceConflicts': 0, 'sourceSeqConflictGroups': 0,
        }
        if self.state['version'] != VERSION or self.state['signatures'] != self.signatures or self.state['accountUin'] != self.account:
            raise ValueError('source_or_parser_changed_create_new_task')
        matching_version=cfg.get('matchingVersion',1)
        if current and self.state.get('matchingVersion',1)!=matching_version:
            raise ValueError('matching_policy_changed_create_new_task')
        self.state['matchingVersion']=matching_version
        self.media = None
        self.pending = False

    def unchanged(self):
        check()
        for name, sig in self.signatures.items():
            s = (self.root / name).stat()
            if [str(s.st_size), str(s.st_mtime_ns), str(s.st_ino), str(s.st_dev)] != sig:
                raise RuntimeError('source_database_changed')

    def count(self, group, key, n=1):
        d = self.state[group]
        d[key] = d.get(key, 0) + n

    def detail(self, kind, value):
        self.db.execute('INSERT INTO details(kind,value) VALUES (?,?)', (kind, dumps(value)))

    def stat(self, scope, kind, record):
        self.db.execute('''INSERT INTO stats VALUES (?,?,?,?,?,1,?,?)
          ON CONFLICT(scope,kind,chat,sender_uid,sender_uin) DO UPDATE SET
          count=count+1,first=min(first,excluded.first),last=max(last,excluded.last)''',
          (scope, kind, record.get('table', ''), record.get('senderUid') or '', record.get('senderUin') or '', record.get('time'), record.get('time')))

    def reply(self, table, element):
        from wire import parse_fields, first, values, text
        ref = element.get('reference', {})
        if not ref.get('time') or not ref.get('sequence'):
            return {'status': 'unresolved', 'reason': 'reference_time_or_sequence_missing'}
        candidates = self.source.execute(f'SELECT msgTime,msgSeq,msgRandom,extensionData FROM "{table}" WHERE msgTime=? LIMIT 513', (int(ref['time']),))
        matches, count, parse_errors = [], 0, 0
        for ts, seq, rnd, raw in candidates:
            count += 1
            try:
                envelope = parse_fields(raw or b'')
                body = parse_fields(first(envelope,5) or b'')
                header = parse_fields(first(envelope,1) or b'')
                uid = text(first(body,40020))
                uin = first(body,40033) or first(header,1)
                protocol_seq = first(body,40003 if table.startswith('msg_1_') else 40005)
                sender_ok = uid == ref['senderUid'] if ref.get('senderUid') else bool(ref.get('senderUin') not in (None,'0') and str(uin)==ref['senderUin'])
                if ref.get('senderUin') not in (None,'0') and uin and str(uin)!=ref['senderUin']: sender_ok=False
                if str(protocol_seq)==ref['sequence'] and sender_ok:
                    matches.append({'sourceKey':[table,ts,str(seq),str(rnd)],'localId':str(first(body,40001))})
            except (ValueError,TypeError): parse_errors += 1
        if count>=513 or parse_errors:
            return {'status':'unresolved','reason':'candidate_limit_or_unparsed_candidate'}
        if len(matches)==1: return {'status':'resolved','target':matches[0]}
        return {'status':'ambiguous' if matches else 'unresolved','reason':'multiple_targets' if matches else 'no_exact_source_target'}

    def add_record(self, record):
        from parser import walk, MEDIA
        service_record = bool(record['elements']) and all(e['type'] in (8,21,26) for e in record['elements'])
        if not service_record and record.get('sentSource') == 1 and record.get('sendStatus') == 2 and record.get('senderUin') not in (None, '0'):
            # 2026-11-03 全量扫描的通话记录也带本机来源位、但作者是对端，不能据它否定备份账号。
            # 普通记录只积累账号核验依据，矛盾单列；dry-run 不因未知本机来源语义丢弃整批。
            if record['senderUin'] == self.account:
                self.state['accountEvidence'] += 1
            else:
                self.state['accountEvidenceConflicts'] += 1
                self.detail('account_identity_conflict', {'sourceKey': record['sourceKey'], 'senderUid': record.get('senderUid'),
                    'senderUin': record.get('senderUin'), 'reason': 'local_source_flag_sender_differs'})
        kinds = set()
        for node in walk(record):
            node['table'] = record['table']
            scope = 'root' if not node['path'] else node['nodeScope']
            if node['path']: self.state['nestedNodes'] += 1
            self.stat(scope, '_message', node)
            for index, element in enumerate(node['elements']):
                kind = element['kind']
                if element['type']==7 and scope=='root':
                    element['sourceRelation']=self.reply(record['table'],element)
                    self.count('counts','reply_target:'+element['sourceRelation']['status'])
                self.count('counts', scope + ':' + kind)
                self.count('elementCounts', scope + ':' + str(element['type']))
                self.count('subtypeCounts',scope+':'+str(element['type'])+':'+str(element.get('subtype')))
                if element.get('app'):
                    self.count('counts',scope+':card_app:'+element['app'])
                    self.stat(scope,'card_app:'+element['app'],node)
                    if scope=='root': kinds.add('card_app:'+element['app'])
                self.stat(scope, kind, node)
                if scope == 'root': kinds.add(kind)
                if element['type'] in MEDIA:
                    self.state['mediaOccurrences'] += 1
                    ids = element.get('identifiers') or [{'algorithm': '', 'value': '', 'role': 'main'}]
                    source = dumps({'key': record['sourceKey'], 'path': node['path'], 'element': index})
                    self.db.execute("""INSERT INTO occurrences(kind,scope,time,sender_uid,sender_uin,source,identifiers)
                      VALUES (?,?,?,?,?,?,?)""", (kind,scope,node.get('time'),node.get('senderUid'),node.get('senderUin'),source,dumps(ids)))
        for kind in kinds: self.count('messageKinds', kind)
        self.db.execute('INSERT INTO seqs VALUES (?,1) ON CONFLICT(seq) DO UPDATE SET count=count+1', (record['seq'],))

    def next(self):
        from parser import parse_record, compact
        self.unchanged()
        if self.pending: raise ValueError('commit_required')
        self.db.execute('BEGIN IMMEDIATE')
        self.pending = True
        phase = self.state['phase']
        records, objects = [], []
        if phase == 'inventory':
            index = self.state['tableIndex']
            if index < len(self.tables):
                name = self.tables[index]
                n, lo, hi = self.source.execute(f'SELECT count(*),min(msgTime),max(msgTime) FROM "{name}"').fetchone()
                self.db.execute('INSERT OR REPLACE INTO inventory VALUES (?,?,?,?)', (name, n, lo, hi))
                self.state['totalMessages'] += n
                for k, v, fn in (('firstTime', lo, min), ('lastTime', hi, max)):
                    if v is not None: self.state[k] = v if self.state[k] is None else fn(self.state[k], v)
                self.state['tableIndex'] += 1
            else:
                self.state.update(phase='messages', tableIndex=0)
                self.state['resourceTotal'] = self.source.execute('SELECT count(*) FROM filecontext').fetchone()[0]
        elif phase == 'messages':
            index = self.state['tableIndex']
            if index >= len(self.tables):
                self.state.update(phase='media', cursor=None)
            else:
                name = self.tables[index]
                cursor = self.state['cursor']
                where = 'WHERE (msgTime,msgSeq,msgRandom) > (?,?,?)' if cursor else ''
                args = [int(x) for x in cursor] if cursor else []
                args.append(self.cfg['batchSize'])
                query = self.source.execute(f'''SELECT _id,msgTime,msgSeq,msgRandom,
                  CASE WHEN length(extensionData)<=16777216 THEN extensionData ELSE NULL END,NULL
                  FROM "{name}" {where} ORDER BY msgTime,msgSeq,msgRandom LIMIT ?''', args)
                started = time.monotonic()
                last, bytes_read = None, 0
                for row in query:
                    check()
                    rid, ts, seq, rnd, raw, extra = row
                    last = [ts, str(seq), str(rnd)]
                    try:
                        record = parse_record(name, row)
                    except (ValueError, TypeError, RecursionError) as e:
                        self.state['parseErrors'] += 1
                        self.detail('parse_error', {'sourceKey': [name, ts, str(seq), str(rnd)], 'reason': str(e)})
                    else:
                        self.add_record(record)
                        records.append(compact(record))
                    self.state['processed'] += 1
                    bytes_read += len(raw or b'')
                    if time.monotonic() - started > 0.5 or bytes_read >= 4 * 1024 * 1024: break
                if last:
                    self.state['cursor'] = last
                else:
                    for seq, n in self.db.execute('SELECT seq,count FROM seqs WHERE count>1'):
                        self.state['sourceSeqConflictGroups'] += 1
                        self.detail('source_seq_conflict', {'table': name, 'seq': seq, 'count': n})
                    self.db.execute('DELETE FROM seqs')
                    self.state.update(tableIndex=index+1, cursor=None)
        elif phase == 'media':
            from media import MediaReader
            if self.media is None: self.media = MediaReader(self.root, self.keys, self.unchanged)
            cursor = self.state['resourceCursor']
            query = self.source.execute('SELECT rowid,* FROM filecontext WHERE rowid>? ORDER BY rowid LIMIT ?', (cursor, min(self.cfg['batchSize'], 32)))
            columns = ['rowid']+[row[1] for row in self.source.execute('PRAGMA table_info(filecontext)')]
            started = time.monotonic()
            last = None
            for row in query:
                check()
                r = dict(zip(columns, row))
                last = r['rowid']
                obj = {'resourceId': str(r['rowid']), 'sourceResId': str(r['resId'])}
                try:
                    obj.update(self.media.inspect(r), status='available')
                    for field, algorithm in (('md5','md5'),('sha','sha1'),('sha3','sha256')):
                        value = r.get(field)
                        if isinstance(value,str) and re.fullmatch('[a-fA-F0-9]{'+str({'md5':32,'sha1':40,'sha256':64}[algorithm])+'}',value):
                            self.db.execute('INSERT OR IGNORE INTO aliases VALUES (?,?,?)',(str(r['rowid']),algorithm,value.lower()))
                    self.state['mediaBytes'] += obj['size']
                except (FileNotFoundError, ValueError, OSError) as e:
                    obj.update(status='unavailable', reason=str(e), size=r['filesize'])
                objects.append(obj)
                self.state['resourcesProcessed'] += 1
                self.state['resourceCursor'] = last
                if time.monotonic() - started >= 0.5: break
            if last is None: self.state['phase'] = 'linking'
        elif phase == 'linking':
            pending = self.db.execute('SELECT * FROM occurrences WHERE id>? ORDER BY id LIMIT ?',
              (self.state['linkCursor'], self.cfg['batchSize'])).fetchall()
            started=time.monotonic()
            for occurrence in pending:
                check()
                candidates={}
                for ident in json.loads(occurrence['identifiers']):
                    algorithm=ident['algorithm']
                    if algorithm not in ('md5','sha1','sha256'): continue
                    # 字段名严格白名单；值始终参数化，协议 hash 与实物 hash 的对应保留出处。
                    query=f'SELECT o.res_id,o.sha256,o.size,o.mime,o.status,o.target FROM objects o WHERE o.{algorithm}=? UNION SELECT o.res_id,o.sha256,o.size,o.mime,o.status,o.target FROM aliases a JOIN objects o ON o.res_id=a.res_id WHERE a.algorithm=? AND a.digest=? LIMIT 33'
                    for obj in self.db.execute(query,(ident['value'],algorithm,ident['value'])):
                        key=(obj['res_id'],ident['role'])
                        candidates[key]={**dict(obj),'role':ident['role'],'target':json.loads(obj['target'])}
                payloads=list(candidates.values())
                main={x['sha256'] for x in payloads if x['status']=='available' and x['role']=='main'}
                status='ambiguous' if len(payloads)>=33 or len(main)>1 else 'resolved' if len(main)==1 else 'preview_only' if payloads else 'unresolved'
                self.db.execute('UPDATE occurrences SET link_status=?,payloads=? WHERE id=?',(status,dumps(payloads),occurrence['id']))
                self.state['linkCursor']=occurrence['id']
                self.state['linkedOccurrences']+=1
                self.count('counts','media_link:'+status)
                if time.monotonic()-started>=0.5: break
            if not pending: self.state['phase']='done'
        return {'state': self.state, 'records': records, 'objects': objects}

    def commit(self, results):
        if not self.pending: raise ValueError('no_pending_batch')
        self.unchanged()
        for item in results.get('matches', []):
            self.count('matches', item['status'])
            self.count('matches', 'sender_' + item['sender']['status'])
            for element in item.get('serviceElements',[]):
                self.count('matches','service_element_'+element['status'])
                for person in element['participants']:
                    self.count('matches','service_participant_'+person['binding']['status'])
                    binding=person['binding']
                    self.db.execute('''INSERT INTO bindings VALUES (?,?,?,?,?,?,?,1) ON CONFLICT(chat,sender_uid,sender_uin) DO UPDATE SET status=excluded.status,user_id=excluded.user_id,evidence=excluded.evidence,count=count+1''',
                      (item['sourceKey'][0],person.get('uid') or '',person.get('userId') or '',item['chatId'],binding['status'],binding['userId'],binding['evidence']))
            for node in item.get('nodeBindings',[]):
                self.count('matches','nested_sender_'+node['binding']['status'])
            for reply in item.get('replies', []): self.count('matches', 'reply_' + reply['status'])
            # 新消息不复制全量正文，保留原库游标即可；重叠/冲突有逐条证据可分页。
            if item['status'] not in ('no_candidate','chat_unbound'): self.detail(item['status'], item)
            sender = item['sender']
            self.db.execute('''INSERT INTO bindings VALUES (?,?,?,?,?,?,?,1) ON CONFLICT(chat,sender_uid,sender_uin)
              DO UPDATE SET chat_id=excluded.chat_id,status=excluded.status,user_id=excluded.user_id,evidence=excluded.evidence,count=count+1''',
              (item['sourceKey'][0],item.get('sourceSenderUid') or '',item.get('sourceSenderUin') or '',item['chatId'],sender['status'],sender['userId'],sender['evidence']))
            for node in item.get('nodeBindings',[]):
                binding=node['binding']
                self.db.execute('''INSERT INTO bindings VALUES (?,?,?,?,?,?,?,1) ON CONFLICT(chat,sender_uid,sender_uin) DO UPDATE SET count=count+1''',
                  (item['sourceKey'][0],node.get('senderUid') or '',node.get('senderUin') or '',item['chatId'],binding['status'],binding['userId'],binding['evidence']))
        for item in results.get('objects', []):
            o = item['object']
            self.db.execute('INSERT OR REPLACE INTO objects VALUES (?,?,?,?,?,?,?,?,?)',
                (o['resourceId'], o.get('sha256'), o.get('md5'), o.get('sha1'), o.get('size'), o.get('mime'), o['status'], dumps(item['target']),o.get('sourceResId')))
            self.count('matches', 'media_' + item['target']['status'])
        self.state['updatedAt'] = time.time()
        self.db.execute('INSERT OR REPLACE INTO state VALUES (1,?)', (dumps(self.state),))
        self.db.commit()
        self.pending = False
        return self.state

    def close(self):
        self.db.close()
        self.source.close()
        if self.media: self.media.close()


def report(path, view, cursor, limit, kind):
    db = sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    if view == 'state':
        r = db.execute('SELECT value FROM state WHERE id=1').fetchone()
        result = json.loads(r[0]) if r else None
    elif view == 'details':
        rows = db.execute('SELECT id,kind,value FROM details WHERE id>? AND (?="" OR kind=?) ORDER BY id LIMIT ?', (cursor, kind, kind, limit)).fetchall()
        result = [{'id': r['id'], 'kind': r['kind'], **json.loads(r['value'])} for r in rows]
    elif view == 'statistics':
        result = [dict(r) for r in db.execute('SELECT rowid AS id,* FROM stats WHERE rowid>? AND (?="" OR kind=?) ORDER BY rowid LIMIT ?', (cursor, kind, kind, limit))]
    elif view == 'chats':
        result = [dict(r) for r in db.execute('SELECT rowid AS id,* FROM inventory WHERE rowid>? ORDER BY rowid LIMIT ?', (cursor, limit))]
    elif view == 'bindings':
        result = [dict(r) for r in db.execute('SELECT rowid AS id,* FROM bindings WHERE rowid>? ORDER BY rowid LIMIT ?',(cursor,limit))]
    elif view == 'media':
        result = [dict(r) for r in db.execute('SELECT rowid AS id,* FROM objects WHERE rowid>? ORDER BY rowid LIMIT ?', (cursor, limit))]
        for r in result: r['target'] = json.loads(r['target'])
    elif view in ('media_occurrences','media_links'):
        result=[dict(r) for r in db.execute('SELECT * FROM occurrences WHERE id>? ORDER BY id LIMIT ?',(cursor,limit))]
        for r in result:
            for field in ('source','identifiers','payloads'): r[field]=json.loads(r[field])
    elif view == 'media_summary':
        # 磁盘索引完成后精确连接；不把协议 MD5 当实际 SHA-256 去重。
        result = dict(db.execute('''SELECT
          count(*) AS resources,
          sum(CASE WHEN status='available' THEN 1 ELSE 0 END) AS available,
          count(DISTINCT sha256) AS unique_payloads,
          sum(size) AS bytes_with_missing_metadata
          FROM objects''').fetchone())
        result['reusableUniqueBytes']=db.execute("SELECT coalesce(sum(size),0) FROM (SELECT max(size) AS size FROM objects WHERE json_extract(target,'$.status')='reusable' GROUP BY sha256)").fetchone()[0]
        result['uniqueBytes'] = db.execute('SELECT coalesce(sum(size),0) FROM (SELECT max(size) AS size FROM objects WHERE sha256 IS NOT NULL GROUP BY sha256)').fetchone()[0]
        result['mediaTimeRange']=dict(db.execute('SELECT min(time) AS first,max(time) AS last,count(*) AS occurrences FROM occurrences').fetchone())
        result['sourceDuplicateResources']=max(0,(result['available'] or 0)-result['unique_payloads'])
        result['occurrenceLinks']={r['link_status']:r['n'] for r in db.execute('SELECT link_status,count(*) AS n FROM occurrences GROUP BY link_status')}
    else: raise ValueError('unknown_report')
    db.close()
    return result


def main():
    os.umask(0o077)
    if len(sys.argv) > 1 and sys.argv[1] == 'report':
        print(dumps(report(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6])))
        return
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    reader = None
    try:
        for line in sys.stdin:
            req = json.loads(line)
            command = req['command']
            if command == 'open':
                reader = Reader(req['config'])
                response = {'state': reader.state}
            elif command == 'next': response = reader.next()
            elif command == 'commit': response = {'state': reader.commit(req)}
            else: raise ValueError('unknown_command')
            print(dumps(response), flush=True)
    except InterruptedError:
        pass
    except Exception as e:
        # 不回传 key、路径、原始正文或 traceback；详细失败原因用受控错误码。
        print(dumps({'error': type(e).__name__, 'reason': str(e)[:200]}), flush=True)
        sys.exit(1)
    finally:
        if reader: reader.close()


if __name__ == '__main__': main()
