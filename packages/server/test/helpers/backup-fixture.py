"""合成无隐私的 MSG0 夹具；真实加密 SQLite 页与真实 wire 字段，不含账号密钥。"""
import json
import hashlib
import sqlite3
import struct
import sys
from pathlib import Path


def varint(n):
    out = bytearray()
    while n > 127:
        out.append((n & 127) | 128)
        n >>= 7
    return bytes(out) + bytes([n])


def proto(*fields):
    out = b''
    for tag, value in fields:
        if isinstance(value, str): value = value.encode()
        out += varint((tag << 3) | (2 if isinstance(value, bytes) else 0))
        out += varint(len(value)) + value if isinstance(value, bytes) else varint(value)
    return out


def encrypt(block, key):
    mask = 0xffffffff
    v = list(struct.unpack('<' + 'I' * (len(block) // 4), block))
    k = struct.unpack('<4I', key)
    n, total = len(v), 0
    z = v[-1]
    for _ in range(6 + 52 // n):
        total = (total + 0x9e3779b9) & mask
        e = (total >> 2) & 3
        for p in range(n):
            y = v[(p + 1) % n]
            mx = (((z >> 5 ^ (y << 2) & mask) + (y >> 3 ^ (z << 4) & mask)) ^ ((total ^ y) + (k[(p & 3) ^ e] ^ z))) & mask
            v[p] = (v[p] + mx) & mask
            z = v[p]
    return struct.pack('<' + 'I' * n, *v)


def create(root):
    root = Path(root)
    plain = root / 'plain.sqlite'
    db = sqlite3.connect(plain)
    db.execute('PRAGMA page_size=8192')
    db.execute('CREATE TABLE msg_1_42(_id INTEGER,msgTime INTEGER,msgSeq INTEGER,msgRandom INTEGER,extensionData BLOB,extraData BLOB,PRIMARY KEY(msgTime,msgSeq,msgRandom))')
    db.execute('CREATE TABLE filecontext(resId INTEGER,md5 TEXT,md510 TEXT,sha TEXT,sha3 TEXT,filesize INTEGER,ref INTEGER,filefloder TEXT,filename TEXT,filekey BLOB,blockSize INTEGER,dbfileResid INTEGER)')
    original=b'\x89PNG\r\n\x1a\nfixture-original'
    preview=b'\x89PNG\r\n\x1a\nfixture-preview'
    poster=b'\xff\xd8\xfffixture-poster'
    video=b'\x00\x00\x00\x18ftypisomfixture-video'
    digest=hashlib.md5(original).digest()
    db.execute('CREATE TABLE res_1_42(msgSeq INTEGER,msgRandom INTEGER,msgSubType INTEGER,filePath TEXT,fileSize INTEGER,extraData BLOB,resinfoId INTEGER)')
    for rid,subtype,payload in [(1,1,original),(2,1,original),(3,3,preview),(4,7,poster),(5,4,video)]:
        db.execute('INSERT INTO filecontext VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',(rid,hashlib.md5(payload).hexdigest(),None,None,None,len(payload),1,'','fixture-'+str(rid),None,8192,rid))
        meta=json.dumps({'msgTime':1700000010,'md5':digest.hex(),'uuid':'fixture-uuid'})
        db.execute('INSERT INTO res_1_42 VALUES (?,?,?,?,?,?,?)',(12,52,subtype,'/image_'+('original' if subtype==1 else 'thumbnail')+'/'+digest.hex()+'.png',len(payload),meta,rid))
    elements = [proto((45002, 1), (45101, '@测试'), (45105, 'u_target')),
        proto((45002, 1), (45101, '@全体成员'), (45105, '0'), (45102, 1)),
        proto((45002, 1), (45101, '@全体成员'), (45105, '0'), (45102, 0)),
        proto((45002, 7), (47402, 8), (47404, 1700000000), (40020, 'u_target'), (47403, 9), (47416, 18446744073709551600), (47423, proto((45002, 1), (45101, '原消息\u2028换行\u2029继续')))),
        proto((45002, 6), (47601, 14), (47602, '/微笑')),
        proto((45002, 6), (47601, 345), (47603, 'super'), (47605, 1)),
        proto((45002, 2), (45406, digest), (45411, 640), (45412, 480)),
        proto((45002, 10), (47901, json.dumps({'app': 'com.tencent.miniapp_01', 'meta': {'detail': {'title': '测试小程序'}}}, ensure_ascii=False))),
        proto((45002, 8), (45003, 12), (48212, 1061), (48214, '<gtip><qq uin="u_author"/><nor txt="拍了拍"/><qq uin="u_missing" jp="9"/></gtip>')), proto((45002, 4), (45906, 12)), proto((45002, 5), (45410, 30), (45503,'fixture-uuid')),
        proto((45002, 26), (48172, 22), (48182, 9), (48182, 10), (48175, proto((48178, '密友绑定提醒'))))]
    nested = proto((40001, 99), (40050, 1699999999), (40033, 9), (40800, elements[6]))
    body = proto((40001, 18446744073709551601), (40003, 12), (40005, 88), (40002, 18446744073709551602),
        (40010, 2), (40020, 'u_author'), (40033, 7), (40041, 2), (40050, 1700000010),
        *[(40800, x) for x in elements], (40900, nested))
    raw = proto((1, proto((1, 7))), (5, body))
    # 原 SQL INTEGER 有符号，body 可以无符号；分开保存，不悄悄覆盖。
    db.execute('INSERT INTO msg_1_42 VALUES (?,?,?,?,?,?)', (1, 1700000010, 12, 52, raw, b''))
    file_payload=b'fixture file data'
    db.execute('INSERT INTO filecontext VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',(6,None,None,None,None,len(file_payload),1,'','manual.bin',None,8192,6))
    db.execute('INSERT INTO res_1_42 VALUES (?,?,?,?,?,?,?)',(13,53,11,'/cache/manual.bin',len(file_payload),json.dumps({'msgTime':1700000011}),6))
    file_body=proto((40001,100),(40003,13),(40002,53),(40010,2),(40033,7),(40041,2),(40050,1700000011),
      (40800,proto((45002,3),(45402,'manual.bin'),(45405,len(file_payload)))))
    db.execute('INSERT INTO msg_1_42 VALUES (?,?,?,?,?,?)',(2,1700000011,13,53,proto((5,file_body)),b''))
    pointer_payload=b'[picFile,path=D:\\missing.mp4]'
    db.execute('INSERT INTO filecontext VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',(7,None,None,None,None,len(pointer_payload),1,'','pointer.dat',None,8192,7))
    db.execute('INSERT INTO res_1_42 VALUES (?,?,?,?,?,?,?)',(14,54,1,'/cache/pointer.dat',len(pointer_payload),json.dumps({'msgTime':1700000012,'uuid':'pointer-uuid'}),7))
    pointer_body=proto((40001,101),(40003,14),(40002,54),(40010,2),(40033,7),(40041,2),(40050,1700000012),
      (40800,proto((45002,2),(45503,'pointer-uuid'))))
    db.execute('INSERT INTO msg_1_42 VALUES (?,?,?,?,?,?)',(3,1700000012,14,54,proto((5,pointer_body)),b''))
    recalled=proto((45002,8),(45003,1),(47703,'u_operator'),(47704,'u_original'),(47710,elements[6]))
    recalled_body=proto((40001,102),(40003,15),(40002,55),(40010,2),(40020,'u_operator'),(40033,7),(40041,2),(40050,1700000013),(40800,recalled))
    db.execute('INSERT INTO msg_1_42 VALUES (?,?,?,?,?,?)',(4,1700000013,15,55,proto((5,recalled_body)),b''))
    db.execute('INSERT INTO res_1_42 VALUES (?,?,?,?,?,?,?)',(15,55,1,'/image_original/'+digest.hex()+'.png',len(original),json.dumps({'msgTime':1700000013,'md5':digest.hex()}),1))
    db.commit(); db.close()
    key = b'fixture-key-1234'
    data = plain.read_bytes()
    header = bytearray(1024);header[32:36] = b'MSG0'
    target = root / 'B31DB6832ED65FD588CF1F41904F3F33'
    target.write_bytes(bytes(header) + b''.join(encrypt(data[i:i+8192], key) for i in range(0, len(data), 8192)))
    plain.unlink()
    media_plain=root/'media-plain.sqlite'
    media=sqlite3.connect(media_plain);media.execute('PRAGMA page_size=8192');media.execute('CREATE TABLE resfile(resId INTEGER,filedata BLOB)');media.execute('CREATE INDEX resfile_id ON resfile(resId)')
    for rid,payload in [(1,original),(2,original),(3,preview),(4,poster),(5,video),(6,file_payload),(7,pointer_payload)]:media.execute('INSERT INTO resfile VALUES (?,?)',(rid,payload))
    media.commit();media.close();data=media_plain.read_bytes();media_target=root/'24B1A38335CE61F10833BB30BD14CD0E';media_target.write_bytes(bytes(header)+b''.join(encrypt(data[i:i+8192],key) for i in range(0,len(data),8192)));media_plain.unlink()
    (root / 'keys.json').write_text(json.dumps([{'file':str(target),'key':key.decode()},{'file':str(media_target),'key':key.decode()}]))
    return target, key


if __name__ == '__main__':
    path, key = create(sys.argv[1])
    from msg0 import open_backup
    from parser import parse_record
    db = open_backup(path, key, cache_mb=1)
    row = db.execute('SELECT _id,msgTime,msgSeq,msgRandom,extensionData,extraData FROM msg_1_42').fetchone()
    result = parse_record('msg_1_42', row)
    write_blocked = False
    try: db.execute('DELETE FROM msg_1_42')
    except Exception: write_blocked = True
    db.close()
    print(json.dumps({'record': result, 'writeBlocked': write_blocked}, ensure_ascii=False))
