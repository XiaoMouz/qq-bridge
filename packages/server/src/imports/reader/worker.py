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

VERSION = 8
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
    from media_links import schema
    schema(db)
    db.execute('CREATE INDEX IF NOT EXISTS objects_source_resource ON objects(source_res_id)')
    if 'unavailable_reason' not in {r[1] for r in db.execute('PRAGMA table_info(objects)')}:
        db.execute('ALTER TABLE objects ADD COLUMN unavailable_reason TEXT')
    if 'special' not in {r[1] for r in db.execute('PRAGMA table_info(objects)')}:
        db.execute("ALTER TABLE objects ADD COLUMN special TEXT NOT NULL DEFAULT '{}'")
    columns={r[1] for r in db.execute('PRAGMA table_info(occurrences)')}
    if 'element_key' not in columns:db.execute('ALTER TABLE occurrences ADD COLUMN element_key TEXT')
    if 'resolution' not in columns:db.execute("ALTER TABLE occurrences ADD COLUMN resolution TEXT NOT NULL DEFAULT '{}'")
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
            'phase': 'inventory', 'referenceTableIndex': 0, 'referenceCursor': 0, 'nativeReferences': 0, 'nativeContextCursor': 0, 'nativeIdentityTableIndex': 0, 'nativeIdentityCursor': None, 'nativeIdentityRows': 0, 'nativeIdentityTableRows': 0, 'nativeFinalizeCursor': 0, 'nativeContextGroupsChecked': 0, 'nativeSourceContexts': {}, 'tableIndex': 0, 'cursor': None, 'processed': 0,
            'totalMessages': 0, 'firstTime': None, 'lastTime': None, 'resourceTotal': None,
            'resourcesProcessed': 0, 'resourceCursor': 0, 'linkCursor': 0, 'linkedOccurrences': 0, 'counts': {}, 'elementCounts': {}, 'messageKinds': {},
            'physicalCacheHits': 0, 'resourcesHashed': 0, 'mediaBytes': 0, 'mediaOccurrences': 0, 'nestedNodes': 0, 'parseErrors': 0,
            'subtypeCounts': {}, 'matches': {}, 'accountEvidence': 0, 'accountEvidenceConflicts': 0, 'sourceSeqConflictGroups': 0,
        }
        if self.state['version'] != VERSION or self.state['signatures'] != self.signatures or self.state['accountUin'] != self.account:
            raise ValueError('source_or_parser_changed_create_new_task')
        matching_version=cfg.get('matchingVersion',1)
        if current and self.state.get('matchingVersion',1)!=matching_version:
            raise ValueError('matching_policy_changed_create_new_task')
        self.state['matchingVersion']=matching_version
        self.catalog=None
        if cfg.get('physicalCatalogRoot'):
            from media import PhysicalCatalog
            self.catalog=PhysicalCatalog(cfg['physicalCatalogRoot'],self.signatures)
        self.media = None
        self.pending = False
        self.pending_stats={}
        self.pending_sequences={}

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

    def stat(self,scope,kind,record):
        key=(scope,kind,record.get('table',''),record.get('senderUid') or '',record.get('senderUin') or '')
        value=self.pending_stats.setdefault(key,[0,None,None]);value[0]+=1
        timestamp=record.get('time')
        if timestamp is not None:
            value[1]=timestamp if value[1] is None else min(value[1],timestamp)
            value[2]=timestamp if value[2] is None else max(value[2],timestamp)

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
                if element['type']==7 and scope=='root' and self.cfg.get('resolveSourceReplies',True):
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
                    self.add_media_occurrence(record,node,element,index,scope)
                # 引用元素内的原消息片段也能带媒体；与40900缓存节点分开记录位置。
                if element['type']==8 and element.get('recalledElements'):
                    self.add_recalled_media(record,node,element,index)
                if element['type']==7:
                    stack=[(q,(qi,),element.get('reference',{})) for qi,q in enumerate(element.get('snapshot',[]))]
                    while stack:
                        quote,quote_path,reference=stack.pop()
                        if quote['type'] in MEDIA:
                            self.state['mediaOccurrences']+=1
                            quote_node={**node,'time':int(reference['time']) if reference.get('time') not in (None,'0','') else None,
                              'senderUid':reference.get('senderUid'),'senderUin':reference.get('senderUin')}
                            self.count('counts','reply_quote:'+quote['kind']);self.stat('reply_quote',quote['kind'],quote_node)
                            self.add_media_occurrence(record,quote_node,quote,index,'reply_quote',quote_path)
                        if quote['type']==7:
                            stack.extend((q,(*quote_path,qi),quote.get('reference',{})) for qi,q in enumerate(quote.get('snapshot',[])))
        for kind in kinds: self.count('messageKinds', kind)
        seq=record['seq'];self.pending_sequences[seq]=self.pending_sequences.get(seq,0)+1

    def add_recalled_media(self,record,node,element,index):
        from media_links import MEDIA_TYPES
        original=element.get('grayTip',{}).get('revokeElement',{})
        fragments=element.get('recalledElements',[])
        root_node={**node,'elements':fragments,'senderUid':original.get('origMsgSenderUid'),'senderUin':None}
        stack=[(item,['recalledElements',i],root_node) for i,item in enumerate(fragments)]
        while stack:
            item,path,owner=stack.pop()
            if item['type'] in MEDIA_TYPES:
                self.state['mediaOccurrences']+=1;self.count('counts','recalled_original:'+item['kind']);self.stat('recalled_original',item['kind'],owner)
                self.add_media_occurrence(record,owner,item,index,'recalled_original',embedded_path=path)
            if item['type']==7:
                reference=item.get('reference',{})
                quoted={**owner,'senderUid':reference.get('senderUid'),'senderUin':reference.get('senderUin'),
                  'time':int(reference['time']) if reference.get('time') not in (None,'0','') else None}
                stack.extend((child,[*path,'snapshot',i],quoted) for i,child in enumerate(item.get('snapshot',[])))

    def add_media_occurrence(self,record,node,element,index,scope,quote_index=None,embedded_path=None):
        # 序列化元素去重存描述；每一次出现保留作者、时间、根消息及嵌套位置。
        descriptor={k:element.get(k) for k in ('type','kind','identifiers','diagnosticIdentifiers','size','builtinResource')}
        if element.get('filename'):descriptor['filename']=Path(element['filename']).name
        key=hashlib.sha256(dumps(descriptor).encode()).hexdigest()
        self.db.execute('INSERT OR IGNORE INTO media_elements(key,descriptor) VALUES (?,?)',(key,dumps(descriptor)))
        from media_links import MEDIA_TYPES
        expected=MEDIA_TYPES.get(element['type'])
        source={'key':record['sourceKey'],'path':node['path'],'element':index,'elementSha256':element['raw']['sha256'],
            'sameKindCount':sum(MEDIA_TYPES.get(x['type'])==expected and x['type']!=27 for x in node['elements'])}
        if embedded_path is not None:source['embeddedPath']=embedded_path
        if scope=='recalled_original':source['historicalOnly']=True
        if quote_index is not None:
            path=list(quote_index) if isinstance(quote_index,(tuple,list)) else [quote_index]
            source['quoteElement']=path[0];source['quotePath']=path
        self.db.execute("""INSERT INTO occurrences(kind,scope,time,sender_uid,sender_uin,source,identifiers,element_key)
          VALUES (?,?,?,?,?,?,?,?)""",(element['kind'],scope,node.get('time'),node.get('senderUid'),node.get('senderUin'),dumps(source),'[]',key))

    def native_context(self,ref):
        from wire import parse_fields,first,values,text
        table=ref['chat'];timestamp=ref['time']
        try:seq=int(ref['seq']);random=int(ref['random'])
        except (ValueError,TypeError):return {'status':'reference_identity_incomplete'}
        if timestamp is None:return {'status':'reference_timestamp_unavailable'}
        rows=list(self.source.execute(f'SELECT msgTime,msgSeq,msgRandom,extensionData FROM "{table}" WHERE msgTime=? AND msgSeq=? AND msgRandom=? LIMIT 2',
          (timestamp,seq,random)))
        variant=False
        if not rows:
            rows=list(self.source.execute(f'SELECT msgTime,msgSeq,msgRandom,extensionData FROM "{table}" WHERE msgTime BETWEEN ? AND ? AND msgSeq=? AND msgRandom=? LIMIT 2',
              (timestamp-2,timestamp+2,seq,random)))
            if not rows:return {'status':'reference_time_unmatched','reason':'pending_conversation_wide_native_key_scan'}
            variant=True
        if len(rows)!=1:return {'status':'source_message_ambiguous'}
        ts,sq,rnd,raw=rows[0]
        try:
            envelope=parse_fields(raw or b'');body_raw=first(envelope,5)
            if not isinstance(body_raw,bytes):return {'status':'source_message_unparsed'}
            body=parse_fields(body_raw);header=parse_fields(first(envelope,1) or b'')
            types=[];recall=[]
            for blob in values(body,40800,2):
                e=parse_fields(blob);ty=first(e,45002);types.append(ty)
                if ty==8 and first(e,45003)==1:recall.append({'operatorUid':text(first(e,47703)),'originalSenderUid':text(first(e,47704))})
            status='recalled_message' if recall else 'service_message' if types and all(t in (1,8,21,26) for t in types) and any(t in (8,21,26) for t in types) else 'source_message_present'
            result={'status':'timestamp_candidate' if variant else status,'messageKind':status,'sourceKey':[table,ts,str(sq),str(rnd)],
              'senderUid':text(first(body,40020)),'senderUin':str(first(body,40033) or first(header,1)) if first(body,40033) or first(header,1) else None,
              'elementTypes':types,'recalledPeople':recall,'historicalOnly':status!='source_message_present'}
            if variant:result['nativeTimestamp']=timestamp;result['deltaSeconds']=ts-timestamp;result['identityConfirmed']=False
            return result
        except (ValueError,TypeError):return {'status':'source_message_unparsed'}

    def next(self):
        from parser import parse_record, compact, MEDIA_MARKERS
        self.unchanged()
        if self.pending: raise ValueError('commit_required')
        self.db.execute('BEGIN IMMEDIATE')
        self.pending = True
        self.pending_stats={}
        self.pending_sequences={}
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
                self.state.update(phase='references', tableIndex=0)
                self.state['resourceTotal'] = self.source.execute('SELECT count(*) FROM filecontext').fetchone()[0]
        elif phase == 'references':
            from media_links import index_reference
            index=self.state['referenceTableIndex']
            if index>=len(self.tables):self.state['phase']='messages'
            else:
                chat=self.tables[index];table='res'+chat[3:]
                exists=self.source.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",(table,)).fetchone()
                if not exists:
                    self.detail('native_resource_table_missing',{'table':table})
                    self.state.update(referenceTableIndex=index+1,referenceCursor=0)
                else:
                    rows=self.source.execute(f'SELECT rowid,msgSeq,msgRandom,msgSubType,filePath,fileSize,extraData,resinfoId FROM "{table}" WHERE rowid>? ORDER BY rowid LIMIT ?',
                      (self.state['referenceCursor'],self.cfg['batchSize']))
                    last=None
                    for row in rows:
                        check();last=row[0]
                        status=index_reference(self.db,chat,row)
                        self.state['nativeReferences']+=1
                        if status!='ok':self.detail('native_metadata_unparsed',{'table':table,'row':last})
                    if last:self.state['referenceCursor']=last
                    else:self.state.update(referenceTableIndex=index+1,referenceCursor=0)
        elif phase == 'messages':
            index = self.state['tableIndex']
            if index >= len(self.tables):
                self.state.update(phase='native_context', cursor=None)
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
                    if self.cfg.get('mediaAuditOnly') and raw and not any(marker in raw for marker in MEDIA_MARKERS):
                        self.state['processed']+=1
                        self.state['rowsWithoutMediaSignature']=self.state.get('rowsWithoutMediaSignature',0)+1
                        self.state['mediaAuditOnly']=True
                        bytes_read+=len(raw)
                        if time.monotonic()-started>0.5 or bytes_read>=4*1024*1024:break
                        continue
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
        elif phase == 'native_context':
            rows=self.db.execute("""SELECT n.rowid AS id,n.chat,n.time,n.seq,n.random FROM native_refs n WHERE n.rowid>?
              AND NOT EXISTS(SELECT 1 FROM native_message_context c WHERE c.chat=n.chat AND c.time IS n.time AND c.seq=n.seq AND c.random=n.random)
              ORDER BY n.rowid LIMIT ?""",(self.state.get('nativeContextCursor',0),self.cfg['batchSize'])).fetchall()
            started=time.monotonic()
            for ref in rows:
                check();self.state['nativeContextCursor']=ref['id']
                found=self.db.execute('SELECT 1 FROM native_message_context WHERE chat=? AND time IS ? AND seq=? AND random=?',
                  (ref['chat'],ref['time'],ref['seq'],ref['random'])).fetchone()
                if found:continue
                context=self.native_context(ref)
                self.db.execute('INSERT INTO native_message_context VALUES (?,?,?,?,?,?)',
                  (ref['chat'],ref['time'],ref['seq'],ref['random'],context['status'],dumps(context)))
                self.state['nativeContextGroupsChecked']=self.state.get('nativeContextGroupsChecked',0)+1
                counts=self.state.setdefault('nativeSourceContexts',{});counts[context['status']]=counts.get(context['status'],0)+1
                if time.monotonic()-started>=0.5:break
            if not rows:
                self.state['nativeIdentityTables']=[r[0] for r in self.db.execute("SELECT DISTINCT chat FROM native_message_context WHERE status IN ('reference_time_unmatched','timestamp_candidate') ORDER BY chat")]
                self.state['phase']='native_identity_scan'
        elif phase == 'native_identity_scan':
            tables=self.state['nativeIdentityTables'];index=self.state.get('nativeIdentityTableIndex',0)
            if index>=len(tables):self.state['phase']='native_finalize'
            else:
                table=tables[index]
                if getattr(self,'identity_table',None)!=table:
                    self.identity_table=table
                    wanted=self.db.execute("SELECT seq,random FROM native_message_context WHERE chat=? AND status IN ('reference_time_unmatched','timestamp_candidate') LIMIT 20001",(table,)).fetchall()
                    self.identity_wanted={(r[0],r[1]) for r in wanted} if len(wanted)<=20000 else None
                cursor=self.state.get('nativeIdentityCursor');where='WHERE (msgTime,msgSeq,msgRandom)>(?,?,?)' if cursor else ''
                args=[int(x) for x in cursor] if cursor else [];args.append(10000)
                # 只读覆盖主键索引，逐行查遍该会话所有时间，不用“附近没有”冒充“全库没有”。
                rows=self.source.execute(f'SELECT msgTime,msgSeq,msgRandom FROM "{table}" {where} ORDER BY msgTime,msgSeq,msgRandom LIMIT ?',args)
                last=None
                for ts,seq,rnd in rows:
                    check();last=[ts,str(seq),str(rnd)]
                    wanted=(str(seq),str(rnd)) in self.identity_wanted if self.identity_wanted is not None else bool(self.db.execute("SELECT 1 FROM native_message_context WHERE chat=? AND seq=? AND random=? AND status IN ('reference_time_unmatched','timestamp_candidate') LIMIT 1",(table,str(seq),str(rnd))).fetchone())
                    if wanted:self.db.execute('INSERT OR IGNORE INTO native_identity_candidates VALUES (?,?,?,?)',(table,str(seq),str(rnd),ts))
                    self.state['nativeIdentityRows']=self.state.get('nativeIdentityRows',0)+1
                    self.state['nativeIdentityTableRows']=self.state.get('nativeIdentityTableRows',0)+1
                if last:self.state['nativeIdentityCursor']=last
                else:
                    self.db.execute('INSERT OR REPLACE INTO native_identity_coverage VALUES (?,?)',(table,self.state.get('nativeIdentityTableRows',0)))
                    self.state.update(nativeIdentityTableIndex=index+1,nativeIdentityCursor=None,nativeIdentityTableRows=0)
        elif phase == 'native_finalize':
            rows=self.db.execute("SELECT rowid AS id,* FROM native_message_context WHERE rowid>? AND status IN ('reference_time_unmatched','timestamp_candidate') ORDER BY rowid LIMIT ?",(self.state.get('nativeFinalizeCursor',0),self.cfg['batchSize'])).fetchall()
            for ref in rows:
                check();self.state['nativeFinalizeCursor']=ref['id']
                found=self.db.execute('SELECT time FROM native_identity_candidates WHERE chat=? AND seq=? AND random=? ORDER BY time LIMIT 513',(ref['chat'],ref['seq'],ref['random'])).fetchall()
                if found:
                    result={'status':'timestamp_candidate','identityConfirmed':False,'reason':'same_native_sequence_random_at_other_timestamp',
                        'candidateTimes':[r[0] for r in found],'nativeTimestamp':ref['time'],'entireConversationScanned':True}
                else:result={'status':'source_message_absent','reason':'native_sequence_random_absent_from_entire_conversation','entireConversationScanned':True}
                self.db.execute('UPDATE native_message_context SET status=?,context=? WHERE rowid=?',(result['status'],dumps(result),ref['id']))
            if not rows:
                self.state['nativeSourceContexts']={r[0]:r[1] for r in self.db.execute('SELECT status,count(*) FROM native_message_context GROUP BY status')}
                self.state['phase']='linking' if self.state['resourcesProcessed']==self.state['resourceTotal'] else 'media'
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
                from media_links import register_catalog_aliases
                register_catalog_aliases(self.db,str(r['resId']),r)
                try:
                    cached=self.catalog.get(str(r['resId'])) if self.catalog and r['dbfileResid'] else None
                    if cached and cached['size']==r['filesize'] and cached.get('mime')!='application/octet-stream':
                        obj.update(cached,status='available');self.state['physicalCacheHits']+=1
                    else:
                        physical=self.media.inspect(r)
                        obj.update(physical,status='available');self.state['resourcesHashed']+=1
                        if self.catalog and r['dbfileResid']:self.catalog.put(str(r['resId']),physical)
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
                from media_links import MediaLinker
                if not hasattr(self,'linker'):self.linker=MediaLinker(self.db)
                resolution=self.linker.resolve(occurrence)
                self.db.execute('UPDATE occurrences SET link_status=?,payloads=?,resolution=? WHERE id=?',
                  (resolution['status'],dumps(resolution['candidates']),dumps({k:v for k,v in resolution.items() if k!='candidates'}),occurrence['id']))
                self.state['linkCursor']=occurrence['id']
                self.state['linkedOccurrences']+=1
                self.count('counts','media_link:'+resolution['status'])
                if time.monotonic()-started>=0.5: break
            if not pending: self.state['phase']='done'
        return {'state': self.state, 'records': records, 'objects': objects}

    def commit(self, results):
        if not self.pending: raise ValueError('no_pending_batch')
        self.unchanged()
        self.db.executemany('''INSERT INTO stats VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(scope,kind,chat,sender_uid,sender_uin) DO UPDATE SET
          count=count+excluded.count,first=CASE WHEN first IS NULL THEN excluded.first WHEN excluded.first IS NULL THEN first ELSE min(first,excluded.first) END,
          last=CASE WHEN last IS NULL THEN excluded.last WHEN excluded.last IS NULL THEN last ELSE max(last,excluded.last) END''',
          [(*key,*value) for key,value in self.pending_stats.items()])
        self.db.executemany('INSERT INTO seqs VALUES (?,?) ON CONFLICT(seq) DO UPDATE SET count=count+excluded.count',self.pending_sequences.items())
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
            self.db.execute('INSERT OR REPLACE INTO objects(res_id,sha256,md5,sha1,size,mime,status,target,source_res_id,unavailable_reason,special) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                (o['resourceId'], o.get('sha256'), o.get('md5'), o.get('sha1'), o.get('size'), o.get('mime'), o['status'], dumps(item['target']),o.get('sourceResId'),o.get('reason'),dumps(o.get('special') or {})))
            self.count('matches', 'media_' + item['target']['status'])
        if self.catalog:self.catalog.commit()
        self.state['updatedAt'] = time.time()
        self.db.execute('INSERT OR REPLACE INTO state VALUES (1,?)', (dumps(self.state),))
        self.db.commit()
        self.pending = False
        return self.state

    def close(self):
        self.db.close()
        self.source.close()
        if self.media: self.media.close()
        if self.catalog:self.catalog.close()


def report(path, view, cursor, limit, kind, status=''):
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
    elif view == 'native_resources':
        conditions=['n.rowid>?'];arguments=[cursor]
        if kind:conditions.append('n.kind=?');arguments.append(kind)
        if status:conditions.append('c.status=?');arguments.append(status)
        arguments.append(limit)
        query="""SELECT n.rowid AS id,n.*,o.sha256,o.mime,o.status AS payload_status,o.unavailable_reason,
          c.status AS source_message_status,c.context FROM native_refs n LEFT JOIN objects o ON o.source_res_id=n.resource
          LEFT JOIN native_message_context c ON c.chat=n.chat AND c.time IS n.time AND c.seq=n.seq AND c.random=n.random WHERE """+' AND '.join(conditions)+' ORDER BY n.rowid LIMIT ?'
        result=[dict(r) for r in db.execute(query,arguments)]
        for row in result:row['context']=json.loads(row['context']) if row['context'] else None
    elif view == 'media':
        result = [dict(r) for r in db.execute('SELECT rowid AS id,* FROM objects WHERE rowid>? ORDER BY rowid LIMIT ?', (cursor, limit))]
        for r in result:
            r['target']=json.loads(r['target'])
            r['special']=json.loads(r.get('special') or '{}')
    elif view in ('media_occurrences','media_links'):
        conditions=['id>?'];arguments=[cursor]
        if status:conditions.append('link_status=?');arguments.append(status)
        if kind:conditions.append('kind=?');arguments.append(kind)
        arguments.append(limit)
        result=[dict(r) for r in db.execute('SELECT * FROM occurrences WHERE '+ ' AND '.join(conditions)+' ORDER BY id LIMIT ?',arguments)]
        for r in result:
            for field in ('source','identifiers','payloads','resolution'): r[field]=json.loads(r[field])
            r['resolution'].setdefault('candidates',r['payloads'])
            if r.get('element_key'):
                descriptor=db.execute('SELECT descriptor FROM media_elements WHERE key=?',(r['element_key'],)).fetchone()
                if descriptor:r['identifiers']=json.loads(descriptor[0]).get('identifiers',[])
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
        audit=db.execute('SELECT value FROM media_catalog_state WHERE id=1').fetchone()
        result['nativeSourceContexts']={row[0]:row[1] for row in db.execute('SELECT status,count(*) FROM native_message_context GROUP BY status')}
        result['associationAudit']=json.loads(audit[0]) if audit else None
        result['occurrenceLinks']={r['link_status']:r['n'] for r in db.execute('SELECT link_status,count(*) AS n FROM occurrences GROUP BY link_status')}
    else: raise ValueError('unknown_report')
    db.close()
    return result


def main():
    os.umask(0o077)
    if len(sys.argv) > 1 and sys.argv[1] == 'report':
        print(dumps(report(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6], sys.argv[7] if len(sys.argv)>7 else '')))
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
