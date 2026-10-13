// 通话管理（docs/design.md 5.2 CallService、5.4 呼叫流程）。
// - 插件把通话桥的状态变化作为 qqbridge_call 事件经上游队列送来（onPluginState）：落库到 calls，
//   经 Subscribe 推给所有在线设备（临时事件），结束时在与对方的私聊里留一条 kind = "call" 的通话记录。
// - 客户端接听（answer）：建 LiveKit 房间名 → 网关以"QQ 端"身份入会 → 让插件接听 → 把客户端令牌交回去。
//   顺序很重要：先让网关就位，QQ 一接通对方说的话就有地方去。
// - 同一个 QQ 号同时只有一通进行中的通话。
// - 挂断（hangup）：插件对通话引擎发拒接（响铃中）或结束（已接）；静音在客户端自己关麦克风轨道。
// 还没有的：主动拨打、群通话。
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, rows, type Db } from '../db/client.ts';
import type { IngestService } from '../ingest/service.ts';
import type { UpstreamHub } from '../upstream/hub.ts';
import type { CallGateway } from './gateway.ts';
import { mintLiveKitToken } from './livekit.ts';

/** 插件上报的通话状态（napcat-plugin-qqbridge/src/call/avsdk-bridge.ts 的 CallState）。 */
export interface PluginCallState {
  callId: string | null;
  phase: 'idle' | 'ringing' | 'accepting' | 'accepted' | 'connected' | 'ended';
  inviteAt: string | null;
  acceptedAt: string | null;
  connectedAt: string | null;
  endedAt: string | null;
  endReason: number | null;
  inviteType: number | null;
  callerUid: string | null;
  callerUin: string | null;
  callerName: string | null;
}

export type CallPhase = 'ringing' | 'accepting' | 'accepted' | 'connected' | 'ended';

export interface CallRecord {
  callId: string;
  qqAccountId: number;
  phase: CallPhase;
  incoming: boolean;
  media: 'voice' | 'video';
  peerUin: number | null;
  peerName: string | null;
  inviteAt: Date;
  acceptedAt: Date | null;
  connectedAt: Date | null;
  endedAt: Date | null;
  endReason: number | null;
  answeredDeviceId: number | null;
  room: string | null;
}

export interface CallConfig {
  livekitApiKey: string;
  livekitApiSecret: string;
  /** 客户端连 LiveKit 用的地址（经 Tailscale，例如 wss://<mac>.ts.net:7443）。 */
  livekitPublicUrl: string;
  /** 振铃状态超过这么久还没变化就当作已过期（例如服务端离线时积压的旧来电）。 */
  ringTimeoutMs?: number;
  logger?: Logger;
}

export class CallError extends Error {
  constructor(
    readonly code: 'not_found' | 'not_ringing' | 'unavailable',
    message: string,
  ) {
    super(message);
  }
}

const COLUMNS = sql.raw(
  `call_id, qq_account_id, phase, incoming, media, peer_uin, peer_name, invite_at, accepted_at, connected_at, ended_at, end_reason, answered_device_id, room`,
);

interface CallRow {
  call_id: string;
  qq_account_id: number;
  phase: CallPhase;
  incoming: boolean;
  media: 'voice' | 'video';
  peer_uin: number | null;
  peer_name: string | null;
  invite_at: Date | string;
  accepted_at: Date | string | null;
  connected_at: Date | string | null;
  ended_at: Date | string | null;
  end_reason: number | null;
  answered_device_id: number | null;
  room: string | null;
}

const toDate = (v: Date | string | null): Date | null => (v === null ? null : v instanceof Date ? v : new Date(v));

function toRecord(r: CallRow): CallRecord {
  return {
    callId: r.call_id,
    qqAccountId: r.qq_account_id,
    phase: r.phase,
    incoming: r.incoming,
    media: r.media,
    peerUin: r.peer_uin === null ? null : Number(r.peer_uin),
    peerName: r.peer_name,
    inviteAt: toDate(r.invite_at)!,
    acceptedAt: toDate(r.accepted_at),
    connectedAt: toDate(r.connected_at),
    endedAt: toDate(r.ended_at),
    endReason: r.end_reason,
    answeredDeviceId: r.answered_device_id === null ? null : Number(r.answered_device_id),
    room: r.room,
  };
}

export class CallService {
  constructor(
    private readonly db: Db,
    private readonly ingest: Pick<IngestService, 'addChatEvent' | 'publishCall'>,
    private readonly hub: Pick<UpstreamHub, 'call'> | null,
    private readonly gateway: CallGateway | null,
    private readonly cfg: CallConfig | null,
  ) {}

  /** 服务端这边接听所需的都配好了（LiveKit、网关、上游）。 */
  get configured(): boolean {
    return Boolean(this.cfg && this.gateway && this.hub);
  }

  async gatewayStatus(): Promise<{ reachable: boolean; room: string | null }> {
    if (!this.gateway?.status) return { reachable: false, room: null };
    try {
      return { reachable: true, ...(await this.gateway.status()) };
    } catch {
      return { reachable: false, room: null };
    }
  }

  /** 插件上报的一次状态变化。返回 false 表示忽略（空闲状态、缺 id 等）。 */
  async onPluginState(qqAccountId: number, state: PluginCallState): Promise<boolean> {
    if (!state.callId || state.phase === 'idle' || !state.inviteAt) return false;
    const inviteAt = new Date(state.inviteAt);
    const stale = state.phase === 'ringing' && Date.now() - inviteAt.getTime() > (this.cfg?.ringTimeoutMs ?? 120_000);
    const phase: CallPhase = stale ? 'ended' : state.phase;
    const peerUin = state.callerUin && /^\d+$/.test(state.callerUin) ? Number(state.callerUin) : null;
    const before = await this.get(state.callId);
    const row = await maybeOne<CallRow>(
      this.db,
      sql`insert into calls (qq_account_id, call_id, incoming, media, peer_uin, peer_name, phase, invite_at, accepted_at, connected_at, ended_at, end_reason)
          values (${qqAccountId}, ${state.callId}, true, ${state.inviteType === 2 ? 'video' : 'voice'}, ${peerUin}, ${state.callerName},
                  ${phase}, ${inviteAt}, ${state.acceptedAt ? new Date(state.acceptedAt) : null}, ${state.connectedAt ? new Date(state.connectedAt) : null},
                  ${state.endedAt ? new Date(state.endedAt) : stale ? new Date() : null}, ${state.endReason})
          on conflict (call_id) do update set
            peer_uin = coalesce(excluded.peer_uin, calls.peer_uin),
            peer_name = coalesce(excluded.peer_name, calls.peer_name),
            -- 已经结束的通话不会再回到前面的状态（重放、乱序）。
            phase = case when calls.phase = 'ended' then 'ended' else excluded.phase end,
            accepted_at = coalesce(calls.accepted_at, excluded.accepted_at),
            connected_at = coalesce(calls.connected_at, excluded.connected_at),
            ended_at = coalesce(calls.ended_at, excluded.ended_at),
            end_reason = coalesce(calls.end_reason, excluded.end_reason),
            updated_at = now()
          returning ${COLUMNS}`,
    );
    if (!row) return false;
    const call = toRecord(row);
    this.ingest.publishCall(qqAccountId, call);
    if (call.phase === 'ended' && before?.phase !== 'ended') await this.finish(call);
    return true;
  }

  async get(callId: string): Promise<CallRecord | null> {
    const row = await maybeOne<CallRow>(this.db, sql`select ${COLUMNS} from calls where call_id = ${callId}`);
    return row ? toRecord(row) : null;
  }

  /** 账号下正在进行的通话（最多一通）。 */
  async active(accountId: number): Promise<CallRecord | null> {
    const row = await maybeOne<CallRow>(
      this.db,
      sql`select ${COLUMNS} from calls
           where qq_account_id in (select id from qq_accounts where account_id = ${accountId}) and phase <> 'ended'
             and invite_at > now() - interval '6 hours'
           order by invite_at desc limit 1`,
    );
    return row ? toRecord(row) : null;
  }

  async list(accountId: number, limit: number, before?: Date): Promise<CallRecord[]> {
    const list = await rows<CallRow>(
      this.db,
      sql`select ${COLUMNS} from calls
           where qq_account_id in (select id from qq_accounts where account_id = ${accountId})
             ${before ? sql`and invite_at < ${before}` : sql``}
           order by invite_at desc limit ${limit}`,
    );
    return list.map(toRecord);
  }

  /** 客户端接听：网关先入会，再让 QQ 接听。返回客户端入会用的地址和令牌。 */
  async answer(accountId: number, deviceId: number, callId: string): Promise<{ call: CallRecord; url: string; token: string; room: string }> {
    if (!this.cfg || !this.gateway || !this.hub) throw new CallError('unavailable', 'calls are not configured (LiveKit / call gateway / upstream)');
    const call = await this.get(callId);
    const owned = call
      ? await maybeOne(this.db, sql`select 1 as x from qq_accounts where id = ${call.qqAccountId} and account_id = ${accountId}`)
      : null;
    if (!call || !owned) throw new CallError('not_found', `call ${callId} not found`);
    if (call.phase !== 'ringing' && call.phase !== 'accepting') throw new CallError('not_ringing', `call ${callId} is ${call.phase}`);

    const room = call.room ?? `qq-call-${call.callId}`;
    const [clientToken, gatewayToken] = await Promise.all([
      mintLiveKitToken(this.cfg, room, `device-${deviceId}`),
      mintLiveKitToken(this.cfg, room, 'qq-gateway'),
    ]);
    await this.gateway.join(room, gatewayToken);
    await this.db.execute(sql`update calls set room = ${room}, answered_device_id = ${deviceId}, updated_at = now() where call_id = ${callId}`);
    try {
      await this.hub.call(call.qqAccountId, 'x.call.accept', {});
    } catch (error) {
      await this.gateway.leave(room).catch(() => undefined);
      throw error;
    }
    const updated = (await this.get(callId))!;
    this.ingest.publishCall(updated.qqAccountId, updated);
    return { call: updated, url: this.cfg.livekitPublicUrl, token: clientToken, room };
  }

  /** 挂断 / 拒接：交给插件；结束状态随后由插件上报（onPluginState）。 */
  async hangup(accountId: number, callId: string): Promise<CallRecord> {
    if (!this.hub) throw new CallError('unavailable', 'calls are not configured (upstream)');
    const call = await this.get(callId);
    const owned = call
      ? await maybeOne(this.db, sql`select 1 as x from qq_accounts where id = ${call.qqAccountId} and account_id = ${accountId}`)
      : null;
    if (!call || !owned) throw new CallError('not_found', `call ${callId} not found`);
    if (call.phase === 'ended') return call;
    await this.hub.call(call.qqAccountId, 'x.call.hangup', {});
    return (await this.get(callId))!;
  }

  /** 通话结束：网关离开房间，在与对方的私聊里留通话记录。 */
  private async finish(call: CallRecord): Promise<void> {
    if (call.room && this.gateway) {
      await this.gateway.leave(call.room).catch((error: unknown) => this.cfg?.logger?.warn({ err: error, room: call.room }, 'gateway leave failed'));
    }
    if (call.peerUin === null) return;
    const end = call.endedAt ?? new Date();
    const durationSec = call.connectedAt ? Math.max(0, Math.round((end.getTime() - call.connectedAt.getTime()) / 1000)) : 0;
    await this.ingest.addChatEvent(call.qqAccountId, {
      scene: 'friend',
      peerId: call.peerUin,
      kind: 'call',
      time: Math.floor(call.inviteAt.getTime() / 1000),
      ...(call.incoming ? { actorId: call.peerUin } : {}),
      data: {
        callId: call.callId,
        incoming: call.incoming,
        media: call.media,
        // endReason -2：在这里拒接的（插件 REJECTED_HERE）。
        result: call.connectedAt ? 'answered' : call.endReason === -2 ? 'declined' : 'missed',
        durationSec,
        answeredHere: call.answeredDeviceId !== null,
        endReason: call.endReason,
      },
    });
  }
}
