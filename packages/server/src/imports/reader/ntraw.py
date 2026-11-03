"""手机备份的一行 → NapCat 形状的 NT 原始消息（NtRawMessage），交给服务端现有的 mapRawMessage。

字段号依据：2026-11-04 重叠窗口 18020 条「备份与生产为同一条」的消息逐字段比对（备份 protobuf 取值 == 生产 raw 取值），
每个字段取覆盖接近全部样本的唯一对应；没在样本里核对过的字段不填，元素原文（base64）留在 backupElement 里，
映射器认不出的类型按未知元素保留。不用本地 msgId：它是手机端的本地编号，和 NapCat 的不同；elementId 填元素下标（见 element）。
"""
import base64
from wire import parse_fields, first, values, text

# (NT 字段名, 备份字段号, 取值方式)。取值方式：s 字符串、i 整数、h 摘要（小写十六进制）。
ELEMENT_FIELDS = {
    1: ('textElement', [('content', 45101, 's'), ('atType', 45102, 'i'), ('atUid', 45103, 's'), ('atNtUid', 45105, 's')]),
    2: ('picElement', [('fileName', 45402, 's'), ('fileSize', 45405, 's'), ('fileUuid', 45503, 's'), ('picWidth', 45411, 'i'),
                       ('picHeight', 45412, 'i'), ('md5HexStr', 45406, 'h'), ('originImageUrl', 45804, 's'), ('picType', 45416, 'i'),
                       ('picSubType', 45003, 'i'), ('summary', 45815, 's'), ('originImageMd5', 45424, 'h'), ('original', 45418, 'i')]),
    3: ('fileElement', [('fileName', 45402, 's'), ('fileSize', 45405, 's'), ('fileUuid', 45503, 's')]),
    4: ('pttElement', [('duration', 45906, 'i'), ('fileName', 45402, 's'), ('fileSize', 45405, 's'), ('fileUuid', 45503, 's'),
                       ('md5HexStr', 45406, 'h')]),
    5: ('videoElement', [('fileName', 45402, 's'), ('fileSize', 45405, 's'), ('fileTime', 45410, 'i'), ('fileUuid', 45503, 's'),
                         ('videoMd5', 45406, 'h'), ('thumbMd5', 45862, 'h'), ('thumbSize', 45415, 'i'),
                         ('thumbWidth', 45413, 'i'), ('thumbHeight', 45414, 'i')]),
    6: ('faceElement', [('faceIndex', 47601, 'i'), ('faceType', 45003, 'i'), ('faceText', 47602, 's'), ('stickerType', 47606, 'i'),
                        ('packId', 47603, 's'), ('stickerId', 47604, 's'), ('sourceType', 47605, 'i')]),
    10: ('arkElement', [('bytesData', 47901, 's')]),
    11: ('marketFaceElement', [('key', 80824, 's'), ('emojiId', 80903, 'h'), ('faceName', 80900, 's'), ('emojiType', 80935, 'i'),
                               ('emojiPackageId', 80810, 'i'), ('subType', 80905, 'i'), ('itemType', 80901, 'i'),
                               ('imageWidth', 80909, 'i'), ('imageHeight', 80910, 'i')]),
    14: ('markdownElement', [('content', 48701, 's')]),
}


def _value(raw, how):
    if raw is None: return None
    if how == 'i': return raw if isinstance(raw, int) else None
    if how == 's':
        if isinstance(raw, int): return str(raw)
        return text(raw)
    # 摘要：有的写成 32 位十六进制文字，有的是 16 字节原始值。
    if isinstance(raw, int): return None
    s = text(raw)
    if s and all(c in '0123456789abcdefABCDEF' for c in s) and len(s) in (32, 40, 64): return s.lower()
    return raw.hex() if len(raw) in (16, 20, 32) else None


def _fields(f, spec):
    out = {}
    for name, number, how in spec:
        v = _value(first(f, number), how)
        if v not in (None, ''): out[name] = v
    return out


def element(raw, scene, gray_tip, index=0):
    f = parse_fields(raw)
    ty = first(f, 45002)
    # elementId 用元素下标：导入时据此把映射出的媒体（IncomingMedia.locator.elementId）对回预检的关联结论。
    out = {'elementType': ty, 'elementId': str(index)}
    if ty in ELEMENT_FIELDS:
        name, spec = ELEMENT_FIELDS[ty]
        out[name] = _fields(f, spec)
    elif ty == 7:
        # 2026-11-04 实测：群里 47402 是被回复消息的 seq（2230/2230）；私聊里 seq 在 47419（26/26），47402 是 clientSeq。
        seq = first(f, 47402 if scene == 'group' else 47419)
        reply = {'replayMsgSeq': str(seq) if seq else None, 'replyMsgTime': _value(first(f, 47404), 's'),
                 'senderUid': _value(first(f, 47403), 's'), 'senderUidStr': text(first(f, 40020))}
        if scene != 'group' and first(f, 47402): reply['replyMsgClientSeq'] = str(first(f, 47402))
        out['replyElement'] = {k: v for k, v in reply.items() if v not in (None, '')}
    elif ty == 8 and gray_tip is not None:
        out['grayTipElement'] = gray_tip
    # 映射器认不全的类型留原文，以后支持了可以从 raw 重新映射；认得的不留，免得每条消息都多一份原始字节。
    if ty not in ELEMENT_FIELDS and ty != 7: out['backupElement'] = base64.b64encode(raw).decode()
    return out


def _message(body, scene, peer, tips, sender_uin, seq, rnd, ts, chat_type):
    out = {
        'msgRandom': str(rnd) if rnd is not None else None, 'msgSeq': str(seq) if seq is not None else None,
        'msgTime': str(ts) if ts is not None else None,
        'chatType': chat_type, 'senderUid': text(first(body, 40020)), 'senderUin': str(sender_uin) if sender_uin else None,
        'peerUid': text(first(body, 40021)), 'peerUin': str(first(body, 40030) or peer),
        'sendStatus': first(body, 40041), 'msgType': first(body, 40011), 'subMsgType': first(body, 40012),
        'clientSeq': str(first(body, 40005)) if first(body, 40005) else None,
        'sendMemberName': text(first(body, 40090)), 'sendNickName': text(first(body, 40093)),
        'elements': [element(e, scene, tips[i] if i < len(tips) else None, i) for i, e in enumerate(values(body, 40800, 2))],
    }
    return {k: v for k, v in out.items() if v not in (None, '')}


def nt_raw(table, row, record, seq_override=None):
    """record 是 parser.parse_record 的结果（灰条已经解析成 grayTipElement 形状）；row 是源表原行。"""
    _, ts, seq, rnd, raw, _ = row
    envelope = parse_fields(raw or b'')
    body = parse_fields(first(envelope, 5) or b'')
    header = parse_fields(first(envelope, 1) or b'')
    out = _message(body, record['scene'], table.split('_')[2], [e.get('grayTip') for e in record['elements']],
                   first(body, 40033) or first(header, 1), seq_override if seq_override is not None else seq, rnd, ts, first(body, 40010))
    out['backupSource'] = {'table': table, 'time': ts, 'seq': str(seq), 'random': str(rnd)}
    if seq_override is not None: out['backupSource']['seqReassigned'] = True
    return out


def nt_node(raw, node, scene, peer, chat_type):
    """合并转发里的一个节点（parser.parse_body 的结果 + 原字节）。节点的 seq 只用于映射，不入会话。"""
    body = parse_fields(raw)
    # 映射器要求有 seq；节点没有时给 1（节点按下标存，不按 seq）。
    return _message(body, scene, peer, [e.get('grayTip') for e in node['elements']], first(body, 40033),
                    first(body, 40003) or 1, first(body, 40002), first(body, 40050), first(body, 40010) or chat_type)
