"""按源 filecontext 定位并流式散列，不展开 40GB 媒体副本。"""
import ctypes
import hashlib
import os
from pathlib import Path, PureWindowsPath
from msg0 import open_backup, _lib

BLOCK = 512 * 1024


def transform(data, key):
    if len(data) != BLOCK or len(key) != 16:
        raise ValueError('loose_media_invalid_block_or_key')
    buf = ctypes.create_string_buffer(data, len(data))
    kb = ctypes.create_string_buffer(key, 16)
    try:
        if _lib.msg0_xxtea_decrypt(buf, len(data), kb):
            raise ValueError('loose_media_decryption_failed')
        return buf.raw
    finally:
        ctypes.memset(kb, 0, 16)


def mime(head):
    if head.startswith(b'\xff\xd8\xff'): return 'image/jpeg'
    if head.startswith(b'\x89PNG'): return 'image/png'
    if head.startswith((b'GIF87a', b'GIF89a')): return 'image/gif'
    if head.startswith(b'RIFF') and head[8:12] == b'WEBP': return 'image/webp'
    if head.startswith(b'BM'): return 'image/bmp'
    if head.startswith((b'II*\0',b'MM\0*')): return 'image/tiff'
    if head.startswith(b'ID3') or (len(head)>1 and head[0]==255 and head[1]&224==224): return 'audio/mpeg'
    if head.startswith(b'%PDF-'): return 'application/pdf'
    if head.startswith(b'#!SILK_V3') or head[1:10] == b'#!SILK_V3': return 'audio/silk'
    if head.startswith(b'#!AMR'): return 'audio/amr'
    if head.startswith(b'OggS'): return 'audio/ogg'
    if head.startswith(b'RIFF') and head[8:12] == b'WAVE': return 'audio/wav'
    if head[4:8] == b'ftyp':
        return 'image/heic' if head[8:12] in (b'heic', b'heix', b'mif1') else 'audio/mp4' if head[8:12] == b'M4A ' else 'video/mp4'
    return 'application/octet-stream'


class MediaReader:
    def __init__(self, root, entries, check):
        self.root = root
        self.check = check
        self.dbs = {}
        self.index = None
        for name, key in entries.items():
            if name != 'B31DB6832ED65FD588CF1F41904F3F33':
                self.dbs[name] = open_backup(root / name, key, cache_mb=4)

    def stream(self, r):
        if r['dbfileResid']:
            found = []
            for name, db in self.dbs.items():
                for rowid, length in db.execute('SELECT rowid,length(filedata) FROM resfile WHERE resId=?', (r['dbfileResid'],)):
                    found.append((name, rowid, length))
            if not found: raise FileNotFoundError('media_database_payload_missing')
            if len(found) != 1: raise ValueError('media_database_payload_ambiguous')
            name, rowid, length = found[0]
            with self.dbs[name].blob_open('main', 'resfile', 'filedata', rowid, False) as blob:
                for pos in range(0, length, 256 * 1024):
                    self.check()
                    yield blob.read(min(256 * 1024, length - pos))
        else:
            name = r['filename']
            if not isinstance(name, str) or not name or Path(name).name != name:
                raise FileNotFoundError('media_loose_filename_invalid')
            paths = self.loose(name)
            if not paths: raise FileNotFoundError('media_loose_payload_missing')
            if len(paths) != 1: raise ValueError('media_loose_payload_ambiguous')
            p = paths[0]
            sig = p.stat()
            if sig.st_size != r['filesize'] or sig.st_size < 2 * BLOCK:
                raise ValueError('media_loose_size_invalid')
            key = r['filekey']
            with p.open('rb') as f:
                yield transform(f.read(BLOCK), key)
                remaining = sig.st_size - 2 * BLOCK
                while remaining:
                    self.check()
                    data = f.read(min(256 * 1024, remaining))
                    if not data: raise IOError('media_loose_short_read')
                    remaining -= len(data)
                    yield data
                yield transform(f.read(BLOCK), key)
            after = p.stat()
            if (sig.st_size, sig.st_mtime_ns, sig.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
                raise RuntimeError('source_media_changed')

    def loose(self, name):
        # 2026-11-03：原来每个松散文件都完整遍历一次备份目录（找到后还要继续找以确认不重名），资源多时是 N×目录树。
        # 每个进程只遍历一次；文件名→路径放临时 SQLite（超出缓存落盘），不把整个文件树常驻内存。
        if self.index is None:
            import sqlite3
            index = sqlite3.connect('')
            index.execute('CREATE TABLE files(name TEXT NOT NULL, path TEXT NOT NULL)')
            for base, dirs, files in os.walk(self.root, followlinks=False):
                self.check()
                dirs[:] = [d for d in dirs if not (Path(base) / d).is_symlink()]
                index.executemany('INSERT INTO files VALUES (?,?)',
                    [(f, str(Path(base) / f)) for f in files if not (Path(base) / f).is_symlink()])
            index.execute('CREATE INDEX files_name ON files(name)')
            self.index = index
        return [Path(row[0]) for row in self.index.execute('SELECT path FROM files WHERE name=? LIMIT 2', (name,))]

    def inspect(self, r):
        digests = {k: hashlib.new(k) for k in ('sha256', 'sha1', 'md5')}
        length, head = 0, b''
        for block in self.stream(r):
            if not head: head = block[:4096]
            length += len(block)
            for digest in digests.values(): digest.update(block)
        if length != r['filesize']: raise ValueError('media_payload_size_mismatch')
        result={**{k:d.hexdigest() for k,d in digests.items()},'size':length,'mime':mime(head)}
        if head.startswith(b'[picFile,path=') and length<=4096:
            import re
            try:label=head.decode('utf-8')
            except UnicodeDecodeError:label=head.decode('gb18030',errors='replace')
            match=re.fullmatch(r'\[picFile,path=(.*)\]',label,re.S)
            if match:
                path=match.group(1);name=PureWindowsPath(path).name
                ids=re.findall(r'(?<![0-9a-fA-F])([0-9a-fA-F]{32}|[0-9a-fA-F]{40}|[0-9a-fA-F]{64})(?![0-9a-fA-F])',name)
                result['mime']='application/x-qq-picture-pointer'
                result['special']={'format':'qq_picfile_pointer','path':path,'filename':name,
                    'identifiers':[{'algorithm':{32:'md5',40:'sha1',64:'sha256'}[len(h)],'value':h.lower()} for h in ids]}
        return result

    def close(self):
        for db in self.dbs.values(): db.close()
        if self.index: self.index.close()


class PhysicalCatalog:
    """内容散列的可复用目录；只复用源数据库签名相同的内嵌BLOB，松散文件每次重读。"""
    def __init__(self,root,signatures):
        import json,sqlite3
        self.json=json
        signature=json.dumps({'version':1,'files':signatures},sort_keys=True,separators=(',',':'))
        name=hashlib.sha256(signature.encode()).hexdigest()
        directory=Path(root);directory.mkdir(mode=0o700,parents=True,exist_ok=True)
        self.path=directory/(name+'.sqlite')
        self.db=sqlite3.connect(self.path)
        self.db.executescript('PRAGMA journal_mode=WAL;CREATE TABLE IF NOT EXISTS payloads(resource TEXT PRIMARY KEY,value TEXT);CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT);')
        previous=self.db.execute("SELECT value FROM metadata WHERE key='signature'").fetchone()
        if previous and previous[0]!=signature:raise ValueError('physical_catalog_signature_mismatch')
        self.db.execute("INSERT OR IGNORE INTO metadata VALUES ('signature',?)",(signature,));self.db.commit()

    def get(self,resource):
        row=self.db.execute('SELECT value FROM payloads WHERE resource=?',(resource,)).fetchone()
        return self.json.loads(row[0]) if row else None

    def put(self,resource,value):
        self.db.execute('INSERT OR REPLACE INTO payloads VALUES (?,?)',(resource,self.json.dumps(value)))

    def commit(self):self.db.commit()
    def close(self):self.db.close()
