// QQ 的灰色提示（elementType 8，grayTipElement）→ 一行系统提示（文字 + 人）。
// 只处理 2026-10-15 在库里抓到过样本的子类型（subElementType），其余仍按未知元素保留原文：
//   1  撤回（revokeElement）：群里 853 条，例「法外张徒狂三 撤回了一条消息」，wording 是撤回时附的话（「因为有错别字。」）。
//   4  进群（groupElement，type 1 + memberAdd）：6 条。adminNick 的含义（邀请人 / 审批人）没核实，只写「某某 加入了群聊」。
//   10 文件已接收（fileReceiptElement）：私聊 1 条（林义涛收下了 5 天前发给他的 apk），发送者是收文件的人。
//   12 xml 提示（xmlElement，<gtip> 模板 10382）：3 条「回应了你的消息」，人用 <qq jp=号码>。
//   17 json 提示（jsonGrayTipElement）：busiId 1061 拍一拍（自定义后缀）23 条、2401 设精华，人只有 uid。
import type { Scene, Segment } from '@qqbridge/domain';

type Tip = Extract<Segment, { type: 'text' } | { type: 'mention' }>;

interface Revoke {
  operatorUid?: string;
  operatorNick?: string;
  operatorRemark?: string;
  operatorMemRemark?: string;
  isSelfOperate?: boolean;
  origMsgSenderUid?: string;
  origMsgSenderNick?: string;
  origMsgSenderRemark?: string;
  origMsgSenderMemRemark?: string;
  wording?: string;
}

interface GrayTipElement {
  subElementType?: number;
  revokeElement?: Revoke;
  groupElement?: { type?: number; memberUid?: string; memberNick?: string; memberRemark?: string; memberAdd?: unknown };
  fileReceiptElement?: { fileName?: string };
  xmlElement?: { content?: string };
  jsonGrayTipElement?: { jsonStr?: string };
}

/** 认得的灰条返回提示的各段；认不得返回 null（调用方按未知元素保留）。 */
export function grayTipSegments(element: unknown, scene: Scene): Tip[] | null {
  const g = (element ?? {}) as GrayTipElement;
  switch (g.subElementType) {
    case 1:
      return g.revokeElement ? revoke(g.revokeElement) : null;
    case 4: {
      const e = g.groupElement;
      if (!e || e.type !== 1 || !e.memberAdd) return null;
      return [person(e.memberUid, e.memberRemark || e.memberNick), text(' 加入了群聊')];
    }
    case 10: {
      const name = g.fileReceiptElement?.fileName;
      if (scene !== 'friend' || !name) return null;
      return [text(`对方已接收文件「${name}」`)];
    }
    case 12:
      return g.xmlElement?.content ? xmlTip(g.xmlElement.content) : null;
    case 17:
      return g.jsonGrayTipElement?.jsonStr ? jsonTip(g.jsonGrayTipElement.jsonStr) : null;
    default:
      return null;
  }
}

function revoke(r: Revoke): Tip[] {
  const operator = r.isSelfOperate ? text('你') : person(r.operatorUid, r.operatorRemark || r.operatorMemRemark || r.operatorNick);
  const other = r.origMsgSenderUid && r.origMsgSenderUid !== r.operatorUid;
  return [
    operator,
    ...(other
      ? [text(' 撤回了 '), person(r.origMsgSenderUid, r.origMsgSenderRemark || r.origMsgSenderMemRemark || r.origMsgSenderNick), text(' 的一条消息')]
      : [text(' 撤回了一条消息')]),
    // 附言（「因为有错别字。」「并坏笑了一下。」）：以标点开头的直接接上，否则加个逗号。
    ...(r.wording?.trim() ? [text(/^[\p{P}\s]/u.test(r.wording.trim()) ? r.wording.trim() : `，${r.wording.trim()}`)] : []),
  ];
}

/** <gtip> 模板：<qq uin="u_…" jp="号码"/>、<nor txt=""/>、<url txt=""/>、<face id=""/>，按出现顺序拼。 */
function xmlTip(xml: string): Tip[] | null {
  if (!/^\s*<gtip[\s>]/.test(xml)) return null;
  const out: Tip[] = [];
  for (const m of xml.matchAll(/<(qq|nor|url|face|img)\b([^>]*?)\/?>/g)) {
    const attrs = attributes(m[2] ?? '');
    switch (m[1]) {
      case 'qq':
        out.push(person(attrs.uin, attrs.nm, /^\d+$/.test(attrs.jp ?? '') ? Number(attrs.jp) : 0));
        break;
      case 'nor':
      case 'url':
        if (attrs.txt) out.push(text(attrs.txt));
        break;
      case 'face':
        out.push(text('[表情]'));
        break;
    }
  }
  return compact(out);
}

/** json 提示：items 里 qq（uid、nm）、nor / url（txt）、img（只是装饰图，不显示）。 */
function jsonTip(json: string): Tip[] | null {
  let items: unknown;
  try {
    items = (JSON.parse(json) as { items?: unknown }).items;
  } catch {
    return null;
  }
  if (!Array.isArray(items)) return null;
  const out: Tip[] = [];
  for (const item of items as Array<Record<string, unknown>>) {
    const type = item.type;
    if (type === 'qq') out.push(person(str(item.uid), str(item.nm)));
    else if ((type === 'nor' || type === 'url') && str(item.txt)) out.push(text(str(item.txt)!));
  }
  return compact(out);
}

/** 模板里人名和文字紧挨着（「拍了拍」前后没有空格），按 QQ 的显示在人名两边补空格。 */
function compact(out: Tip[]): Tip[] | null {
  if (!out.some((t) => t.type === 'mention' || t.text.trim())) return null;
  return out.map((t, i) => {
    if (t.type !== 'text') return t;
    const before = out[i - 1]?.type === 'mention' && !/^\s/.test(t.text) ? ' ' : '';
    const after = out[i + 1]?.type === 'mention' && !/\s$/.test(t.text) ? ' ' : '';
    return text(before + t.text + after);
  });
}

function text(t: string): Tip {
  return { type: 'text', text: t };
}

function person(uid: string | undefined, name: string | undefined, userId = 0): Tip {
  return { type: 'mention', userId, ...(name?.trim() ? { name: name.trim() } : {}), ...(uid ? { uid } : {}) };
}

function str(v: unknown): string | undefined {
  return typeof v === 'string' && v ? v : undefined;
}

function attributes(s: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of s.matchAll(/(\w+)\s*=\s*"([^"]*)"/g)) out[m[1]!] = decode(m[2]!);
  return out;
}

function decode(s: string): string {
  return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
}
