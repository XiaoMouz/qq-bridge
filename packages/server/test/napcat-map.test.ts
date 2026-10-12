import { messageFlags, MessageFlag, plainText } from '@qqbridge/domain';
import { describe, expect, it } from 'vitest';
import { eventKind, mapNapcatEvent, mapRawMessage, parseForwardXml } from '../src/upstream/napcat/map.ts';
import { el, messageEvent, raw } from './helpers/napcat.ts';

const SELF = 10001;
const MD5_A = '0123456789abcdef0123456789abcdef';
const MD5_B = 'fedcba9876543210fedcba9876543210';

describe('NapCat mapping', () => {
  it('maps a group message: real seq, mentions, faces, reply, image with its live URL and locator, peers', () => {
    const r = raw({
      chatType: 2,
      peer: '123456',
      seq: 9001,
      sender: '20002',
      peerName: '测试群',
      elements: [
        el.reply(8990, '30003'),
        el.at(String(SELF), '我'),
        el.text(' 看这个 '),
        el.face(14),
        el.face(5, 3),
        el.pic({ md5: MD5_A, size: 34567, w: 1920, h: 1080 }),
      ],
    });
    const fileName = `${MD5_A.toUpperCase()}.jpg`;
    const action = mapNapcatEvent(
      messageEvent(r, {
        ob11: [
          { type: 'reply', data: { id: '1' } },
          { type: 'at', data: { qq: String(SELF) } },
          { type: 'text', data: { text: ' 看这个 ' } },
          { type: 'face', data: { id: '14' } },
          { type: 'face', data: { id: '5' } },
          { type: 'image', data: { file: fileName, url: 'https://multimedia.nt.qq.com.cn/download?rkey=abc', file_size: '34567' } },
        ],
      }),
      SELF,
    );
    expect(action.type).toBe('message');
    if (action.type !== 'message') return;
    const m = action.message;
    expect(m).toMatchObject({ scene: 'group', peerId: 123456, seq: 9001, senderId: 20002, time: 1_700_009_001, self: false, source: 'realtime' });
    expect(m.qqMsgId).toBe(r.msgId);
    expect(m.raw).toBe(r);
    expect(m.segments).toEqual([
      { type: 'reply', seq: 8990, senderId: 30003 },
      { type: 'mention', userId: SELF, name: '我' },
      { type: 'text', text: ' 看这个 ' },
      { type: 'face', faceId: '14' },
      { type: 'face', faceId: '5', isLarge: true },
      { type: 'image', media: { ord: 0, state: 'pending', width: 1920, height: 1080 }, width: 1920, height: 1080, subType: 'normal' },
    ]);
    expect(m.media).toEqual([
      {
        ord: 0,
        kind: 'image',
        role: 'attachment',
        qqMd5: MD5_A,
        qqFileUuid: `uuid-${MD5_A.slice(0, 8)}`,
        size: 34567,
        name: fileName,
        url: 'https://multimedia.nt.qq.com.cn/download?rkey=abc',
        locator: {
          chatType: 2,
          peerUid: '123456',
          msgId: r.msgId,
          elementId: r.elements![5]!.elementId,
          elementType: 2,
          originImageUrl: `/download?appid=1407&fileid=${MD5_A.slice(0, 12)}`,
          md5HexStr: MD5_A.toUpperCase(),
        },
      },
    ]);
    // 下游的标志位与纯文本照常计算（@我、图片）。
    expect(messageFlags(m.segments, SELF) & MessageFlag.mentionsMe).toBeTruthy();
    expect(messageFlags(m.segments, SELF) & MessageFlag.photo).toBeTruthy();
    expect(plainText(m.segments)).toContain('看这个');
    expect(action.peers).toEqual([
      { kind: 'group', peerId: 123456, name: '测试群' },
      { kind: 'user', peerId: 20002, uid: 'u_20002', name: 'nick-20002' },
    ]);
  });

  it('maps messages I sent from another device, including private chats', () => {
    const r = raw({ chatType: 1, peer: '30003', seq: 77, sender: String(SELF), elements: [el.text('晚点聊')] });
    const action = mapNapcatEvent(messageEvent(r, { self: true }), SELF);
    expect(action).toMatchObject({ type: 'message', message: { scene: 'friend', peerId: 30003, senderId: SELF, self: true } });
  });

  it('maps voice, video, files (full or 10 MB md5), market faces, forwards, ark and keeps unknown elements', () => {
    const r = raw({
      chatType: 1,
      peer: '30003',
      seq: 5,
      sender: '30003',
      elements: [
        el.ptt({ md5: MD5_A, size: 4000, duration: 7 }),
        el.video({ md5: MD5_B, size: 900_000, w: 720, h: 1280, seconds: 15 }),
        el.file({ name: 'a.pdf', size: 12345, md5: MD5_A }),
        el.file({ name: 'big.zip', size: 300_000_000, head: MD5_B }),
        el.mface('abcdef0123456789abcdef0123456789', '[开心]'),
        el.forward('res-1', '<msg><item><title size="34">群聊的聊天记录</title><title>A: 你好 &amp; 再见</title><summary>查看3条转发消息</summary></item></msg>'),
        el.ark(JSON.stringify({ app: 'com.tencent.miniapp', prompt: '[小程序]' })),
        el.unknown(19),
      ],
    });
    const action = mapRawMessage(r, {
      selfUin: SELF,
      source: 'realtime',
      ob11: [
        { type: 'record', data: { url: 'https://grouptalk.c2c.qq.com/ptt?x=1' } },
        { type: 'video', data: { url: '/root/.config/QQ/video.mp4' } }, // 本地路径（NapCat 换链接失败时）不用
        { type: 'file', data: { url: 'https://example.qq.com/a.pdf' } },
      ],
    });
    if (action.type !== 'message') throw new Error(action.type);
    const { segments, media } = action.message;
    expect(segments.map((s) => s.type)).toEqual(['record', 'video', 'file', 'file', 'market_face', 'forward', 'light_app', 'unknown']);
    expect(segments[0]).toMatchObject({ durationSec: 7, media: { ord: 0 } });
    expect(segments[1]).toMatchObject({ width: 720, height: 1280, durationSec: 15, media: { ord: 1, width: 720, height: 1280 } });
    expect(segments[3]).toMatchObject({ type: 'file', name: 'big.zip', size: 300_000_000, media: { ord: 3 } });
    expect(segments[4]).toMatchObject({ type: 'market_face', emojiId: 'abcdef0123456789abcdef0123456789', summary: '[开心]', media: { ord: 4 } });
    expect(segments[5]).toEqual({
      type: 'forward',
      forwardId: 'res-1',
      title: '群聊的聊天记录',
      preview: ['A: 你好 & 再见'],
      summary: '查看3条转发消息',
    });
    expect(segments[6]).toMatchObject({ type: 'light_app', appName: 'com.tencent.miniapp' });
    expect(segments[7]).toMatchObject({ type: 'unknown', original: 'nt:19', data: { calendarElement: { summary: 'x' } } });

    expect(media.map((m) => [m.ord, m.kind, m.url ?? null])).toEqual([
      [0, 'audio', 'https://grouptalk.c2c.qq.com/ptt?x=1'],
      [1, 'video', null],
      [2, 'file', 'https://example.qq.com/a.pdf'],
      [3, 'file', null],
      [4, 'sticker', 'https://gxh.vip.qq.com/club/item/parcel/item/ab/abcdef0123456789abcdef0123456789/raw300.gif'],
    ]);
    expect(media[2]).toMatchObject({ qqMd5: MD5_A, size: 12345, name: 'a.pdf' });
    expect(media[2]!.qqMd5Partial).toBeUndefined();
    expect(media[3]).toMatchObject({ qqMd5: MD5_B, qqMd5Partial: true, size: 300_000_000 });
    expect(media[3]!.locator).toMatchObject({ elementType: 3, fileUuid: '/file-big.zip', file10MMd5: MD5_B, peerUid: 'u_30003' });
    expect(media[1]!.locator).toMatchObject({ elementType: 5, fileUuid: `video-${MD5_B.slice(0, 6)}` });
  });

  it('keeps face names, hides bot keyboards and strips the markdown metadata link', () => {
    const r = raw({
      chatType: 2,
      peer: '123456',
      seq: 77,
      sender: '20002',
      elements: [
        { ...el.face(474, 3), faceElement: { faceIndex: 474, faceType: 3, faceText: '/给你一拳' } },
        { elementType: 14, elementId: '9001', markdownElement: { content: '[](%7B%22version%22%3A2%7D)\n# 签到成功' } },
        { elementType: 17, elementId: '9002' },
      ],
    });
    const action = mapRawMessage(r, { selfUin: SELF, source: 'realtime' });
    if (action.type !== 'message') throw new Error(action.type);
    const { segments } = action.message;
    expect(segments[0]).toEqual({ type: 'face', faceId: '474', isLarge: true, name: '给你一拳' });
    expect(segments[1]).toEqual({ type: 'markdown', content: '# 签到成功' });
    expect(segments[2]).toMatchObject({ type: 'unknown', original: 'keyboard' });
    expect(plainText(segments)).toBe('[给你一拳]签到成功');
  });

  it('maps a merged-forward card (com.tencent.multimsg) to a forward that can be opened', () => {
    const card = JSON.stringify({
      app: 'com.tencent.multimsg',
      meta: { detail: { resid: 'RES123', source: '群聊的聊天记录', summary: '查看2条转发消息', news: [{ text: 'A: 你好' }, { text: 'B: [图片]' }] } },
    });
    const action = mapRawMessage(raw({ chatType: 2, peer: '123456', seq: 88, sender: '20002', elements: [el.ark(card)] }), { selfUin: SELF, source: 'realtime' });
    if (action.type !== 'message') throw new Error(action.type);
    expect(action.message.segments).toEqual([
      { type: 'forward', forwardId: 'RES123', title: '群聊的聊天记录', preview: ['A: 你好', 'B: [图片]'], summary: '查看2条转发消息' },
    ]);
  });

  it('fills in element types that packet-parsed forwards leave at 0', () => {
    const text = { ...el.text('军团还是联盟'), elementType: 0 };
    const action = mapRawMessage(raw({ chatType: 2, peer: '123456', seq: 89, sender: '20002', elements: [text] }), { selfUin: SELF, source: 'backfill' });
    if (action.type !== 'message') throw new Error(action.type);
    expect(action.message.segments).toEqual([{ type: 'text', text: '军团还是联盟' }]);
  });

  it('keeps the sender display name (group card first) for list previews', () => {
    const r = { ...raw({ chatType: 2, peer: '123456', seq: 90, sender: '20002', elements: [el.text('hi')] }), sendMemberName: '群名片', sendNickName: '昵称' };
    const action = mapRawMessage(r, { selfUin: SELF, source: 'realtime' });
    if (action.type !== 'message') throw new Error(action.type);
    expect(action.message.senderName).toBe('群名片');
  });

  it('maps history messages without OneBot segments: no URL, but a locator to fetch one later', () => {
    const r = raw({ chatType: 2, peer: '123456', seq: 100, sender: '20002', elements: [el.pic({ md5: MD5_B, size: 10, w: 1, h: 1, sticker: true })] });
    const action = mapRawMessage(r, { selfUin: SELF, source: 'backfill' });
    if (action.type !== 'message') throw new Error(action.type);
    expect(action.message.source).toBe('backfill');
    expect(action.message.segments[0]).toMatchObject({ type: 'image', subType: 'sticker' });
    expect(action.message.media[0]).toMatchObject({ kind: 'image', role: 'sticker', qqMd5: MD5_B });
    expect(action.message.media[0]!.url).toBeUndefined();
    expect(action.message.media[0]!.locator).toMatchObject({ elementType: 2, md5HexStr: MD5_B.toUpperCase() });
  });

  it('maps recalls using the seq the plugin attached, and ignores what it cannot place', () => {
    expect(
      mapNapcatEvent(
        { post_type: 'notice', notice_type: 'group_recall', group_id: 123456, user_id: 20002, operator_id: 40004, message_id: 5, time: 1_700_000_100, qqbridge: { recalled: { msgSeq: '9001' } } },
        SELF,
      ),
    ).toEqual({ type: 'recall', scene: 'group', peerId: 123456, seq: 9001, operatorId: 40004, time: 1_700_000_100 });
    expect(
      mapNapcatEvent(
        { post_type: 'notice', notice_type: 'friend_recall', user_id: 30003, message_id: 6, time: 1_700_000_200, qqbridge: { recalled: { msgSeq: '77', peerUin: '30003' } } },
        SELF,
      ),
    ).toEqual({ type: 'recall', scene: 'friend', peerId: 30003, seq: 77, operatorId: 30003, time: 1_700_000_200 });
    expect(mapNapcatEvent({ post_type: 'notice', notice_type: 'group_recall', group_id: 1, message_id: 7 }, SELF)).toMatchObject({ type: 'ignore' });

    expect(mapNapcatEvent({ post_type: 'notice', notice_type: 'group_increase' }, SELF)).toMatchObject({ type: 'ignore' });
    expect(mapNapcatEvent({ post_type: 'message', message_type: 'group' }, SELF)).toMatchObject({
      type: 'ignore',
      reason: expect.stringContaining('without raw'),
    });
    const dataLine = raw({ chatType: 8, peer: '0', seq: 1, sender: String(SELF), elements: [el.text('文件传输')] });
    expect(mapRawMessage(dataLine, { selfUin: SELF, source: 'realtime' })).toMatchObject({ type: 'ignore', reason: 'unsupported chatType 8' });
    expect(eventKind({ post_type: 'notice', notice_type: 'group_recall' })).toBe('notice.group_recall');
    expect(eventKind(messageEvent(dataLine))).toBe('message.private');
  });

  it('maps group notices to service events with the right actor, target and details', () => {
    const base = { post_type: 'notice', time: 1_700_000_500, self_id: SELF, group_id: 123456 };
    const ev = (extra: Record<string, unknown>) => mapNapcatEvent({ ...base, ...extra }, SELF);
    expect(ev({ notice_type: 'group_increase', sub_type: 'invite', user_id: 20002, operator_id: 30003 })).toEqual({
      type: 'chatEvent',
      event: { scene: 'group', peerId: 123456, kind: 'member_join', time: 1_700_000_500, actorId: 30003, targetId: 20002, data: { via: 'invite' } },
    });
    expect(ev({ notice_type: 'group_decrease', sub_type: 'kick', user_id: 20002, operator_id: 30003 })).toMatchObject({
      event: { kind: 'member_leave', actorId: 30003, targetId: 20002, data: { how: 'kick' } },
    });
    expect(ev({ notice_type: 'group_admin', sub_type: 'unset', user_id: 20002 })).toMatchObject({ event: { kind: 'admin_unset', targetId: 20002 } });
    expect(ev({ notice_type: 'group_ban', sub_type: 'ban', user_id: 0, operator_id: 30003, duration: 0 })).toMatchObject({
      event: { kind: 'mute', actorId: 30003, data: { duration: 0, all: true } },
    });
    expect(ev({ notice_type: 'group_ban', sub_type: 'lift_ban', user_id: 20002, operator_id: 30003, duration: 0 })).toMatchObject({
      event: { kind: 'unmute', targetId: 20002 },
    });
    expect(ev({ notice_type: 'group_card', user_id: 20002, card_new: '新名片', card_old: '旧名片' })).toMatchObject({
      event: { kind: 'card_change', data: { cardNew: '新名片', cardOld: '旧名片' } },
    });
    // QQ 把邀请入群灰条塞进名片缓存：不是真改名片。
    expect(ev({ notice_type: 'group_card', user_id: SELF, card_new: '', card_old: '青空Isaac邀请冬麦yoki进入了群聊，点击欢迎...' })).toMatchObject({ type: 'ignore' });
    expect(ev({ notice_type: 'group_card', user_id: 20002, card_new: '某某邀请了“小季”加入群聊点击欢迎', card_old: '' })).toMatchObject({ type: 'ignore' });
    expect(ev({ notice_type: 'group_upload', user_id: 20002, file: { id: 'enc', name: 'a.pdf', size: 1234, busid: 102 } })).toMatchObject({
      event: { kind: 'group_file', actorId: 20002, data: { name: 'a.pdf', size: 1234, fileId: 'enc', busid: 102 } },
    });
    expect(ev({ notice_type: 'notify', sub_type: 'title', user_id: 20002, title: '龙王' })).toMatchObject({ event: { kind: 'title', data: { title: '龙王' } } });
    expect(ev({ notice_type: 'notify', sub_type: 'group_name', user_id: 30003, name_new: '新群名' })).toMatchObject({
      event: { kind: 'group_name', actorId: 30003, data: { name: '新群名' }, peers: [{ kind: 'group', peerId: 123456, name: '新群名' }] },
    });
    expect(ev({ notice_type: 'notify', sub_type: 'poke', user_id: 20002, target_id: SELF, raw_info: [{ txt: '戳了戳' }] })).toMatchObject({
      event: { scene: 'group', kind: 'poke', actorId: 20002, targetId: SELF },
    });
  });

  it('maps essence, reactions, private pokes, typing and new friends', () => {
    const resolved = { qqbridge: { message: { msgSeq: '9001' } } };
    expect(
      mapNapcatEvent({ post_type: 'notice', notice_type: 'essence', sub_type: 'add', group_id: 1, operator_id: 3, sender_id: 2, message_id: 5, time: 10, ...resolved }, SELF),
    ).toMatchObject({ type: 'chatEvent', event: { kind: 'essence_add', actorId: 3, targetId: 2, refSeq: 9001 } });
    expect(
      mapNapcatEvent(
        { post_type: 'notice', notice_type: 'group_msg_emoji_like', group_id: 1, user_id: SELF, message_id: 5, likes: [{ emoji_id: '76', count: 2 }], is_add: true, ...resolved },
        SELF,
      ),
    ).toEqual({
      type: 'reaction',
      scene: 'group',
      peerId: 1,
      seq: 9001,
      change: { likes: [{ emojiId: '76', count: 2 }], byMe: true, isAdd: true },
    });
    expect(mapNapcatEvent({ post_type: 'notice', notice_type: 'group_msg_emoji_like', group_id: 1, message_id: 5, likes: [] }, SELF)).toMatchObject({
      type: 'ignore',
    });
    // 私聊戳一戳：会话是对方，不管是谁戳谁。
    expect(mapNapcatEvent({ post_type: 'notice', notice_type: 'notify', sub_type: 'poke', user_id: SELF, target_id: 30003 }, SELF)).toMatchObject({
      event: { scene: 'friend', peerId: 30003, kind: 'poke', actorId: SELF, targetId: 30003 },
    });
    expect(mapNapcatEvent({ post_type: 'notice', notice_type: 'notify', sub_type: 'poke', user_id: 30003, target_id: SELF }, SELF)).toMatchObject({
      event: { scene: 'friend', peerId: 30003 },
    });
    expect(mapNapcatEvent({ post_type: 'notice', notice_type: 'notify', sub_type: 'input_status', user_id: 30003, status_text: '对方正在输入...' }, SELF)).toEqual({
      type: 'typing',
      scene: 'friend',
      peerId: 30003,
      userId: 30003,
      text: '对方正在输入...',
    });
    expect(mapNapcatEvent({ post_type: 'notice', notice_type: 'friend_add', user_id: 30003, time: 10 }, SELF)).toMatchObject({
      event: { scene: 'friend', peerId: 30003, kind: 'friend_add', peers: [{ kind: 'user', peerId: 30003, isFriend: true }] },
    });
    expect(mapNapcatEvent({ post_type: 'notice', notice_type: 'notify', sub_type: 'profile_like', operator_id: 1 }, SELF)).toMatchObject({ type: 'ignore' });
  });

  it('parses forward previews defensively', () => {
    expect(parseForwardXml('')).toEqual({});
    expect(parseForwardXml('<title>&#20320;&lt;b&gt;</title>')).toEqual({ title: '你<b>' });
  });

  it('passes call bridge states through and ignores malformed ones', () => {
    const call = { callId: 'c', phase: 'ringing', inviteAt: '2026-10-04T00:00:00Z' };
    expect(mapNapcatEvent({ post_type: 'qqbridge_call', call } as never, 1)).toEqual({ type: 'call', state: call });
    expect(mapNapcatEvent({ post_type: 'qqbridge_call' } as never, 1)).toMatchObject({ type: 'ignore' });
    expect(eventKind({ post_type: 'qqbridge_call' } as never)).toBe('qqbridge_call');
  });
});

describe('marketFacePng', () => {
  it('turns a market face gif link into the static png of the same face', async () => {
    const { marketFacePng } = await import('../src/upstream/napcat/media-source.ts');
    expect(marketFacePng('https://gxh.vip.qq.com/club/item/parcel/item/34/344d33bc6b1d9f31db0ce55f75dc3c48/raw300.gif')).toBe(
      'https://gxh.vip.qq.com/club/item/parcel/item/34/344d33bc6b1d9f31db0ce55f75dc3c48/300x300.png',
    );
    expect(marketFacePng('https://multimedia.nt.qq.com.cn/download?fileid=x')).toBeNull();
  });
});
