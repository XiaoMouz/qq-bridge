"""QQ MSG0 备份的按需解密只读 SQLite 视图。

用法：con = open_backup(path, keybytes)，使用后显式 close。
不落地整库明文；源文件只读打开，页缓存有界。
"""
from __future__ import annotations
from collections import OrderedDict
import ctypes
import os
from pathlib import Path
import threading
import uuid

import apsw

HEADER_SIZE = 1024
PAGE_SIZE = 8192
_sqlite_configured = False
_sqlite_config_lock = threading.Lock()

def _configure_backup_sqlite():
    """QQ 的外置 1024 字节头会移动 SQLite 保留锁页；修正只作用于此进程的 APSW。

    该 SQLite 实例只能读取备份。状态库使用 sqlite3 模块独立的 SQLite 实例。
    """
    global _sqlite_configured
    with _sqlite_config_lock:
        if _sqlite_configured:
            return
        cfg = apsw.Connection(':memory:')
        try:
            cfg.enable_load_extension(True)
            cfg.load_extension(str(Path(os.environ['QQ_IMPORT_NATIVE']) / 'pendingbyte_fix.so'),
                               'sqlite3_msgpendingbyte_init')
            previous = cfg.execute('SELECT qq_pending_byte(1073740800)').fetchone()[0]
            if previous not in (1073741824, 1073740800):
                raise RuntimeError('Unexpected SQLite reserved-byte configuration')
            if cfg.execute('SELECT qq_pending_byte(0)').fetchone()[0] != 1073740800:
                raise RuntimeError('QQ reserved-byte configuration did not apply')
        finally:
            cfg.close()
        _sqlite_configured = True
_lib = ctypes.CDLL(str(Path(os.environ['QQ_IMPORT_NATIVE']) / 'msg0codec.so'))
_lib.msg0_xxtea_decrypt.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
_lib.msg0_xxtea_decrypt.restype = ctypes.c_int


def decrypt_page(data: bytes, key: bytes) -> bytes:
    """用原始 16 字节密钥解密一个小端 XXTEA 页。"""
    if len(key) != 16 or len(data) < 8 or len(data) % 4 or len(data) > 65536:
        raise ValueError('Expected a 16-byte key and complete page of 8..65536 bytes')
    buf = ctypes.create_string_buffer(data, len(data))
    keybuf = ctypes.create_string_buffer(key, 16)
    try:
        if _lib.msg0_xxtea_decrypt(buf, len(data), keybuf):
            raise ValueError('XXTEA rejected page parameters')
        return buf.raw
    finally:
        ctypes.memset(keybuf, 0, 16)


class _ReadOnlyFile(apsw.VFSFile):
    def __init__(self, name, flags, owner):
        self.owner = owner
        self.cache = OrderedDict()
        self.guard = threading.RLock()
        self.closed = False
        self.page_reads = 0
        self.cache_hits = 0
        self.keybuf = ctypes.create_string_buffer(owner.key, 16)
        # 不透传 SQLite 的打开提示，底层文件始终只读。
        flags[1] = apsw.SQLITE_OPEN_READONLY
        super().__init__(owner.base, name, [apsw.SQLITE_OPEN_READONLY, 0])
        if super().xRead(4,32)!=b'MSG0':
            raise apsw.NotADBError('Expected MSG0 backup wrapper')
        physical_size = super().xFileSize()
        if physical_size < HEADER_SIZE + PAGE_SIZE or (physical_size - HEADER_SIZE) % PAGE_SIZE:
            self.xClose()
            raise apsw.CantOpenError('Invalid MSG0 physical size')
        self.logical_size = physical_size - HEADER_SIZE
        first = self._page(0)
        if first[:16] != b'SQLite format 3\0' or int.from_bytes(first[16:18], 'big') != PAGE_SIZE:
            self.xClose()
            raise apsw.NotADBError('MSG0 key/page size did not produce a valid SQLite header')

    def _page(self, index):
        cached = self.cache.get(index)
        if cached is not None:
            self.cache_hits += 1
            self.cache.move_to_end(index)
            return cached
        encrypted = super().xRead(PAGE_SIZE, HEADER_SIZE + index * PAGE_SIZE)
        if len(encrypted) != PAGE_SIZE:
            raise apsw.IOError('Short encrypted MSG0 page')
        buf = ctypes.create_string_buffer(encrypted, PAGE_SIZE)
        if _lib.msg0_xxtea_decrypt(buf, PAGE_SIZE, self.keybuf):
            raise apsw.IOError('XXTEA page transform failed')
        plain = buf.raw
        self.page_reads += 1
        self.cache[index] = plain
        if len(self.cache) > self.owner.max_pages:
            self.cache.popitem(last=False)
        return plain

    def xRead(self, amount, offset):
        if amount < 0 or offset < 0:
            raise apsw.IOError('Negative read')
        with self.guard:
            if self.closed:
                raise apsw.IOError('Read after close')
            end = min(offset + amount, self.logical_size)
            if offset >= end:
                return b''
            chunks = []
            while offset < end:
                page, within = divmod(offset, PAGE_SIZE)
                take = min(end - offset, PAGE_SIZE - within)
                chunks.append(self._page(page)[within:within + take])
                offset += take
            return b''.join(chunks)

    def xFileSize(self):
        return self.logical_size

    def xWrite(self, data, offset):
        raise apsw.ReadOnlyError('MSG0 source is read-only')

    def xTruncate(self, newsize):
        raise apsw.ReadOnlyError('MSG0 source is read-only')

    def xSync(self, flags):
        return None

    def xLock(self, level):
        return None

    def xUnlock(self, level):
        return None

    def xCheckReservedLock(self):
        return False

    def xSectorSize(self):
        return 4096

    def xDeviceCharacteristics(self):
        return apsw.SQLITE_IOCAP_IMMUTABLE

    def xFileControl(self, op, ptr):
        # 禁用 mmap 和原生文件控制，避免 SQLite 绕过解密页流。
        if op == apsw.SQLITE_FCNTL_MMAP_SIZE:
            ctypes.c_int64.from_address(ptr).value = 0
            return True
        return False

    def xClose(self):
        if not self.closed:
            with self.guard:
                self.closed = True
                self.cache.clear()
                ctypes.memset(self.keybuf, 0, 16)
                super().xClose()


class _ReadOnlyVFS(apsw.VFS):
    def __init__(self, path, key, cache_mb):
        self.path = str(Path(path).resolve(strict=True))
        self.key = bytes(key)
        self.name = 'qq-msg0-ro-' + uuid.uuid4().hex
        self.base = apsw.vfs_names()[0]
        self.max_pages = max(1, int(cache_mb * 1024 * 1024 / PAGE_SIZE))
        self.file = None
        super().__init__(self.name, self.base)

    def xOpen(self, name, flags):
        filename = name.filename() if isinstance(name, apsw.URIFilename) else name
        if not filename or os.path.abspath(filename) != self.path:
            raise apsw.CantOpenError('Only the selected MSG0 database can be opened')
        if flags[0] & (apsw.SQLITE_OPEN_READWRITE | apsw.SQLITE_OPEN_CREATE | apsw.SQLITE_OPEN_DELETEONCLOSE):
            raise apsw.ReadOnlyError('MSG0 writes are forbidden')
        self.file = _ReadOnlyFile(name, flags, self)
        return self.file

    def xAccess(self, pathname, flags):
        # 不探测、不重放原目录的 journal/WAL。
        return os.path.abspath(pathname) == self.path and flags != apsw.SQLITE_ACCESS_READWRITE

    def xDelete(self, filename, syncdir):
        raise apsw.ReadOnlyError('MSG0 deletes are forbidden')


class BackupConnection(apsw.Connection):
    """连接持有独立 VFS，显式关闭时清理缓存与密钥。"""
    def __init__(self, path, key, cache_mb=64):
        if len(key) != 16:
            raise ValueError('MSG0 requires exactly sixteen key bytes')
        _configure_backup_sqlite()
        self._backup_vfs = _ReadOnlyVFS(path, key, cache_mb)
        try:
            uri = Path(self._backup_vfs.path).as_uri() + '?mode=ro&immutable=1'
            super().__init__(uri, flags=apsw.SQLITE_OPEN_READONLY | apsw.SQLITE_OPEN_URI, vfs=self._backup_vfs.name)
            self.execute('PRAGMA query_only=ON')
            self.execute('PRAGMA temp_store=MEMORY')
            self.execute('PRAGMA mmap_size=0')
        except BaseException:
            self._backup_vfs.unregister()
            raise

    @property
    def page_stats(self):
        f = self._backup_vfs.file
        return {'decrypted_pages': f.page_reads, 'cache_hits': f.cache_hits,
                'cached_bytes': len(f.cache) * PAGE_SIZE} if f else {}

    def close(self, force=False):
        try:
            return super().close(force)
        finally:
            self._backup_vfs.unregister()
            self._backup_vfs.key = b''


def open_backup(path, keybytes, *, cache_mb=64) -> apsw.Connection:
    return BackupConnection(path, keybytes, cache_mb)
