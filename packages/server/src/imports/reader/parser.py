"""手机备份 → 无损扫描记录；只解释已核验的 NT 分支，未知类型显式保留。

字段依据：WeQ 466ea302、2026-10-23 四会话跨端核对。
本地 msgId / clientSeq / 协议引用 ID 各自保存，不互相代用。
"""
import base64
import hashlib
import json
import re
from wire import parse_fields, first, values, text

TYPES = {1: 'text', 2: 'image', 3: 'file', 4: 'voice', 5: 'video', 6: 'face',
         7: 'reply', 8: 'system', 9: 'wallet', 10: 'card', 11: 'sticker',
         12: 'live_gift', 13: 'long_message', 14: 'markdown', 15: 'giphy',
         16: 'forward', 21: 'call', 23: 'online_file', 26: 'dynamic',
         27: 'face_bubble', 28: 'location', 49: 'bubble_video'}
MEDIA = {2, 3, 4, 5, 11, 15, 23, 27, 49}
HASH = re.compile(r'(?<![0-9a-fA-F])([0-9a-fA-F]{64}|[0-9a-fA-F]{40}|[0-9a-fA-F]{32})(?![0-9a-fA-F])')


def identifier(v):
    return str(v) if v is not None else None


def opaque(raw):
    return {'sha256': hashlib.sha256(raw).hexdigest(), 'base64': base64.b64encode(raw).decode()}


def media_ids(fields, ty):
    out = []
    for f in fields:
        if not isinstance(f.value, bytes):
            continue
        s = text(f.value)
        role = 'poster' if ty in (5, 49) and f.number in (45421, 45862) else 'main'
        if f.number in (45406, 45407, 45408, 45424, 80903) or role == 'poster':
            if s and re.fullmatch(r'[a-fA-F0-9]{32}|[a-fA-F0-9]{40}|[a-fA-F0-9]{64}', s):
                digest = s.lower()
            elif len(f.value) in (16, 20, 32):
                digest = f.value.hex()
            else:
                continue
            out.append({'algorithm': {32: 'md5', 40: 'sha1', 64: 'sha256'}[len(digest)], 'value': digest, 'role': role})
        elif s and (f.number == 45402 or (ty == 2 and f.number in (45802, 45803, 45804)) or (ty == 3 and f.number == 45954)):
            role = 'preview' if f.number in (45802, 45803, 45954) else 'main'
            for digest in HASH.findall(s):
                out.append({'algorithm': {32: 'md5', 40: 'sha1', 64: 'sha256'}[len(digest)], 'value': digest.lower(), 'role': role})
        elif f.number == 45503 and s:
            out.append({'algorithm': 'uuid', 'value': s, 'role': 'main'})
    return [dict(t) for t in dict.fromkeys(tuple(x.items()) for x in out)]


def parse_element(raw):
    f = parse_fields(raw)
    ty = first(f, 45002)
    kind = TYPES.get(ty, 'unknown_' + str(ty))
    out = {'type': ty, 'kind': kind, 'subtype': first(f,45003), 'elementId': identifier(first(f,45001)), 'raw': opaque(raw)}
    if ty == 1:
        out['text'] = text(first(f, 45101)) or ''
        uid = text(first(f, 45105))
        reserve = first(f, 45102)
        # 2026-10-19 真实 iPhone @all 与普通“@全体成员”负例：零 UID 本身不是 @all。
        if uid == 'all' or (uid == '0' and reserve == 1 and out['text'] in ('@全体成员', '@全体成员 ', '@所有人', '@所有人 ')):
            out.update(kind='mention_all', targetUid='all')
        elif uid and uid != '0':
            out.update(kind='mention', targetUid=uid)
    elif ty == 6:
        out.update(faceId=identifier(first(f, 47601)), name=text(first(f, 47602)),
                   superEmoji={str(n): identifier(first(f, n)) for n in range(47603, 47611) if first(f, n) is not None})
        if first(f, 47603) is not None or first(f, 47604) is not None or first(f, 47605) == 1:
            out['kind'] = 'super_face'
    elif ty == 7:
        out['reference'] = {k: identifier(first(f, n)) for k, n in (
            ('sequence', 47402), ('time', 47404), ('senderUin', 47403), ('senderUid', 40020),
            ('protocolMessageId', 47416), ('cacheMessageId', 47422), ('conversationSequence', 47419))}
        out['reference']['senderUid'] = text(first(f, 40020))
        out['snapshot'] = [parse_element(x) for x in values(f, 47423, 2)]
        out['quotedText'] = [text(x) for x in values(f, 47413, 2)]
    elif ty in MEDIA:
        # 2026-11-03 对照 628 张真实重叠图片：45003 与 NapCat picSubType 完全一致。
        if ty==2 and first(f,45003)==1: out['kind']='custom_sticker'
        out.update(identifiers=media_ids(f, ty), filename=text(first(f, 45402)),
                   width=first(f, 45411 if ty == 2 else 45413), height=first(f, 45412 if ty == 2 else 45414),
                   duration=first(f, 45906 if ty == 4 else 45410))
    elif ty in (10, 16):
        payload = text(first(f, 47901 if ty == 10 else 48602)) or ''
        out['payload'] = payload
        if ty == 10:
            try:
                card = json.loads(payload)
                if isinstance(card, dict):
                    out['app'] = card.get('app')
                    if card.get('app') == 'com.tencent.multimsg':
                        out['kind'] = 'forward'
                    elif card.get('app') in ('com.tencent.miniapp', 'com.tencent.miniapp_01'):
                        out['kind'] = 'miniapp'
            except ValueError:
                out['parseIssue'] = 'card_invalid_json'
        else:
            out['resourceId'] = text(first(f, 48601))
    elif ty == 26:
        uins=[identifier(x) for x in values(f,48182)]
        descriptions=[]
        for tag in (48175,48176):
            block=first(f,tag)
            fields=parse_fields(block) if isinstance(block,bytes) else []
            descriptions.append({'text':text(first(fields,48178)), 'color':text(first(fields,48179))})
        out['dynamic']={'type':first(f,48172),'id':text(first(f,48173)),
            'descriptions':descriptions,'relatedUins':uins,'publisherUid':text(first(f,48188)),
            'meta':text(first(f,48183))}
    elif ty == 8:
        # 适配成现有 grayTipSegments 的输入；不把系统事件的外层空作者当参与者。
        sub=first(f,45003)
        tip={'subElementType':sub}
        if sub==1:
            tip['revokeElement']={k:text(first(f,n)) for k,n in (
                ('operatorUid',47703),('operatorNick',47714),('operatorMemRemark',47716),
                ('origMsgSenderUid',47704),('origMsgSenderNick',47705),('origMsgSenderMemRemark',47707))}
        elif sub==10:
            tip['fileReceiptElement']={'fileName':text(first(f,45402))}
        if first(f,48214) is not None:tip['xmlElement']={'content':text(first(f,48214))}
        if first(f,48271) is not None:tip['jsonGrayTipElement']={'jsonStr':text(first(f,48271))}
        out['grayTip']=tip
        out['savedText']=text(first(f,47713)) or text(first(f,48274))
        out['interaction'] = {str(n): identifier(first(f, n)) for n in (48211, 48212, 48215, 48216) if first(f, n) is not None}
        if first(f, 48212) == 1061:
            out['kind'] = 'poke'
    elif ty == 14:
        out['text'] = text(first(f, 48701)) or text(first(f, 49099)) or ''
    return out


def children(body):
    for raw in values(body, 40900, 2):
        f = parse_fields(raw)
        if first(f, 40050) is not None or first(f, 40001) is not None:
            yield raw
        else:
            yield from values(f, 40900, 2)


def parse_body(raw, path=(), budget=None):
    if budget is None:
        budget = [0]
    budget[0] += 1
    if len(path) > 32 or budget[0] > 20000:
        raise ValueError('nested_node_budget_exceeded')
    b = parse_fields(raw)
    out = {'path': list(path), 'localId': identifier(first(b, 40001)),
           'seq': identifier(first(b, 40003)), 'clientSeq': identifier(first(b, 40005)),
           'random': identifier(first(b, 40002)), 'msgUid': identifier(first(b, 40006)),
           'time': first(b, 40050), 'senderUid': text(first(b, 40020)),
           'senderUin': identifier(first(b, 40033)), 'peerUid': text(first(b, 40021)),
           'peerUin': identifier(first(b, 40030)), 'chatType': first(b, 40010),
           'sendStatus': first(b, 40041), 'sentSource': first(b, 40040),
           'nickname': text(first(b, 40093)), 'card': text(first(b, 40090)),
           'elements': [parse_element(x) for x in values(b, 40800, 2)], 'nodes': []}
    out['nodeScope'] = 'reply_snapshot' if first(b, 40011) == 9 else 'forward_node'
    out['nodes'] = [parse_body(v, (*path, i), budget) for i, v in enumerate(children(b))]
    return out


def parse_record(table, row):
    rid, ts, seq, rnd, raw, extra = row
    envelope = parse_fields(raw or b'')
    h = parse_fields(first(envelope, 1) or b'')
    b = first(envelope, 5)
    if not isinstance(b, bytes) or not b:
        raise ValueError('nt_body_missing')
    out = parse_body(b)
    kind, peer = table.split('_')[1:]
    out.update(table=table, rowId=str(rid), time=ts, seq=str(seq), random=str(rnd),
               scene='group' if kind == '1' and out['chatType'] == 2 else 'friend' if kind == '3' and out['chatType'] == 1 else 'temp' if kind == '3' and out['chatType'] == 100 else None,
               peer=peer, sourceKey=[table, ts, str(seq), str(rnd)],
               rawSha256=hashlib.sha256(raw or b'').hexdigest())
    out['senderUin'] = out['senderUin'] if out['senderUin'] not in (None, '0') else identifier(first(h, 1))
    body = parse_fields(b)
    out['bodyIdentity'] = {'time': first(body, 40050), 'seq': identifier(first(body, 40003)), 'random': identifier(first(body, 40002))}
    out['identityDisagreement'] = out['bodyIdentity'] != {'time': ts, 'seq': str(seq), 'random': str(rnd)}
    # 源账号由请求显式声明；本机成功发送记录还要核对发送者，不从目录哈希推账号。
    return out


def walk(record):
    yield record
    for node in record['nodes']:
        yield from walk(node)


def compact(record):
    """只在 IPC 中去掉可随时从源行重新读取的原字节，不复制整库明文。"""
    for node in walk(record):
        for element in node['elements']:
            element['raw'].pop('base64', None)
            for snap in element.get('snapshot', []):
                snap['raw'].pop('base64', None)
    return record
