"""原生资源引用、实际字节和专用标识联合定位；所有命中保留角色与证据。"""
import hashlib
import json
from pathlib import Path
import re
from collections import OrderedDict

HASH = re.compile(r'(?<![0-9a-fA-F])([0-9a-fA-F]{64}|[0-9a-fA-F]{40}|[0-9a-fA-F]{32})(?![0-9a-fA-F])')
UUID = re.compile(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
MEDIA_TYPES = {2:'image',3:'file',4:'audio',5:'video',11:'image',15:'image',23:'file',27:'image',49:'video'}


def classify(subtype, path):
    # 2026-11-03 核对全部585854条资源引用与原iPhone路径、实际MIME。
    known={1:('image','original'),3:('image','preview'),4:('video','original'),
           7:('image','poster'),17:('image','poster'),15:('audio','original'),12:('image','preview')}
    if subtype in known:return known[subtype]
    suffix=Path(path or '').suffix.lower()
    kind='image' if suffix in ('.jpg','.jpeg','.png','.gif','.webp','.heic','.heif','.bmp','.tif','.tiff','.avif') else 'video' if suffix in ('.mp4','.mov','.m4v','.webm','.mkv','.avi','.3gp') else 'audio' if suffix in ('.amr','.silk','.slk','.m4a','.aac','.mp3','.wav','.ogg','.flac','.opus') else 'file'
    return kind,'original'


def schema(db):
    db.executescript('''
      CREATE TABLE IF NOT EXISTS native_refs(chat TEXT,ref_row INTEGER,seq TEXT,random TEXT,time INTEGER,
        resource TEXT,kind TEXT,role TEXT,subtype INTEGER,filename TEXT,size INTEGER,parse_status TEXT,
        PRIMARY KEY(chat,ref_row));
      CREATE INDEX IF NOT EXISTS native_ref_message ON native_refs(chat,time,seq,random,resource);
      CREATE INDEX IF NOT EXISTS native_ref_resource ON native_refs(resource,kind,role);
      CREATE INDEX IF NOT EXISTS native_ref_filename ON native_refs(filename,size);
      CREATE TABLE IF NOT EXISTS resource_aliases(algorithm TEXT,value TEXT,resource TEXT,kind TEXT,role TEXT,
        method TEXT,field TEXT,PRIMARY KEY(algorithm,value,resource,kind,role,method,field));
      CREATE INDEX IF NOT EXISTS resource_alias_lookup ON resource_aliases(algorithm,value);
      CREATE TABLE IF NOT EXISTS media_elements(key TEXT PRIMARY KEY,descriptor TEXT,result TEXT);
      CREATE TABLE IF NOT EXISTS native_message_context(chat TEXT,time INTEGER,seq TEXT,random TEXT,status TEXT,context TEXT,PRIMARY KEY(chat,time,seq,random));
      CREATE INDEX IF NOT EXISTS native_context_status_chat ON native_message_context(status,chat,seq,random);
      CREATE TABLE IF NOT EXISTS native_identity_candidates(chat TEXT,seq TEXT,random TEXT,time INTEGER,PRIMARY KEY(chat,seq,random,time));
      CREATE TABLE IF NOT EXISTS native_identity_coverage(chat TEXT PRIMARY KEY,rows INTEGER);
      CREATE TABLE IF NOT EXISTS media_catalog_state(id INTEGER PRIMARY KEY,value TEXT);
    ''')


def digest(value):
    if not isinstance(value,str) or not re.fullmatch(r'[a-fA-F0-9]{32}|[a-fA-F0-9]{40}|[a-fA-F0-9]{64}',value):return None
    return {32:'md5',40:'sha1',64:'sha256'}[len(value)],value.lower()


def add_alias(db, algorithm, value, resource, kind, role, method, field):
    db.execute('INSERT OR IGNORE INTO resource_aliases VALUES (?,?,?,?,?,?,?)',
               (algorithm,value,str(resource),kind,role,method,str(field)))


def index_reference(db,chat,row):
    rowid,seq,rnd,subtype,path,size,extra,resid=row
    try:
        obj=json.loads(extra) if extra else {}
        if not isinstance(obj,dict):raise ValueError()
        parse_status='ok'
    except (ValueError,TypeError,UnicodeError):obj={};parse_status='metadata_unparsed'
    kind,role=classify(subtype,path)
    ts=obj.get('msgTime')
    try:ts=int(ts) if ts is not None else None
    except (ValueError,TypeError):ts=None
    filename=obj.get('str_file_name')
    filename=filename if isinstance(filename,str) else Path(path or '').name
    db.execute('INSERT OR REPLACE INTO native_refs VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
      (chat,rowid,str(seq),str(rnd),ts,str(resid),kind,role,subtype,filename,size,parse_status))
    for field in ('md5','sha','thumbMd5','uuid','bytes_file_uuid'):
        value=obj.get(field)
        if not isinstance(value,str) or not value:continue
        if field=='thumbMd5' and role!='poster':continue
        if field in ('uuid','bytes_file_uuid'):
            add_alias(db,'uuid',value,resid,kind,role,'native_reference',field)
            for u in UUID.findall(value):add_alias(db,'normalized_uuid',u.lower(),resid,kind,role,'native_reference',field)
        elif (d:=digest(value)):
            add_alias(db,*d,resid,kind,role,'native_reference',field)
    # 仅匹配已核验的iPhone内容ID路径，不把普通文件名作为内容身份。
    match=re.search(r'/(image_original|image_thumbnail)/([a-fA-F0-9]{32})(?:_|\.)',path or '')
    if match:add_alias(db,'md5',match[2].lower(),resid,kind,role,'iphone_content_path','filePath')
    return parse_status


def register_catalog_aliases(db,resource,row):
    for field in ('md5','sha'):
        if (d:=digest(row.get(field))):add_alias(db,*d,resource,'unknown','stored_version','catalog_identifier',field)
    # 专用资源常以严格的内容ID命名；不以任意同名文件做自动关联。
    filename=row.get('filename') or ''
    for value in HASH.findall(Path(filename).name):
        d=digest(value)
        if d:
            add_alias(db,*d,resource,'unknown','stored_version','catalog_content_filename','filename')
            if len(value)==32:add_alias(db,'emoji_id',value.lower(),resource,'image','stored_version','catalog_emoji_filename','filename')


def kind_of(mime):
    return mime.split('/',1)[0] if isinstance(mime,str) and mime.startswith(('image/','video/','audio/')) else 'file'


class MediaLinker:
    def __init__(self,db):
        db.execute('CREATE INDEX IF NOT EXISTS media_link_status_page ON occurrences(link_status,id)')
        self.db=db
        coverage={'physicalResources':db.execute('SELECT count(*) FROM objects').fetchone()[0],
          'availableResources':db.execute("SELECT count(*) FROM objects WHERE status='available'").fetchone()[0],
          'nativeReferences':db.execute('SELECT count(*) FROM native_refs').fetchone()[0],
          'unparsedNativeReferences':db.execute("SELECT count(*) FROM native_refs WHERE parse_status!='ok'").fetchone()[0],
          'explicitAliases':db.execute('SELECT count(*) FROM resource_aliases').fetchone()[0],
          'policy':'native message identity + physical hashes + declared resource identities; no fuzzy matching'}
        db.execute('INSERT OR REPLACE INTO media_catalog_state VALUES (1,?)',(json.dumps(coverage,separators=(',',':')),))
        self.cache=OrderedDict()
        self.role_cache=OrderedDict()

    def global_candidates(self,key,descriptor):
        if key in self.cache:
            self.cache.move_to_end(key);return self.cache[key]
        cached=self.db.execute('SELECT result FROM media_elements WHERE key=?',(key,)).fetchone()
        if cached and cached[0]:return json.loads(cached[0])
        expected=MEDIA_TYPES.get(descriptor['type'],'file');candidates={};diagnostic=[];native_missing=set();unreadable={}
        def add(obj,ident,role,method,seen=None):
            if obj['status']!='available':
                failure=obj['unavailable_reason'] or 'unclassified_read_failure'
                if failure in ('media_database_payload_missing','media_loose_payload_missing'):
                    native_missing.add(obj['source_res_id'])
                else:unreadable[obj['source_res_id']]=failure
                return
            special=json.loads(obj['special']) if obj['special'] else {}
            if special.get('format')=='qq_picfile_pointer' and expected!='file':
                diagnostic.append({'resource':obj['source_res_id'],'reason':'pointer_payload','pointer':special})
                seen=set(seen or ());seen.add(obj['sha256'])
                if len(seen)>8:return
                for pointer in special.get('identifiers',[]):
                    alg=pointer['algorithm']
                    if alg not in ('md5','sha1','sha256'):continue
                    for child in self.db.execute(f'''SELECT o.* FROM objects o WHERE {alg}=? UNION SELECT o.* FROM resource_aliases a
                      JOIN objects o ON o.source_res_id=a.resource WHERE a.algorithm=? AND a.value=?''',(pointer['value'],alg,pointer['value'])):
                        if child['sha256'] in seen:continue
                        add(child,{**pointer,'field':'qq_picfile_pointer.filename'},'stored_version' if role in ('main','original') else role,'qq_picfile_pointer_target',seen)
                return
            actual=kind_of(obj['mime'])
            if obj['size']==1 and expected!='file':
                diagnostic.append({'resource':obj['source_res_id'],'reason':'one_byte_placeholder'});return
            if role in ('preview','poster') and actual!='image':
                diagnostic.append({'resource':obj['source_res_id'],'sha256':obj['sha256'],'mime':obj['mime'],'reason':'payload_type_mismatch'});return
            if role in ('original','stored_version') and expected!='file' and actual!=expected:
                diagnostic.append({'resource':obj['source_res_id'],'sha256':obj['sha256'],'mime':obj['mime'],'reason':'payload_type_mismatch'});return
            k=(obj['sha256'],role)
            value=candidates.setdefault(k,{'sha256':obj['sha256'],'role':role,'size':obj['size'],'mime':obj['mime'],
               'resources':[],'resourceCount':0,'_resources':set(),'evidence':[],'target':json.loads(obj['target']),**({'special':special} if special else {})})
            rid=obj['source_res_id']
            if rid not in value['_resources']:
                value['_resources'].add(rid)
                value['resourceCount']=len(value['_resources'])
                if len(value['resources'])<32:value['resources'].append(rid)
            proof={'method':method,'algorithm':ident['algorithm'],'field':ident.get('field'),'value':ident['value']}
            if proof not in value['evidence'] and len(value['evidence'])<8:value['evidence'].append(proof)
        for ident in descriptor.get('identifiers',[]):
            alg=ident['algorithm'];value=ident['value'];role=ident['role']
            physical_alg='md5' if alg=='emoji_id' else alg
            if physical_alg in ('md5','sha1','sha256'):
                for obj in self.db.execute(f'SELECT * FROM objects WHERE {physical_alg}=?',(value,)):
                    rid=obj['source_res_id']
                    known=self.role_cache.get(rid)
                    if known is None:
                        known={r[0] for r in self.db.execute('SELECT DISTINCT role FROM native_refs WHERE resource=?',(rid,))}
                        self.role_cache[rid]=known
                        if len(self.role_cache)>4096:self.role_cache.popitem(last=False)
                    actual_role=role if role!='main' else 'original' if 'original' in known else 'preview' if known=={'preview'} else 'poster' if known=={'poster'} else 'stored_version'
                    add(obj,ident,actual_role,'physical_content_hash')
            for alias in self.db.execute('''SELECT o.*,a.role AS alias_role,a.method AS alias_method,a.field AS alias_field
              FROM resource_aliases a JOIN objects o ON o.source_res_id=a.resource WHERE a.algorithm IN (?,?) AND a.value=?''',(alg,'md5' if alg=='emoji_id' else alg,value)):
                ar=alias['alias_role'];actual=kind_of(alias['mime'])
                final=role if role!='main' else ar
                if expected=='video' and actual=='image' and ar=='poster':final='poster'
                add(alias,ident,final,alias['alias_method']+':'+alias['alias_field'])
            missing=self.db.execute('''SELECT DISTINCT a.resource FROM resource_aliases a LEFT JOIN objects o
              ON o.source_res_id=a.resource WHERE a.algorithm IN (?,?) AND a.value=? AND o.res_id IS NULL''',(alg,'md5' if alg=='emoji_id' else alg,value))
            native_missing.update(r[0] for r in missing)
        # 未知字段只做诊断；发现实际文件时报告逻辑缺口，绝不把任意字段直接当媒体身份。
        known={(x['algorithm'],x['value'],x.get('field')) for x in descriptor.get('identifiers',[])}
        for ident in descriptor.get('diagnosticIdentifiers',[]):
            if (ident['algorithm'],ident['value'],ident.get('field')) in known:continue
            alg=ident['algorithm']
            if alg not in ('md5','sha1','sha256'):continue
            rows=self.db.execute(f'SELECT source_res_id,sha256,mime FROM objects WHERE {alg}=?',(ident['value'],)).fetchall()
            if rows:diagnostic.append({'reason':'unadapted_identity_field','field':ident['field'],'objects':[dict(r) for r in rows]})
        known_roles={(sha,role) for sha,role in candidates if role!='stored_version'}
        for sha,role in list(candidates):
            if role=='stored_version' and any(s==sha for s,r in known_roles):
                extra=candidates.pop((sha,role))
                for s,r in sorted(known_roles):
                    if s==sha:
                        target=candidates[(s,r)]
                        target['_resources'].update(extra['_resources'])
                        target['resourceCount']=len(target['_resources'])
                        target['resources']=sorted(target['_resources'])[:32]
                        for proof in extra['evidence']:
                            if proof not in target['evidence'] and len(target['evidence'])<8:target['evidence'].append(proof)
                        break
        for item in candidates.values():
            item.pop('_resources',None)
            item['contentIdentityVerified']=any(e['method']=='physical_content_hash' for e in item['evidence'])
        result={'candidates':list(candidates.values()),'diagnostic':diagnostic,'nativeMissingResources':sorted(native_missing),'unreadableResources':unreadable}
        self.db.execute('UPDATE media_elements SET result=? WHERE key=?',(json.dumps(result,separators=(',',':')),key))
        self.cache[key]=result
        if len(self.cache)>2048:self.cache.popitem(last=False)
        return result

    def resolve(self,occurrence):
        descriptor=json.loads(self.db.execute('SELECT descriptor FROM media_elements WHERE key=?',(occurrence['element_key'],)).fetchone()[0])
        if descriptor['type']==27:
            return {'status':'builtin_resource','reason':'qq_emoji_bounce_uses_client_asset','preferredSha256':None,
              'candidates':[],'evidence':{'builtinResource':descriptor.get('builtinResource'),'catalogAudit':'media_catalog_state:1'}}
        global_result=self.global_candidates(occurrence['element_key'],descriptor)
        candidates=[dict(x) for x in global_result['candidates']]
        source=json.loads(occurrence['source']);table,ts,seq,rnd=source['key']
        native=[]
        if occurrence['scope'] in ('root','recalled_original'):
            native=self.db.execute('SELECT resource,kind,role,subtype FROM native_refs WHERE chat=? AND time=? AND seq=? AND random=?',(table,ts,seq,rnd)).fetchall()
        native_roles={r['resource']:r['role'] for r in native}
        expected=MEDIA_TYPES.get(descriptor['type'],'file')
        if native and source.get('sameKindCount')==1:
            for obj in self.db.execute("""SELECT DISTINCT o.*,n.role AS native_role FROM native_refs n JOIN objects o ON o.source_res_id=n.resource
              WHERE n.chat=? AND n.time=? AND n.seq=? AND n.random=? AND n.kind=?""",(table,ts,seq,rnd,expected)):
                if obj['status']!='available' or (obj['size']==1 and expected!='file'):continue
                actual=kind_of(obj['mime'])
                if actual!=expected and expected!='file':continue
                if not any(x['sha256']==obj['sha256'] and x['role']==obj['native_role'] for x in candidates):
                    candidates.append({'sha256':obj['sha256'],'role':obj['native_role'],'size':obj['size'],'mime':obj['mime'],
                      'resources':[obj['source_res_id']],'resourceCount':1,'contentIdentityVerified':False,'evidence':[{'method':'native_message_single_typed_element'}],'target':json.loads(obj['target']),**({'special':json.loads(obj['special'])} if obj['special'] and obj['special']!='{}' else {})})
        # 原生引用是限定当前消息的额外证据；不能只因同消息内存在附件就绑定到任意元素。
        for item in candidates:
            matches=self.db.execute('''SELECT DISTINCT source_res_id FROM objects WHERE sha256=?
              AND source_res_id IN (SELECT resource FROM native_refs WHERE chat=? AND time=? AND seq=? AND random=?)''',
              (item['sha256'],table,ts,seq,rnd)).fetchall() if native else []
            item['nativeResources']=[r[0] for r in matches]
        native_unavailable=[]
        if occurrence['scope'] in ('root','recalled_original'):
            for ref in native:
                if ref['kind']!=expected and not(expected=='file' and ref['subtype']==11):continue
                obj=self.db.execute('SELECT status,unavailable_reason FROM objects WHERE source_res_id=?',(ref['resource'],)).fetchone()
                if obj is None:native_unavailable.append({'resource':ref['resource'],'reason':'resource_missing_from_filecontext'})
                elif obj['status']!='available':native_unavailable.append({'resource':ref['resource'],'reason':obj['unavailable_reason'] or 'unclassified_read_failure'})
        preferred=[]
        for native_only,roles in ((True,('original',)),(False,('original',)),(True,('stored_version',)),(False,('stored_version',))):
            group=[x for x in candidates if x['role'] in roles and (not native_only or x['nativeResources'])]
            if group:
                preferred=group;break
        hashes={x['sha256'] for x in preferred}
        evidence={'nativeReferenceCount':len(native),'checkedAlgorithms':sorted({i['algorithm'] for i in descriptor.get('identifiers',[])}),
          'diagnostic':global_result['diagnostic'],'missingNativeResources':global_result['nativeMissingResources'],'unreadableResources':global_result['unreadableResources'],'catalogAudit':'media_catalog_state:1','nativeUnavailableResources':native_unavailable,'historicalOnly':bool(source.get('historicalOnly'))}
        if not candidates and descriptor.get('filename') and descriptor.get('size') is not None:
            name=Path(descriptor['filename']).name
            weak=self.db.execute("""SELECT DISTINCT o.sha256,o.source_res_id FROM native_refs n JOIN objects o ON o.source_res_id=n.resource
              WHERE n.filename=? AND n.size=? LIMIT 33""",(name,descriptor['size'])).fetchall()
            if weak:evidence['filenameSizeOnlyCandidates']=[dict(r) for r in weak]
        if len(hashes)==1:
            status='resolved';reason='unique_preferred_payload';preferred_sha=next(iter(hashes))
        elif len(hashes)>1:
            status='multiple_versions';reason='distinct_payloads_with_same_explicit_identity';preferred_sha=None
        elif candidates:
            status='preview_only';reason='original_payload_not_found';preferred_sha=None
        elif any(d['reason']=='unadapted_identity_field' for d in global_result['diagnostic']):
            status='logic_gap';reason='unadapted_identity_field_has_physical_payload';preferred_sha=None
        elif native_unavailable and all(x['reason'] in ('resource_missing_from_filecontext','media_database_payload_missing','media_loose_payload_missing') for x in native_unavailable):
            status='missing_file';reason='native_message_reference_without_payload';preferred_sha=None
        elif native_unavailable or global_result['unreadableResources']:
            status='unreadable_file';reason='referenced_payload_cannot_be_read';preferred_sha=None
        elif any(d['reason']=='payload_type_mismatch' for d in global_result['diagnostic']):
            status='type_mismatch';reason='explicit_identity_points_to_other_payload_type';preferred_sha=None
        elif any(d['reason']=='pointer_payload' for d in global_result['diagnostic']):
            status='pointer_only';reason='external_pointer_without_backed_payload';preferred_sha=None
        elif global_result['nativeMissingResources']:
            status='missing_file';reason='explicit_resource_reference_without_payload';preferred_sha=None
        elif global_result['diagnostic']:
            status='placeholder_only';reason='only_one_byte_placeholder';preferred_sha=None
        elif native and source.get('sameKindCount',0)>1 and not descriptor.get('identifiers'):
            status='identity_insufficient';reason='multiple_elements_without_individual_identity';preferred_sha=None
        elif evidence.get('filenameSizeOnlyCandidates'):
            status='identity_insufficient';reason='filename_size_match_without_verifiable_identity';preferred_sha=None
        else:
            algorithms=evidence['checkedAlgorithms']
            status='identity_missing' if not algorithms else 'identity_insufficient' if not any(a in ('md5','sha1','sha256') for a in algorithms) else 'missing_by_identifiers'
            reason={'identity_missing':'no_verifiable_media_identity','identity_insufficient':'uuid_without_resource_reference','missing_by_identifiers':'no_match_in_all_payload_hashes_and_native_aliases'}[status]
            preferred_sha=None
        return {'status':status,'reason':reason,'preferredSha256':preferred_sha,'candidates':candidates,'evidence':evidence}
