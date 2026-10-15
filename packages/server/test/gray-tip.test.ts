// 灰色提示：样本取自 2026-10-15 库里的真实数据（人名、uid 已换掉）。
import { serviceText } from '@qqbridge/domain';
import { describe, expect, it } from 'vitest';
import { mapRawMessage } from '../src/upstream/napcat/map.ts';
import { raw } from './helpers/napcat.ts';

const SELF = 10001;

function tip(grayTipElement: unknown, chatType: 1 | 2 = 2) {
  const action = mapRawMessage(
    raw({ chatType, peer: chatType === 2 ? '123456' : '20002', seq: 77, sender: chatType === 2 ? '0' : '20002', elements: [{ elementType: 8, elementId: '1', grayTipElement } as never] }),
    { selfUin: SELF, source: 'realtime' },
  );
  if (action.type !== 'message') throw new Error(action.type);
  return action.message;
}

describe('gray tips', () => {
  it('revoke with a wording becomes a service line', () => {
    const m = tip({
      subElementType: 1,
      revokeElement: { operatorUid: 'u_a', operatorNick: '甲', operatorMemRemark: '甲的群名片', origMsgSenderUid: 'u_a', isSelfOperate: false, wording: '因为有错别字。\t' },
    });
    expect(m.kind).toBe('service');
    expect(m.segments).toEqual([
      { type: 'mention', userId: 0, name: '甲的群名片', uid: 'u_a' },
      { type: 'text', text: ' 撤回了一条消息' },
      { type: 'text', text: '，因为有错别字。' },
    ]);
    expect(serviceText(m.segments)).toBe('甲的群名片 撤回了一条消息，因为有错别字。');
  });

  it('admin revoking someone else names both', () => {
    const m = tip({ subElementType: 1, revokeElement: { operatorUid: 'u_a', operatorNick: '管理', origMsgSenderUid: 'u_b', origMsgSenderNick: '乙' } });
    expect(serviceText(m.segments)).toBe('管理 撤回了 乙 的一条消息');
  });

  it('file receipt in a private chat', () => {
    const m = tip({ subElementType: 10, fileReceiptElement: { fileName: 'Kazumi_android_2.3.8.apk.1' } }, 1);
    expect(m.kind).toBe('service');
    expect(serviceText(m.segments)).toBe('对方已接收文件「Kazumi_android_2.3.8.apk.1」');
  });

  it('member join', () => {
    const m = tip({ subElementType: 4, groupElement: { type: 1, memberUid: 'u_c', memberNick: 'Tazz', memberAdd: { otherAdd: { uid: 'u_c', name: 'Tazz' } } } });
    expect(serviceText(m.segments)).toBe('Tazz 加入了群聊');
  });

  it('xml reaction tip keeps the QQ number from jp', () => {
    const m = tip({
      subElementType: 12,
      xmlElement: { content: '<gtip align="center"> <qq uin="u_d" col="3" jp="3865801565"/> <nor txt="回应了你的"/> <url jp= "" msgseq="5506" col="3" txt="消息:"/>  <face type="2" id="10060">  </face> </gtip>' },
    });
    expect(m.segments[0]).toEqual({ type: 'mention', userId: 3865801565, uid: 'u_d' });
    expect(serviceText(m.segments)).toBe('3865801565 回应了你的消息:[表情]');
  });

  it('json nudge tip keeps uids for the ingest to resolve', () => {
    const jsonStr = JSON.stringify({
      align: 'center',
      items: [
        { col: '1', nm: '', type: 'qq', uid: 'u_e' },
        { jp: 'https://zb.vip.qq.com/', src: 'http://tianquan.gtimg.cn/x.jpg', type: 'img' },
        { txt: '拍了拍', type: 'nor' },
        { col: '1', nm: '', tp: '0', type: 'qq', uid: 'u_f' },
        { txt: '的头，并亲了一口', type: 'nor' },
      ],
    });
    const m = tip({ subElementType: 17, jsonGrayTipElement: { busiId: '1061', jsonStr } });
    expect(m.kind).toBe('service');
    expect(serviceText(m.segments)).toBe('某人 拍了拍 某人 的头，并亲了一口');
  });

  it('unknown subtypes stay unknown and keep the original', () => {
    const m = tip({ subElementType: 99 });
    expect(m.kind).toBeUndefined();
    expect(m.segments[0]).toMatchObject({ type: 'unknown', original: 'nt:8' });
  });
});

describe('unsupported elements text', () => {
  it('red packets and long messages read as words, others keep the type', async () => {
    const { plainText } = await import('@qqbridge/domain');
    expect(plainText([{ type: 'unknown', original: 'nt:9', data: { walletElement: { receiver: { title: '恭喜发财' } } } }])).toBe('[QQ红包] 恭喜发财');
    expect(plainText([{ type: 'unknown', original: 'nt:13', data: {} }])).toBe('[长消息]');
    expect(plainText([{ type: 'unknown', original: 'nt:21', data: {} }])).toBe('[nt:21]');
  });
});
