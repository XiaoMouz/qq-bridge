import { sql } from 'drizzle-orm';
import type { Scene, Segment } from '@qqbridge/domain';
import { resolveTipPeople } from '../ingest/service.ts';
import { grayTipSegments } from '../upstream/napcat/gray-tip.ts';
import { rows, type Db } from '../db/client.ts';

export const MATCHER_VERSION = 4;

export interface Element {
  type: number; kind: string; text?: string; targetUid?: string; faceId?: string;
  app?: string; payload?: string; resourceId?: string;
  reference?: Record<string, string | null>; snapshot?: Element[];
  identifiers?: { algorithm: string; value: string; role: string }[];
  [key: string]: unknown;
}
export interface BackupRecord {
  table: string; sourceKey: [string, number, string, string]; scene: string | null; peer: string;
  seq: string; clientSeq: string | null; random: string; time: number;
  senderUid: string | null; senderUin: string | null; sendStatus: number | null;
  identityDisagreement: boolean; elements: Element[]; nodes: BackupRecord[]; path?: number[]; nodeScope?: string;
}
export interface MatchResult {
  sourceKey: BackupRecord['sourceKey']; status: string; chatId: number | null;
  sender: { status: string; userId: string | null; evidence: string };
  sourceSenderUid?: string | null; sourceSenderUin?: string | null;
  nodeBindings?: { path: number[]; scope: string; senderUid: string | null; senderUin: string | null; binding: MatchResult['sender'] }[];
  timeEvidence?: { sourceTime: number; targetTime: number; deltaSeconds: number };
  serviceElements?: ServiceElement[];
  messageId?: string; version?: number; reasons?: string[]; replies?: unknown[];
}
interface ServiceElement {
  path: number[]; elementIndex: number; kind: string; status: 'rendered' | 'unadapted'; segments: Segment[];
  participants: { uid: string | null; userId: string | null; displayName: string; binding: MatchResult['sender'] }[];
}
interface Target {
  id: string; seq: string; random: string | null; time: number; sender_uin: string;
  version: number; state: string; raw: Record<string, any> | null; segments: any[];
}
const valid = (x: unknown): boolean => x != null && String(x) !== '' && String(x) !== '0';
// JSON 数字原文保留；64 位卡片 ID 不能先被 JSON.parse 舍入后再宣称内容相同。
class JsonNumber {
  constructor(readonly literal: string) {}
}
const canonical = (value: unknown): string => {
  if (value instanceof JsonNumber) return `n:${value.literal}`;
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.entries(value).sort(([a],[b])=>a.localeCompare(b))
    .map(([key,child])=>JSON.stringify(key)+':'+canonical(child)).join(',') + '}';
  return JSON.stringify(value);
};
function card(value: string | undefined): unknown {
  try {
    return JSON.parse(value ?? '', (_key: string, child: unknown, context?: { source?: string }) =>
      typeof child === 'number' ? new JsonNumber(context?.source ?? String(child)) : child);
  } catch { return null; }
}

/** 同身份只代表同消息，不代表两个端的完整内容可互相覆盖。 */
export function compareContent(source: BackupRecord, target: Target): { equal: boolean; reasons: string[] } {
  const rawElements: any[] = target.raw?.elements ?? [];
  if (!rawElements.length) return { equal: false, reasons: ['target_raw_elements_missing'] };
  if (source.elements.length !== rawElements.length) return { equal: false, reasons: ['element_count_differs'] };
  const reasons: string[] = [];
  for (const [i, a] of source.elements.entries()) {
    const b = rawElements[i];
    const ty = Number(b.elementType);
    if (a.type !== ty) {
      // 手机合并转发为 ARK，Linux 为 XML；需单独比较 resid，不能按类型直接判不同消息。
      if (a.kind === 'forward' && ty === 16) {
        const data = card(a.payload) as any;
        const detail = data?.meta?.detail ?? data?.meta?.detail_1;
        const xml = b.multiForwardMsgElement?.xmlContent ?? b.forwardMsgElement?.xmlContent ?? '';
        const resid = /m_resid=["']([^"']+)/.exec(xml)?.[1];
        if (resid && detail?.resid === resid) { reasons.push(`element_${i}:forward_same_resid_other_representation`); continue; }
      }
      reasons.push(`element_${i}:type_differs`); continue;
    }
    if (a.type === 1) {
      const t = b.textElement ?? {};
      if (a.text !== t.content) reasons.push(`element_${i}:text_differs`);
      const at = Number(t.atType ?? 0);
      if (a.kind === 'mention_all') {
        if (at !== 1) reasons.push(`element_${i}:mention_all_differs`);
      } else if (a.kind === 'mention') {
        if (at !== 2 || !a.targetUid || a.targetUid !== t.atNtUid) reasons.push(`element_${i}:mention_uid_differs`);
      } else if (at !== 0) reasons.push(`element_${i}:mention_kind_differs`);
    } else if (a.type === 6) {
      if (a.faceId !== String(b.faceElement?.faceIndex)) reasons.push(`element_${i}:face_differs`);
      if (a.kind === 'super_face') reasons.push(`element_${i}:super_face_context_requires_review`);
    } else if (a.type === 10) {
      const left = card(a.payload), right = card(b.arkElement?.bytesData);
      if (!left || !right || canonical(left) !== canonical(right)) reasons.push(`element_${i}:card_differs`);
    } else if ([2, 3, 4, 5, 11, 49].includes(a.type)) {
      const m = b.picElement ?? b.fileElement ?? b.pttElement ?? b.videoElement ?? b.marketFaceElement ?? {};
      const hashes = [m.md5HexStr, m.fileMd5, m.md5, m.emojiId, m.videoMd5, m.originVideoMd5].filter(Boolean).map((x: unknown) => String(x).toLowerCase());
      const ids = a.identifiers?.filter(x => x.role === 'main' && x.algorithm === 'md5') ?? [];
      if (!ids.some(x => hashes.includes(x.value))) reasons.push(`element_${i}:media_identity_unverified`);
      // 文件字节是否可复用由 objects 的实际 SHA-256 判定，不由协议 MD5 推断。
    } else if (a.type === 7) {
      // 关联目标在 matchReplies 中核验；这里只比较引用的作者与时间，不能拿跨端本地 msgId 比较。
      const r = b.replyElement ?? {};
      if (valid(a.reference?.senderUid) && valid(r.senderUidStr) && a.reference?.senderUid !== r.senderUidStr) reasons.push(`element_${i}:reply_sender_differs`);
    } else if (a.type === 14) {
      if (a.text !== b.markdownElement?.content) reasons.push(`element_${i}:markdown_differs`);
    } else reasons.push(`element_${i}:semantic_adapter_unavailable`);
  }
  return { equal: reasons.length === 0, reasons };
}

export class BackupMatcher {
  constructor(private readonly db: Db) {}

  async matchBatch(qqAccountId: number, source: BackupRecord[]): Promise<MatchResult[]> {
    const results: MatchResult[] = [];
    // 输入最多 500 条；所有缓存只活一批，避免全库用户/消息常驻内存。
    const chats = new Map<string, number | null>();
    const people = new Map<string, MatchResult['sender']>();
    const groups = new Map<number, BackupRecord[]>();
    for (const record of source) {
      const key = `${record.scene}:${record.peer}`;
      if (!chats.has(key)) {
        const found = record.scene ? await rows<{ id: number }>(this.db, sql`
          select id from chats where qq_account_id=${qqAccountId} and scene=${record.scene} and peer_id=${record.peer}::bigint`) : [];
        chats.set(key, found[0]?.id ?? null);
      }
      const id = chats.get(key);
      if (id) { const list = groups.get(id) ?? []; list.push(record); groups.set(id, list); }
    }
    const targetGroups = new Map<number, Target[]>();
    for (const [id, records] of groups) targetGroups.set(id, await this.candidates(id, records));
    for (const record of source) {
      const chatId = chats.get(`${record.scene}:${record.peer}`)!;
      const personKey = `${record.scene}:${record.peer}:${record.senderUid}:${record.senderUin}`;
      if (!people.has(personKey)) people.set(personKey, await this.bindSender(qqAccountId, record));
      const result: MatchResult = { sourceKey: record.sourceKey, sourceSenderUid: record.senderUid, sourceSenderUin: record.senderUin, status: 'no_candidate', chatId, sender: people.get(personKey)!, nodeBindings: await this.bindNodes(qqAccountId, record, record, people) };
      result.serviceElements = await this.bindServiceElements(qqAccountId, record, record, people);
      if (record.elements.length && record.elements.every(e => e.type === 8 || e.type === 26)) {
        result.sender = { status: 'not_applicable', userId: null, evidence: 'service_event_uses_participants' };
      }
      if (!chatId) { result.status = 'chat_unbound'; result.reasons = ['existing_chat_not_found']; results.push(result); continue; }
      const batchTargets = targetGroups.get(chatId) ?? [];
      const candidates = batchTargets.filter(t => t.seq === record.seq || t.time === record.time);
      if (batchTargets.length >= 4097) { result.status = 'ambiguous'; result.reasons = ['batch_candidate_limit']; results.push(result); continue; }
      const protocolIdentityMatches = (t: Target): boolean => {
        const r = t.raw;
        return BigInt(record.seq) > 0n && !record.identityDisagreement && record.sendStatus === 2 && Number(r?.sendStatus) === 2 &&
          valid(record.senderUid) && record.senderUid === r?.senderUid &&
          (!valid(record.senderUin) || record.senderUin === t.sender_uin) &&
          record.seq === t.seq && valid(record.random) &&
          record.random === String(r?.msgRandom ?? '') &&
          (record.scene === 'group' || (valid(record.clientSeq) && BigInt(record.clientSeq!) > 0n && record.clientSeq === String(r?.clientSeq ?? '')));
      };
      const exact = candidates.filter(t => protocolIdentityMatches(t) && record.time === t.time);
      const timeVariants: Target[] = [];
      if (exact.length === 0) {
        // 2026-11-03 当前 Mac mini 16 会话核对：54 条身份与已支持内容一致，原生时间差 ±1 秒。
        // 时间差本身不是匹配键；必须同时满足完整身份、唯一候选、内容一致和回复实际目标一致。
        for (const t of candidates) {
          if (!protocolIdentityMatches(t) || Math.abs(t.time - record.time) !== 1 || !compareContent(record, t).equal) continue;
          const refs = await this.matchReplies(chatId, record, t);
          if (refs.every(x => x.status === 'verified')) timeVariants.push(t);
        }
      }
      const matched = exact.length === 1 ? exact[0] : exact.length === 0 && timeVariants.length === 1 ? timeVariants[0] : null;
      if (matched) {
        const t = matched;
        const comparison = compareContent(record, t);
        result.status = comparison.equal ? 'same' : 'same_identity_content_variant';
        if (t.time !== record.time) {
          result.status = 'same_identity_time_variant';
          result.timeEvidence = { sourceTime: record.time, targetTime: t.time, deltaSeconds: t.time - record.time };
          comparison.reasons.push('native_time_differs_by_one_second_preserve_target_time');
        }
        result.messageId = t.id; result.version = t.version; result.reasons = comparison.reasons;
        const replies = await this.matchReplies(chatId, record, t);
        if (replies.length) {
          result.replies = replies;
          if (replies.some(x => x.status !== 'verified')) {
            result.status = 'same_identity_content_variant'; result.reasons.push('reply_target_not_verified');
          }
        }
        if (t.state === 'recalled') {
          result.status = 'same_identity_preserve_recalled'; result.reasons.push('preserve_existing_recall_state');
        }
      } else if (exact.length > 1 || timeVariants.length > 1 || candidates.length >= 128) {
        result.status = 'ambiguous'; result.reasons = ['multiple_or_unbounded_candidates'];
      } else if (candidates.length) {
        result.status = candidates.some(t => t.seq === record.seq) ? 'seq_conflict' : 'identity_unverified';
        result.reasons = ['same_seq_or_time_is_not_identity'];
      }
      results.push(result);
    }
    return results;
  }

  private async bindServiceElements(qqAccountId: number, root: BackupRecord, node: BackupRecord,
    cache: Map<string, MatchResult['sender']>): Promise<ServiceElement[]> {
    const result: ServiceElement[]=[];
    for (const [elementIndex,e] of node.elements.entries()) {
      if (e.type!==8 && e.type!==26) continue;
      const parts: Segment[] = e.type===8
        ? grayTipSegments(e.grayTip,root.scene as Scene) ?? (typeof e.savedText==='string' ? [{type:'text',text:e.savedText}] : [])
        : [];
      if(e.type===26) {
        const d=e.dynamic as { relatedUins?: string[]; publisherUid?: string; descriptions?: {text?:string}[] } | undefined;
        const uins=d?.relatedUins??[];
        for(const uin of uins) if(valid(uin))parts.push({type:'mention',userId:Number(uin),...(uins.length===1&&d?.publisherUid?{uid:d.publisherUid}:{})});
        const title=d?.descriptions?.[0]?.text;
        if(title)parts.push({type:'text',text:' '+title});
        const summary=d?.descriptions?.[1]?.text;
        if(summary)parts.push({type:'text',text:'\n'+summary});
      }
      const participants: ServiceElement['participants']=[];
      const resolved: Segment[]=[];
      for(const part of parts) {
        if(part.type!=='mention'){resolved.push(part);continue;}
        const input={...root,senderUid:part.uid??null,senderUin:part.userId?String(part.userId):null};
        const key=`${root.scene}:${root.peer}:${input.senderUid}:${input.senderUin}`;
        if(!cache.has(key))cache.set(key,await this.bindSender(qqAccountId,input));
        const binding=cache.get(key)!;
        const candidate=binding.status==='bound'&&binding.userId ? {...part,userId:Number(binding.userId)} : part;
        const filled=binding.status==='bound'
          ? (await resolveTipPeople(this.db,qqAccountId,root.scene==='group'?Number(root.peer):null,[candidate]))[0]!
          : candidate;
        if(filled.type!=='mention')continue;
        const displayName=filled.name|| (filled.userId?String(filled.userId):'某人');
        resolved.push({...filled,name:displayName});
        participants.push({uid:part.uid??null,userId:filled.userId?String(filled.userId):null,displayName,binding});
      }
      result.push({path:node.path??[],elementIndex,kind:e.kind,status:resolved.length?'rendered':'unadapted',segments:resolved,participants});
    }
    for(const child of node.nodes??[])result.push(...await this.bindServiceElements(qqAccountId,root,child,cache));
    return result;
  }

  private async bindNodes(qqAccountId: number, root: BackupRecord, node: BackupRecord,
    cache: Map<string, MatchResult['sender']>): Promise<NonNullable<MatchResult['nodeBindings']>> {
    const result: NonNullable<MatchResult['nodeBindings']> = [];
    for (const child of node.nodes ?? []) {
      const key = `${root.scene}:${root.peer}:${child.senderUid}:${child.senderUin}`;
      if (!cache.has(key)) cache.set(key, await this.bindSender(qqAccountId, { ...child, scene: root.scene, peer: root.peer }));
      const binding = child.elements.length && child.elements.every(e=>e.type===8||e.type===26)
        ? {status:'not_applicable',userId:null,evidence:'service_event_uses_participants'} : cache.get(key)!;
      result.push({ path: child.path ?? [], scope: child.nodeScope ?? 'unknown', senderUid: child.senderUid,
        senderUin: child.senderUin, binding });
      result.push(...await this.bindNodes(qqAccountId, root, child, cache));
    }
    return result;
  }

  private async candidates(chatId: number, records: BackupRecord[]): Promise<Target[]> {
    const sequences = [...new Set(records.map(r => r.seq))].map(x => sql`${x}::bigint`);
    const times = [...new Set(records.map(r => r.time))].map(x => sql`to_timestamp(${x})`);
    return rows<Target>(this.db, sql`select id::text,seq::text,random::text,
      extract(epoch from time)::float8 as time,sender_uin::text,version,state,
      jsonb_build_object('sendStatus',raw->'sendStatus','senderUid',raw->'senderUid','msgSeq',raw->'msgSeq',
        'clientSeq',raw->'clientSeq','msgRandom',raw->'msgRandom','elements',raw->'elements') as raw,segments from messages
      where chat_id=${chatId} and (seq in (${sql.join(sequences, sql`,`)}) or time in (${sql.join(times, sql`,`)})) limit 4097`);
  }

  async bindSender(qqAccountId: number, r: BackupRecord): Promise<MatchResult['sender']> {
    const sourceUin = valid(r.senderUin) && /^\d+$/.test(r.senderUin!) && BigInt(r.senderUin!) <= BigInt(Number.MAX_SAFE_INTEGER) ? r.senderUin : null;
    const peer = /^\d+$/.test(r.peer) && BigInt(r.peer) <= BigInt(Number.MAX_SAFE_INTEGER) ? r.peer : null;
    const found = await rows<{ user_id: string; uid: string | null }>(this.db, sql`
      select peer_id::text as user_id,uid from peers where qq_account_id=${qqAccountId} and kind='user'
      and ((${r.senderUid}::text is not null and uid=${r.senderUid}) or peer_id=${sourceUin}::bigint)
      union select uin::text,uid from qq_accounts where id=${qqAccountId}
      and ((${r.senderUid}::text is not null and uid=${r.senderUid}) or uin=${sourceUin}::bigint)
      union select user_id::text,null::text from group_members where qq_account_id=${qqAccountId}
      and group_id=${peer}::bigint and user_id=${sourceUin}::bigint and ${r.scene}='group'`);
    const uidIds = new Set(found.filter(x => valid(r.senderUid) && x.uid === r.senderUid).map(x => x.user_id));
    const conflict = uidIds.size > 1 || (uidIds.size === 1 && valid(r.senderUin) && !uidIds.has(r.senderUin!)) ||
      found.some(x => x.user_id === r.senderUin && valid(x.uid) && valid(r.senderUid) && x.uid !== r.senderUid);
    if (conflict) return { status: 'conflict', userId: null, evidence: 'uid_uin_disagreement' };
    if (uidIds.size === 1) return { status: 'bound', userId: [...uidIds][0]!, evidence: 'existing_unique_uid' };
    if (valid(r.senderUin) && found.some(x => x.user_id === r.senderUin)) return { status: 'bound', userId: r.senderUin, evidence: 'source_uin_existing_user_or_member' };
    return { status: 'unbound', userId: valid(r.senderUin) ? r.senderUin : null, evidence: valid(r.senderUin) ? 'source_uin_without_existing_profile' : 'uid_only_without_unique_mapping' };
  }

  private async matchReplies(chatId: number, source: BackupRecord, target: Target): Promise<{ status: string; targetId?: string; reference: unknown }[]> {
    const replies = [];
    for (const [i, e] of source.elements.entries()) {
      if (e.type !== 7) continue;
      const ref = e.reference ?? {};
      const seq = target.raw?.elements?.[i]?.replyElement?.replayMsgSeq;
      if (!valid(ref.time) || !valid(ref.sequence) || !valid(seq)) { replies.push({ status: 'missing_context', reference: ref }); continue; }
      const targets = await rows<Target>(this.db, sql`select id::text,seq::text,sender_uin::text,
        extract(epoch from time)::float8 as time,raw from messages where chat_id=${chatId} and seq=${String(seq)}::bigint limit 2`);
      const matched = targets.filter(t => t.time === Number(ref.time) &&
        String(source.scene === 'group' ? t.raw?.msgSeq : t.raw?.clientSeq) === ref.sequence &&
        (valid(ref.senderUid) ? ref.senderUid === t.raw?.senderUid : valid(ref.senderUin) && ref.senderUin === t.sender_uin) &&
        (!valid(ref.senderUin) || ref.senderUin === t.sender_uin));
      replies.push(matched.length === 1 ? { status: 'verified', targetId: matched[0]!.id, reference: ref } : { status: 'unresolved', reference: ref });
    }
    return replies;
  }

  async matchObjects(objects: MediaObject[]): Promise<{ object: MediaObject; target: { status: string; sha256?: string } }[]> {
    if (!objects.length) return [];
    const hashes = objects.flatMap(o => o.sha256 ? [o.sha256] : []);
    const existing = hashes.length ? await rows<{ sha256: string; size: number; state: string }>(this.db,
      sql`select sha256,size,state from blobs where sha256 in (${sql.join(hashes.map(x => sql`${x}`), sql`,`)})`) : [];
    return objects.map(o => {
      const t = existing.find(x => x.sha256 === o.sha256);
      return { object: o, target: { status: o.status !== 'available' ? 'source_unavailable' : !t ? 'new_payload' : t.size !== o.size ? 'hash_size_conflict' : t.state === 'purged' ? 'purged_preserve_policy' : 'reusable', ...(t ? { sha256: t.sha256 } : {}) } };
    });
  }
}
export interface MediaObject {
  resourceId: string; status: string; sha256?: string; md5?: string; sha1?: string; size?: number; mime?: string; reason?: string;
}
