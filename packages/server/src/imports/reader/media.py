"""按源 filecontext 定位并流式散列，不展开 40GB 媒体副本。"""
import ctypes
from collections import OrderedDict
import hashlib
import os
from pathlib import Path
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
        self.files = OrderedDict()
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
            paths = self.files.get(name)
            if paths is None:
                # 松散文件逐次查找，只缓存 128 个定位；不把整个备份文件树塞进内存。
                paths = []
                for base, dirs, files in os.walk(self.root, followlinks=False):
                    self.check()
                    dirs[:] = [d for d in dirs if not (Path(base) / d).is_symlink()]
                    if name in files:
                        p = Path(base) / name
                        if not p.is_symlink(): paths.append(p)
                        if len(paths)>1: break
                self.files[name] = paths
                if len(self.files)>128: self.files.popitem(last=False)
            else:
                self.files.move_to_end(name)
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

    def inspect(self, r):
        digests = {k: hashlib.new(k) for k in ('sha256', 'sha1', 'md5')}
        length, head = 0, b''
        for block in self.stream(r):
            if not head: head = block[:64]
            length += len(block)
            for digest in digests.values(): digest.update(block)
        if length != r['filesize']: raise ValueError('media_payload_size_mismatch')
        return {**{k: d.hexdigest() for k, d in digests.items()}, 'size': length, 'mime': mime(head)}

    def close(self):
        for db in self.dbs.values(): db.close()
