// ConnectRPC 服务实现（proto 定义见 packages/protocol/proto/qqbridge/v1）。
import { ForwardError } from '../messages/forwarding.ts';
import { GroupContentError } from '../contacts/group-content.ts';
import type { MessageInitShape } from '@bufbuild/protobuf';
import { Code, ConnectError, type ConnectRouter, type ServiceImpl } from '@connectrpc/connect';
import {
  AdminService,
  ApnsEnvironment,
  AuthService,
  CallService,
  ContactService,
  DialogService,
  HistoryDirection,
  MediaService,
  MessageService,
  PolicyScope,
  Scene,
  SyncService,
  type SubscribeResponseSchema,
} from '@qqbridge/protocol';
import { MessageFlag } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { CallError } from '../calls/service.ts';
import { ContactError, type UserProfile } from '../contacts/service.ts';
import { InteractionError } from '../messages/interactions.ts';
import { maybeOne, rows } from '../db/client.ts';
import { UploadError } from '../media/upload.ts';
import { deletePolicy, effectivePolicy, listPolicies, PolicyError, setPolicy } from '../media/policies.ts';
import type { ChatStorageSummary } from '../media/service.ts';
import type { StickerItem } from '../media/stickers.ts';
import { DialogPrefsError } from '../dialogs/prefs.ts';
import { OutboxError } from '../outbox/service.ts';
import { SearchQueryError, searchMessages } from '../search/messages.ts';
import { UpstreamCallError } from '../upstream/hub.ts';
import { getChatDifference, getChatDifferences, getDifference, getHistory, getState, listDialogs, NotFoundError } from '../sync/difference.ts';
import { subscribe, type StreamEvent } from '../sync/subscribe.ts';
import { requireAuth, type ApiDeps } from './context.ts';
import {
  callToProto,
  chatEventToProto,
  dialogToProto,
  differenceToProto,
  mediaKindFromProto,
  mediaKindToProto,
  segmentToProto,
  messageToProto,
  outboxToProto,
  outgoingFromProto,
  peerToProto,
  sceneToProto,
  toSafeNumber,
  mediaInfo,
} from './convert.ts';

const nowSec = () => BigInt(Math.floor(Date.now() / 1000));
const SHA256 = /^[0-9a-f]{64}$/;

function authService(deps: ApiDeps): ServiceImpl<typeof AuthService> {
  return {
    async login(req) {
      if (!req.username || !req.password) throw new ConnectError('username and password are required', Code.InvalidArgument);
      const res = await deps.auth.login(req.username, req.password, {
        name: req.deviceName || 'unknown',
        platform: req.platform || 'unknown',
      });
      return { token: res.token, accountId: BigInt(res.accountId), deviceId: BigInt(res.deviceId) };
    },
    async logout(_req, ctx) {
      const auth = requireAuth(ctx);
      await deps.auth.revokeDevice(auth, auth.deviceId);
      return {};
    },
    async listDevices(_req, ctx) {
      const devices = await deps.auth.listDevices(requireAuth(ctx));
      return {
        devices: devices.map((d) => ({
          id: BigInt(d.id),
          name: d.name,
          platform: d.platform,
          createdAt: BigInt(Math.floor(d.createdAt.getTime() / 1000)),
          lastSeenAt: d.lastSeenAt ? BigInt(Math.floor(d.lastSeenAt.getTime() / 1000)) : 0n,
          current: d.current,
        })),
      };
    },
    async revokeDevice(req, ctx) {
      return { revoked: await deps.auth.revokeDevice(requireAuth(ctx), toSafeNumber(req.deviceId, 'device_id')) };
    },
    async registerPush(req, ctx) {
      const auth = requireAuth(ctx);
      const hex = /^[0-9a-fA-F]{32,200}$/;
      for (const [name, value] of [['apns_token', req.apnsToken], ['apns_voip_token', req.apnsVoipToken]] as const) {
        if (value && !hex.test(value)) throw new ConnectError(`${name} must be a hex device token`, Code.InvalidArgument);
      }
      const env = req.environment === ApnsEnvironment.SANDBOX ? 'sandbox' : req.environment === ApnsEnvironment.PRODUCTION ? 'production' : null;
      await deps.db.execute(
        sql`update devices set apns_token = ${req.apnsToken.toLowerCase() || null}, apns_voip_token = ${req.apnsVoipToken.toLowerCase() || null},
                               apns_env = ${env} where id = ${auth.deviceId}`,
      );
      return {};
    },
  };
}

function syncService(deps: ApiDeps): ServiceImpl<typeof SyncService> {
  return {
    async getState(_req, ctx) {
      const accountId = requireAuth(ctx).accountId;
      const { pts } = await getState(deps.db, accountId);
      const accounts = await rows<{ id: number; uin: number; nickname: string | null }>(
        deps.db,
        sql`select id, uin, nickname from qq_accounts where account_id = ${accountId} order by id`,
      );
      return {
        pts: BigInt(pts),
        serverTime: nowSec(),
        qqAccounts: accounts.map((a) => ({ id: BigInt(a.id), uin: BigInt(a.uin), nickname: a.nickname ?? '' })),
      };
    },
    async getDifference(req, ctx) {
      const limit = clampLimit(req.limit, 500, 2000);
      const diff = await getDifference(deps.db, requireAuth(ctx).accountId, toSafeNumber(req.pts, 'pts'), limit);
      return { difference: differenceToProto(diff) };
    },
    async getChatDifferences(req, ctx) {
      const results = await getChatDifferences(
        deps.db,
        requireAuth(ctx).accountId,
        req.chats.map((c) => ({ chatId: toSafeNumber(c.chatId, 'chat_id'), chatPts: toSafeNumber(c.chatPts, 'chat_pts') })),
        clampLimit(req.perChatLimit, 30, 100),
      );
      return {
        chats: results.map((d) => ({
          chatId: BigInt(d.chatId),
          chatPts: BigInt(d.chatPts),
          isFinal: d.final,
          tooLong: d.tooLong,
          messages: d.messages.map(messageToProto),
          events: d.events.map(chatEventToProto),
        })),
      };
    },
    async getChatDifference(req, ctx) {
      const diff = await getChatDifference(
        deps.db,
        requireAuth(ctx).accountId,
        toSafeNumber(req.chatId, 'chat_id'),
        toSafeNumber(req.chatPts, 'chat_pts'),
        clampLimit(req.limit, 200, 500),
      );
      return {
        chatPts: BigInt(diff.chatPts),
        isFinal: diff.final,
        tooLong: diff.tooLong,
        messages: diff.messages.map(messageToProto),
        events: diff.events.map(chatEventToProto),
      };
    },
    async *subscribe(req, ctx) {
      const auth = requireAuth(ctx);
      for await (const event of subscribe(deps.db, deps.bus, auth.accountId, toSafeNumber(req.pts, 'pts'), ctx.signal)) {
        yield streamEventToProto(event);
        if (event.kind === 'resync') return;
      }
    },
  };
}

function streamEventToProto(event: StreamEvent): MessageInitShape<typeof SubscribeResponseSchema> {
  switch (event.kind) {
    case 'difference':
      return { event: { case: 'difference', value: differenceToProto(event.difference) } };
    case 'heartbeat':
      return { event: { case: 'heartbeat', value: { pts: BigInt(event.pts), serverTime: nowSec() } } };
    case 'resync':
      return { event: { case: 'resync', value: {} } };
    case 'update': {
      const u = event.update;
      switch (u.type) {
        case 'dialog':
          return { event: { case: 'dialog', value: { pts: BigInt(u.pts), dialog: dialogToProto(u.dialog) } } };
        case 'peer':
          return { event: { case: 'peer', value: { pts: BigInt(u.pts), peer: peerToProto(u.peer) } } };
        case 'tombstone':
          return {
            event: {
              case: 'tombstone',
              value: { pts: BigInt(u.pts), tombstone: { pts: BigInt(u.pts), entity: u.tombstone.entity, key: u.tombstone.key } },
            },
          };
        case 'chatMessage':
          return {
            event: {
              case: 'chatMessage',
              value: { chatId: BigInt(u.chatId), chatPts: BigInt(u.chatPts), message: messageToProto(u.message) },
            },
          };
        case 'outbox':
          return { event: { case: 'outbox', value: { pts: BigInt(u.pts), entry: outboxToProto(u.entry) } } };
        case 'chatEvent':
          return {
            event: {
              case: 'chatEvent',
              value: { chatId: BigInt(u.chatId), chatPts: BigInt(u.chatPts), event: chatEventToProto(u.event) },
            },
          };
        case 'typing':
          return { event: { case: 'typing', value: { chatId: BigInt(u.chatId), userId: BigInt(u.userId), text: u.text } } };
        case 'call':
          return { event: { case: 'call', value: { call: callToProto(u.call) } } };
      }
    }
  }
}

function dialogService(deps: ApiDeps): ServiceImpl<typeof DialogService> {
  return {
    async listDialogs(req, ctx) {
      const res = await listDialogs(deps.db, requireAuth(ctx).accountId, {
        limit: clampLimit(req.limit, 50, 200),
        beforeChatId: req.beforeChatId ? toSafeNumber(req.beforeChatId, 'before_chat_id') : null,
        beforeTopTime: req.beforeTopTime ? new Date(toSafeNumber(req.beforeTopTime, 'before_top_time') * 1000) : null,
      });
      return { pts: BigInt(res.pts), dialogs: res.dialogs.map(dialogToProto) };
    },
    async markRead(req, ctx) {
      const accountId = requireAuth(ctx).accountId;
      const chatId = toSafeNumber(req.chatId, 'chat_id');
      const changed = await deps.ingest.markRead(accountId, chatId, toSafeNumber(req.maxSeq, 'max_seq'));
      if (changed) void writeBackRead(deps, accountId, chatId);
      return { changed };
    },
    async setPinned(req, ctx) {
      return prefs(() => deps.dialogPrefs.setPinned(requireAuth(ctx).accountId, toSafeNumber(req.chatId, 'chat_id'), req.pinned));
    },
    async setNotifyPolicy(req, ctx) {
      return prefs(() =>
        deps.dialogPrefs.setNotifyPolicy(requireAuth(ctx).accountId, toSafeNumber(req.chatId, 'chat_id'), req.policy),
      );
    },
    async setMentionAllNotify(req, ctx) {
      return prefs(() => deps.dialogPrefs.setMentionAllNotify(requireAuth(ctx).accountId, toSafeNumber(req.chatId, 'chat_id'), req.enabled));
    },
    async saveDraft(req, ctx) {
      const segments = req.segments.map(outgoingFromProto);
      if (segments.some((s) => s === null)) throw new ConnectError('unknown draft segment', Code.InvalidArgument);
      return prefs(() =>
        deps.dialogPrefs.saveDraft(
          requireAuth(ctx).accountId,
          toSafeNumber(req.chatId, 'chat_id'),
          segments as NonNullable<(typeof segments)[number]>[],
          req.replyToSeq ? toSafeNumber(req.replyToSeq, 'reply_to_seq') : undefined,
        ),
      );
    },
    async setTyping(req, ctx) {
      try {
        return { sent: await deps.interactions.typing(requireAuth(ctx).accountId, toSafeNumber(req.chatId, 'chat_id')) };
      } catch (error) {
        throw interactionError(error);
      }
    },
    async openChat(req, ctx) {
      const scene = req.scene === Scene.FRIEND ? 'friend' : req.scene === Scene.GROUP ? 'group' : null;
      if (!scene) throw new ConnectError('scene must be FRIEND or GROUP', Code.InvalidArgument);
      const peerId = toSafeNumber(req.peerId, 'peer_id');
      if (peerId <= 0) throw new ConnectError('peer_id is required', Code.InvalidArgument);
      try {
        const via = req.viaGroupId ? toSafeNumber(req.viaGroupId, 'via_group_id') : 0;
        return { chatId: BigInt(await deps.ingest.openChat(requireAuth(ctx).accountId, scene, peerId, via)) };
      } catch (error) {
        if (error instanceof NotFoundError) throw new ConnectError(error.message, Code.NotFound);
        throw error;
      }
    },
    async setActiveChat(req, ctx) {
      const auth = requireAuth(ctx);
      const chatId = toSafeNumber(req.chatId, 'chat_id');
      if (chatId === 0) {
        deps.activeChats.set(auth.deviceId, null);
        return {};
      }
      const owned = await maybeOne(
        deps.db,
        sql`select 1 as x from chats c join qq_accounts q on q.id = c.qq_account_id
             where c.id = ${chatId} and q.account_id = ${auth.accountId}`,
      );
      if (!owned) throw new ConnectError(`chat ${chatId} not found`, Code.NotFound);
      deps.activeChats.set(auth.deviceId, chatId);
      deps.contacts.chatOpened(chatId); // 头像按需刷新（后台进行）
      return {};
    },
  };
}

async function prefs(fn: () => Promise<boolean>): Promise<{ changed: boolean }> {
  try {
    return { changed: await fn() };
  } catch (error) {
    if (error instanceof DialogPrefsError) {
      throw new ConnectError(error.message, error.code === 'not_found' ? Code.NotFound : Code.InvalidArgument);
    }
    throw error;
  }
}

/** 已读回写 QQ（尽力而为：QQ 不在线就跳过，手机 QQ 上的未读角标以后会随 QQ 自己的同步消失）。 */
async function writeBackRead(deps: ApiDeps, accountId: number, chatId: number): Promise<void> {
  try {
    const chat = await maybeOne<{ scene: string; peer_id: number; qq_account_id: number }>(
      deps.db,
      sql`select c.scene, c.peer_id, c.qq_account_id from chats c join qq_accounts q on q.id = c.qq_account_id
           where c.id = ${chatId} and q.account_id = ${accountId}`,
    );
    if (!chat || !deps.upstream?.isConnected(chat.qq_account_id)) return;
    const group = chat.scene === 'group';
    await deps.upstream.call(chat.qq_account_id, 'ob11', {
      name: group ? 'mark_group_msg_as_read' : 'mark_private_msg_as_read',
      params: group ? { group_id: chat.peer_id } : { user_id: chat.peer_id },
    });
  } catch (error) {
    deps.logger.warn({ err: error, chatId }, 'read write-back to QQ failed');
  }
}

function messageService(deps: ApiDeps): ServiceImpl<typeof MessageService> {
  return {
    async getHistory(req, ctx) {
      const direction =
        req.direction === HistoryDirection.NEWER ? 'newer' : req.direction === HistoryDirection.AROUND ? 'around' : 'older';
      const chatId = toSafeNumber(req.chatId, 'chat_id');
      const query = {
        anchorSeq: req.anchorSeq === undefined ? null : toSafeNumber(req.anchorSeq, 'anchor_seq'),
        direction,
        limit: clampLimit(req.limit, 50, 200),
      } as const;
      const accountId = requireAuth(ctx).accountId;
      let res = await getHistory(deps.db, accountId, chatId, query);
      // 懒回填：往上翻到了服务端最早的一条，现场向 QQ 要更早的（拉不到就照原样返回）。
      if (direction === 'older' && res.messages.length < query.limit && deps.history) {
        const below = res.messages[0]?.seq ?? query.anchorSeq;
        if (below) {
          const got = await deps.history.backfillOlder(chatId, below, query.limit - res.messages.length).catch((error: unknown) => {
            deps.logger.warn({ err: error, chatId }, 'lazy backfill failed');
            return 0;
          });
          if (got > 0) res = await getHistory(deps.db, accountId, chatId, query);
        }
      }
      return { chatPts: BigInt(res.chatPts), messages: res.messages.map(messageToProto), events: res.events.map(chatEventToProto) };
    },
    async listUnreadMentions(req, ctx) {
      const auth = requireAuth(ctx);
      const chatId = toSafeNumber(req.chatId, 'chat_id');
      const afterSeq = toSafeNumber(req.afterSeq, 'after_seq');
      const mask = MessageFlag.mentionsMe | MessageFlag.mentionAll | MessageFlag.replyToMe;
      const list = await rows<{ seq: number; flags: number }>(
        deps.db,
        sql`select m.seq, m.flags from messages m
              join chats c on c.id = m.chat_id join qq_accounts q on q.id = c.qq_account_id
             where q.account_id = ${auth.accountId} and m.chat_id = ${chatId} and m.seq > ${afterSeq}
               and m.sender_uin <> q.uin and m.state = 'normal' and (m.flags & ${mask}) <> 0 and not m.mention_seen
             order by m.seq desc limit 200`,
      );
      return { mentions: list.map((m) => ({ seq: BigInt(m.seq), flags: m.flags & mask })) };
    },
    async markMentionsSeen(req, ctx) {
      const seqs = req.seqs.map((s) => toSafeNumber(s, 'seqs'));
      try {
        return { changed: await deps.ingest.markMentionsSeen(requireAuth(ctx).accountId, toSafeNumber(req.chatId, 'chat_id'), seqs) };
      } catch (error) {
        if (error instanceof NotFoundError) throw new ConnectError(error.message, Code.NotFound);
        throw error;
      }
    },
    async forwardMessages(req, ctx) {
      const auth = requireAuth(ctx);
      try {
        const entries = await deps.forwarder.forward(auth.accountId, auth.deviceId, {
          fromChatId: toSafeNumber(req.fromChatId, 'from_chat_id'),
          seqs: req.seqs.map((s) => toSafeNumber(s, 'seq')),
          toChatIds: req.toChatIds.map((c) => toSafeNumber(c, 'to_chat_id')),
          bundle: req.bundle,
        });
        return { entries: entries.map(outboxToProto) };
      } catch (error) {
        if (error instanceof ForwardError || error instanceof OutboxError) {
          const code = { invalid: Code.InvalidArgument, not_found: Code.NotFound, media_missing: Code.FailedPrecondition }[error.code];
          throw new ConnectError(error.message, code);
        }
        throw error;
      }
    },
    async sendMessage(req, ctx) {
      const auth = requireAuth(ctx);
      const segments = req.segments.map(outgoingFromProto);
      if (segments.some((s) => s === null)) throw new ConnectError('unknown outgoing segment', Code.InvalidArgument);
      try {
        const entry = await deps.outbox.enqueue(auth.accountId, auth.deviceId, {
          chatId: toSafeNumber(req.chatId, 'chat_id'),
          clientRandomId: toSafeNumber(req.clientRandomId, 'client_random_id'),
          message: {
            segments: segments as NonNullable<(typeof segments)[number]>[],
            ...(req.replyToSeq ? { replyToSeq: toSafeNumber(req.replyToSeq, 'reply_to_seq') } : {}),
          },
        });
        return { entry: outboxToProto(entry) };
      } catch (error) {
        if (error instanceof OutboxError) {
          const code = { invalid: Code.InvalidArgument, not_found: Code.NotFound, media_missing: Code.FailedPrecondition }[error.code];
          throw new ConnectError(error.message, code);
        }
        throw error;
      }
    },
    async searchMessages(req, ctx) {
      const auth = requireAuth(ctx);
      const opt = (v: bigint, field: string) => (v ? toSafeNumber(v, field) : undefined);
      try {
        const since = opt(req.since, 'since');
        const until = opt(req.until, 'until');
        const chatId = opt(req.chatId, 'chat_id');
        const senderId = opt(req.senderId, 'sender_id');
        const result = await searchMessages(
          deps.db,
          auth.accountId,
          req.query,
          {
            ...(chatId ? { chatId } : {}),
            ...(senderId ? { senderId } : {}),
            ...(req.flagsAny ? { flagsAny: req.flagsAny } : {}),
            ...(since ? { since: new Date(since * 1000) } : {}),
            ...(until ? { until: new Date(until * 1000) } : {}),
          },
          {
            limit: clampLimit(req.limit, 30, 100),
            ...(req.before
              ? {
                  before: {
                    time: new Date(toSafeNumber(req.before.time, 'before.time') * 1000),
                    chatId: toSafeNumber(req.before.chatId, 'before.chat_id'),
                    seq: toSafeNumber(req.before.seq, 'before.seq'),
                  },
                }
              : {}),
          },
        );
        return {
          messages: result.messages.map(messageToProto),
          keywords: result.keywords,
          ...(result.next
            ? {
                next: {
                  time: BigInt(Math.floor(result.next.time.getTime() / 1000)),
                  chatId: BigInt(result.next.chatId),
                  seq: BigInt(result.next.seq),
                },
              }
            : {}),
        };
      } catch (error) {
        if (error instanceof SearchQueryError) throw new ConnectError(error.message, Code.InvalidArgument);
        throw error;
      }
    },
    async react(req, ctx) {
      try {
        const message = await deps.interactions.react(
          requireAuth(ctx).accountId,
          toSafeNumber(req.chatId, 'chat_id'),
          toSafeNumber(req.seq, 'seq'),
          req.emojiId,
          req.add,
        );
        return { message: messageToProto(message) };
      } catch (error) {
        throw interactionError(error);
      }
    },
    async getForward(req, ctx) {
      if (req.path.length > 8 || req.path.some((i) => i < 0)) throw new ConnectError('invalid path', Code.InvalidArgument);
      try {
        const bundle = await deps.forwards.get(requireAuth(ctx).accountId, toSafeNumber(req.chatId, 'chat_id'), toSafeNumber(req.seq, 'seq'), req.path);
        return {
          unavailable: bundle.state === 'unavailable',
          nodes: bundle.nodes.map((n) => ({
            senderId: BigInt(n.senderId),
            senderName: n.senderName,
            time: BigInt(n.time),
            segments: n.segments.map(segmentToProto),
          })),
        };
      } catch (error) {
        throw interactionError(error);
      }
    },
    async listSharedMedia(req, ctx) {
      const kinds = req.kinds.map(mediaKindFromProto).filter((k): k is NonNullable<typeof k> => k !== null);
      try {
        const res = await deps.interactions.sharedMedia(requireAuth(ctx).accountId, toSafeNumber(req.chatId, 'chat_id'), {
          kinds,
          ...(req.beforeSeq ? { beforeSeq: toSafeNumber(req.beforeSeq, 'before_seq') } : {}),
          limit: clampLimit(req.limit, 60, 200),
        });
        return {
          nextBeforeSeq: BigInt(res.nextBeforeSeq),
          items: res.items.map((i) => ({
            seq: BigInt(i.seq),
            time: BigInt(Math.floor(i.time.getTime() / 1000)),
            senderId: BigInt(i.senderId),
            kind: mediaKindToProto(i.kind),
            segment: segmentToProto(i.segment),
          })),
        };
      } catch (error) {
        throw interactionError(error);
      }
    },
    async recallMessage(req, ctx) {
      const auth = requireAuth(ctx);
      const chatId = toSafeNumber(req.chatId, 'chat_id');
      const seq = toSafeNumber(req.seq, 'seq');
      const row = await maybeOne<{ qq_msg_id: string | null; peer_uid: string | null; scene: string; peer_id: number; qq_account_id: number }>(
        deps.db,
        sql`select m.qq_msg_id, m.raw->>'peerUid' as peer_uid, c.scene, c.peer_id, c.qq_account_id
              from messages m join chats c on c.id = m.chat_id join qq_accounts q on q.id = c.qq_account_id
             where c.id = ${chatId} and m.seq = ${seq} and q.account_id = ${auth.accountId}`,
      );
      if (!row) throw new ConnectError(`message ${chatId}/${seq} not found`, Code.NotFound);
      if (!row.qq_msg_id) throw new ConnectError('message has no QQ id', Code.FailedPrecondition);
      const upstream = deps.upstream;
      if (!upstream?.isConnected(row.qq_account_id)) throw new ConnectError('QQ is offline', Code.Unavailable);
      try {
        await upstream.call(row.qq_account_id, 'x.recall', {
          chatType: row.scene === 'group' ? 2 : 1,
          peerUid: row.peer_uid ?? (row.scene === 'group' ? String(row.peer_id) : undefined),
          peerUin: String(row.peer_id),
          msgId: row.qq_msg_id,
        });
      } catch (error) {
        // 例如超过撤回时限、不是管理员：QQ 的原因直接给用户看。
        if (error instanceof UpstreamCallError) throw new ConnectError(error.message, Code.FailedPrecondition);
        throw new ConnectError(error instanceof Error ? error.message : String(error), Code.Unavailable);
      }
      return {};
    },
  };
}

function mediaService(deps: ApiDeps): ServiceImpl<typeof MediaService> {
  return {
    async prepareUpload(req, ctx) {
      const auth = requireAuth(ctx);
      try {
        const result = await deps.uploads.prepare(auth.accountId, {
          sha256: req.sha256,
          size: toSafeNumber(req.size, 'size'),
          mime: req.mime,
          name: req.name,
        });
        if (result.exists) return { exists: true, uploadUrl: '', offset: 0n };
        return { exists: false, uploadUrl: `/upload/${result.id}`, offset: BigInt(result.offset) };
      } catch (error) {
        if (error instanceof UploadError) {
          throw new ConnectError(error.message, error.status === 413 ? Code.ResourceExhausted : Code.InvalidArgument);
        }
        throw error;
      }
    },
    async signMediaUrls(req, ctx) {
      const auth = requireAuth(ctx);
      const requested = [...new Set(req.sha256)].filter((s) => SHA256.test(s)).slice(0, 200);
      if (requested.length === 0) return { urls: [] };
      // 只为账号自己的聊天里出现过的内容（以及这些内容的缩略图 / 预览图）签发链接。
      const list = sql.join(requested.map((s) => sql`${s}`), sql`, `);
      const allowed = await rows<{ sha256: string }>(
        deps.db,
        sql`with mine as (
              select u.sha256 from chat_blob_usage u
                join chats c on c.id = u.chat_id join qq_accounts q on q.id = c.qq_account_id
               where q.account_id = ${auth.accountId}
              union
              -- 联系人和群的头像
              select p.avatar_sha256 from peers p join qq_accounts q on q.id = p.qq_account_id
               where q.account_id = ${auth.accountId} and p.avatar_sha256 is not null
              union
              -- 下载过的群文件
              select g.sha256 from group_file_blobs g join qq_accounts q on q.id = g.qq_account_id
               where q.account_id = ${auth.accountId}
            )
            select sha256 from mine where sha256 in (${list})
            union
            select v.variant_sha256 as sha256 from blob_variants v
             where v.variant_sha256 in (${list}) and v.sha256 in (select sha256 from mine)`,
      );
      // 收藏表情（还没在聊天里出现过的也能看）。
      const stickers = await deps.stickers.ownedSha256(auth.accountId);
      for (const sha of requested) if (stickers.has(sha) && !allowed.some((a) => a.sha256 === sha)) allowed.push({ sha256: sha });
      return {
        urls: allowed.map(({ sha256 }) => {
          const signed = deps.signer.sign(sha256);
          return { sha256, url: signed.url, expiresAt: BigInt(signed.expiresAt) };
        }),
      };
    },
    async listMediaUsages(req, ctx) {
      if (!SHA256.test(req.sha256)) throw new ConnectError('invalid sha256', Code.InvalidArgument);
      const usages = await deps.media.listUsages(requireAuth(ctx).accountId, req.sha256);
      return {
        usages: usages.map((u) => ({
          chatId: BigInt(u.chatId),
          scene: sceneToProto(u.scene),
          peerId: BigInt(u.peerId),
          messageSeq: BigInt(u.messageSeq ?? 0),
          forwardBundleId: u.forwardBundleId ?? '',
          nodePath: u.nodePath ?? [],
          senderId: BigInt(u.senderUin ?? 0),
          time: BigInt(Math.floor(u.time.getTime() / 1000)),
          role: u.role,
          kind: mediaKindToProto(u.kind),
        })),
      };
    },
    async getStorageOverview(req, ctx) {
      const o = await deps.media.storageOverview(requireAuth(ctx).accountId, clampLimit(req.limit, 100, 500));
      return {
        physicalBytes: BigInt(o.physicalBytes),
        logicalBytes: BigInt(o.logicalBytes),
        dedupSavedBytes: BigInt(o.dedupSavedBytes),
        blobCount: o.blobCount,
        hotBytes: BigInt(o.hotBytes),
        coldBytes: BigInt(o.coldBytes),
        coldTierEnabled: deps.tiering.enabled,
        chats: o.chats.map(chatStorageToProto),
        categories: (await deps.media.storageCategories()).map((c) => ({ category: c.category, bytes: BigInt(c.bytes), count: c.count })),
        messageBytes: BigInt(await deps.storageBrowser.messageBytes()),
        messageCount: BigInt(await deps.storageBrowser.messageCount()),
        volumes: (await deps.media.volumes()).map((v) => ({
          tier: v.tier,
          available: v.available,
          totalBytes: BigInt(v.totalBytes),
          freeBytes: BigInt(v.freeBytes),
        })),
      };
    },
    async listStorageChats(req, ctx) {
      const list = await deps.storageBrowser.chats(requireAuth(ctx).accountId, req.categories, clampLimit(req.limit, 100, 300));
      return {
        chats: list.map((c) => ({ chatId: BigInt(c.chatId), scene: sceneToProto(c.scene), peerId: BigInt(c.peerId), bytes: BigInt(c.bytes), count: c.count })),
      };
    },
    async listStorageItems(req, ctx) {
      const limit = clampLimit(req.limit, 60, 200);
      const chatId = req.chatId ? toSafeNumber(req.chatId, 'chat_id') : null;
      const list = await deps.storageBrowser.items(requireAuth(ctx).accountId, chatId, req.categories, req.offset, limit + 1);
      return {
        more: list.length > limit,
        items: list.slice(0, limit).map((i) => ({
          sha256: i.sha256,
          size: BigInt(i.size),
          category: i.category,
          state: i.state,
          tier: i.tier,
          refChats: i.refChats,
          chatId: BigInt(i.chatId),
          seq: BigInt(i.seq),
          time: BigInt(i.time ? Math.floor(i.time.getTime() / 1000) : 0),
          mime: i.mime ?? '',
          name: i.name ?? '',
          thumbSha256: i.thumbSha256 ?? '',
        })),
      };
    },
    async addSticker(req, ctx) {
      if (!/^[0-9a-f]{64}$/.test(req.sha256)) throw new ConnectError('sha256 is required', Code.InvalidArgument);
      try {
        await deps.stickers.add(requireAuth(ctx).accountId, req.sha256);
        return {};
      } catch (error) {
        throw new ConnectError(error instanceof Error ? error.message : String(error), Code.Unavailable);
      }
    },
    async listStickers(req, ctx) {
      try {
        const items = await deps.stickers.list(requireAuth(ctx).accountId, req.refresh);
        return { stickers: items.map(stickerToProto) };
      } catch (error) {
        throw new ConnectError(error instanceof Error ? error.message : String(error), Code.Unavailable);
      }
    },
    async requestMedia(req, ctx) {
      const accountId = requireAuth(ctx).accountId;
      const refs = req.refs.slice(0, req.original ? 10 : 200).map((r) => ({
        chatId: toSafeNumber(r.chatId, 'chat_id'),
        seq: toSafeNumber(r.seq, 'seq'),
        ord: r.ord,
      }));
      const queued = await deps.ingest.requestMedia(accountId, refs, req.original ? 'original' : 'thumb');
      if (!req.original) {
        if (queued.length > 0) deps.pokeMediaFetcher();
        return { queued: queued.length };
      }
      // 看大图：当场下载，下完把结果带回去。
      if (deps.fetchMediaNow) await Promise.all(queued.map((id) => deps.fetchMediaNow!(id)));
      const media = await Promise.all(refs.map((r) => deps.ingest.messageMedia(r.chatId, r.seq, r.ord)));
      return { queued: queued.length, media: media.map((m) => (m ? mediaInfo(m) : {})) };
    },
    async prepareStickers(req, ctx) {
      const md5 = req.md5.map((m) => m.toLowerCase()).filter((m) => /^[0-9a-f]{32}$/.test(m));
      const items = await deps.stickers.prepare(requireAuth(ctx).accountId, md5);
      return { stickers: items.map(stickerToProto) };
    },
    async getChatStorage(req, ctx) {
      const auth = requireAuth(ctx);
      const chatId = toSafeNumber(req.chatId, 'chat_id');
      const detail = await deps.media.chatStorage(auth.accountId, chatId, clampLimit(req.topLimit, 20, 100));
      const policy = await effectivePolicy(deps.db, auth.accountId, chatId, detail.summary.scene, deps.defaultAutoFetchMaxBytes);
      return {
        summary: chatStorageToProto(detail.summary),
        kinds: detail.kinds.map((k) => ({
          kind: mediaKindToProto(k.kind),
          count: k.count,
          logicalBytes: BigInt(k.logicalBytes),
          exclusiveBytes: BigInt(k.exclusiveBytes),
          hotBytes: BigInt(k.hotBytes),
          coldBytes: BigInt(k.coldBytes),
          purgedCount: k.purgedCount,
        })),
        largest: detail.largest.map((l) => ({
          sha256: l.sha256,
          size: BigInt(l.size),
          kind: mediaKindToProto(l.kind),
          tier: l.tier,
          shared: l.shared,
          lastAccessAt: BigInt(l.lastAccessAt ? Math.floor(l.lastAccessAt.getTime() / 1000) : 0),
          firstSeq: BigInt(l.firstSeq ?? 0),
        })),
        policy: {
          keepOriginalDays: policy.keepOriginalDays,
          autoFetchMaxBytes: BigInt(policy.autoFetchMaxBytes),
          coldAfterDays: policy.coldAfterDays,
          coldMinBytes: BigInt(policy.coldMinBytes),
          hotQuotaBytes: BigInt(policy.hotQuotaBytes ?? 0),
        },
      };
    },
    async runTiering(req, ctx) {
      if (!deps.tiering.enabled && !req.dryRun) throw new ConnectError('cold storage is not configured (MEDIA_COLD_ROOT)', Code.FailedPrecondition);
      const r = await deps.tiering.run(requireAuth(ctx).accountId, req.dryRun);
      return {
        candidates: r.candidates,
        bytes: BigInt(r.bytes),
        moved: r.moved,
        movedBytes: BigInt(r.movedBytes),
        byAge: r.byReason.age,
        byChatQuota: r.byReason.chat_quota,
        byGlobalQuota: r.byReason.global_quota,
      };
    },
    async planCleanup(req, ctx) {
      const kinds = req.kinds.map(mediaKindFromProto).filter((k): k is NonNullable<typeof k> => k !== null);
      const plan = await deps.media.planCleanup(requireAuth(ctx).accountId, toSafeNumber(req.chatId, 'chat_id'), {
        kinds,
        ...(req.olderThanDays === undefined ? {} : { olderThanDays: req.olderThanDays }),
      });
      return {
        refCount: plan.refCount,
        blobCount: plan.blobCount,
        purgeableBlobCount: plan.purgeableBlobCount,
        freedBytes: BigInt(plan.freedBytes),
        keptSharedBlobCount: plan.keptSharedBlobCount,
      };
    },
    async executeCleanup(req, ctx) {
      const kinds = req.kinds.map(mediaKindFromProto).filter((k): k is NonNullable<typeof k> => k !== null);
      try {
        const report = await deps.cleaner.execute(requireAuth(ctx).accountId, toSafeNumber(req.chatId, 'chat_id'), {
          kinds,
          ...(req.olderThanDays === undefined ? {} : { olderThanDays: req.olderThanDays }),
        });
        return {
          refCount: report.refCount,
          blobCount: report.blobCount,
          purgedBlobCount: report.purgedBlobCount,
          freedBytes: BigInt(report.freedBytes),
          keptSharedBlobCount: report.keptSharedBlobCount,
        };
      } catch (error) {
        if (error instanceof NotFoundError) throw new ConnectError(error.message, Code.NotFound);
        throw error;
      }
    },
    async listStoragePolicies(_req, ctx) {
      const policies = await listPolicies(deps.db, requireAuth(ctx).accountId);
      return {
        policies: policies.map((p) => ({
          scope: POLICY_SCOPES_TO_PROTO[p.scope],
          scene: p.scene ? sceneToProto(p.scene) : Scene.UNSPECIFIED,
          chatId: BigInt(p.chatId ?? 0),
          ...(p.keepOriginalDays === null ? {} : { keepOriginalDays: p.keepOriginalDays }),
          ...(p.autoFetchMaxBytes === null ? {} : { autoFetchMaxBytes: BigInt(p.autoFetchMaxBytes) }),
          ...(p.coldAfterDays === null ? {} : { coldAfterDays: p.coldAfterDays }),
          ...(p.coldMinBytes === null ? {} : { coldMinBytes: BigInt(p.coldMinBytes) }),
          ...(p.hotQuotaBytes === null ? {} : { hotQuotaBytes: BigInt(p.hotQuotaBytes) }),
        })),
      };
    },
    async setStoragePolicy(req, ctx) {
      const p = req.policy;
      if (!p) throw new ConnectError('policy is required', Code.InvalidArgument);
      await policyCall(() =>
        setPolicy(deps.db, requireAuth(ctx).accountId, {
          ...policyScopeFromProto(p.scope, p.scene, p.chatId),
          keepOriginalDays: p.keepOriginalDays ?? null,
          autoFetchMaxBytes: p.autoFetchMaxBytes === undefined ? null : toSafeNumber(p.autoFetchMaxBytes, 'auto_fetch_max_bytes'),
          coldAfterDays: p.coldAfterDays ?? null,
          coldMinBytes: p.coldMinBytes === undefined ? null : toSafeNumber(p.coldMinBytes, 'cold_min_bytes'),
          hotQuotaBytes: p.hotQuotaBytes === undefined ? null : toSafeNumber(p.hotQuotaBytes, 'hot_quota_bytes'),
        }),
      );
      return {};
    },
    async deleteStoragePolicy(req, ctx) {
      const deleted = await policyCall(() =>
        deletePolicy(deps.db, requireAuth(ctx).accountId, policyScopeFromProto(req.scope, req.scene, req.chatId)),
      );
      return { deleted };
    },
  };
}

function stickerToProto(s: StickerItem) {
  return { md5: s.md5, sha256: s.sha256 ?? '', thumbSha256: s.thumbSha256 ?? '', desc: s.desc, market: s.market };
}

function chatStorageToProto(c: ChatStorageSummary) {
  return {
    chatId: BigInt(c.chatId),
    scene: sceneToProto(c.scene),
    peerId: BigInt(c.peerId),
    logicalBytes: BigInt(c.logicalBytes),
    exclusiveBytes: BigInt(c.exclusiveBytes),
    blobCount: c.blobCount,
    hotBytes: BigInt(c.hotBytes),
    coldBytes: BigInt(c.coldBytes),
  };
}

const POLICY_SCOPES_TO_PROTO = { global: PolicyScope.GLOBAL, scene: PolicyScope.SCENE, chat: PolicyScope.CHAT } as const;

function policyScopeFromProto(scope: PolicyScope, scene: Scene, chatId: bigint) {
  const domainScope = scope === PolicyScope.GLOBAL ? 'global' : scope === PolicyScope.SCENE ? 'scene' : scope === PolicyScope.CHAT ? 'chat' : null;
  if (!domainScope) throw new ConnectError('policy scope is required', Code.InvalidArgument);
  const domainScene = scene === Scene.FRIEND ? 'friend' : scene === Scene.GROUP ? 'group' : scene === Scene.TEMP ? 'temp' : null;
  return { scope: domainScope, scene: domainScene, chatId: chatId ? toSafeNumber(chatId, 'chat_id') : null } as const;
}

async function policyCall<T>(fn: () => Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    if (error instanceof PolicyError) throw new ConnectError(error.message, error.code === 'not_found' ? Code.NotFound : Code.InvalidArgument);
    throw error;
  }
}

function callService(deps: ApiDeps): ServiceImpl<typeof CallService> {
  return {
    async getActiveCall(_req, ctx) {
      const call = await deps.calls.active(requireAuth(ctx).accountId);
      return call ? { call: callToProto(call) } : {};
    },
    async answerCall(req, ctx) {
      const auth = requireAuth(ctx);
      if (!req.callId) throw new ConnectError('call_id is required', Code.InvalidArgument);
      try {
        const res = await deps.calls.answer(auth.accountId, auth.deviceId, req.callId);
        return { call: callToProto(res.call), livekitUrl: res.url, livekitToken: res.token, room: res.room };
      } catch (error) {
        if (error instanceof CallError) {
          const code = { not_found: Code.NotFound, not_ringing: Code.FailedPrecondition, unavailable: Code.Unavailable }[error.code];
          throw new ConnectError(error.message, code);
        }
        if (error instanceof UpstreamCallError) throw new ConnectError(error.message, Code.FailedPrecondition);
        throw error;
      }
    },
    async listCalls(req, ctx) {
      const before = req.before ? new Date(Number(req.before) * 1000) : undefined;
      const list = await deps.calls.list(requireAuth(ctx).accountId, clampLimit(req.limit, 50, 200), before);
      return { calls: list.map(callToProto) };
    },
  };
}

function contactService(deps: ApiDeps): ServiceImpl<typeof ContactService> {
  const userProfile = (p: UserProfile) => ({
    peer: peerToProto(p.peer),
    sex: p.sex,
    age: p.age,
    level: p.level,
    refreshedAt: BigInt(p.refreshedAt ? Math.floor(p.refreshedAt.getTime() / 1000) : 0),
  });
  const wrap = async <T>(fn: () => Promise<T>): Promise<T> => {
    try {
      return await fn();
    } catch (error) {
      if (error instanceof ContactError) throw new ConnectError(error.message, error.code === 'failed' ? Code.FailedPrecondition : Code.NotFound);
      if (error instanceof Error && error.message === 'QQ is offline') throw new ConnectError(error.message, Code.Unavailable);
      throw error;
    }
  };
  const secs = (d: Date | null) => BigInt(d ? Math.floor(d.getTime() / 1000) : 0);
  return {
    async listFriends(_req, ctx) {
      const accountId = requireAuth(ctx).accountId;
      return wrap(async () => ({
        friends: (await deps.contacts.listPeers(accountId, 'user')).map(peerToProto),
        categories: (await deps.contacts.listCategories(accountId)).map((c) => ({
          id: c.id,
          name: c.name,
          sort: c.sort,
          specialCare: c.specialCare,
          userIds: c.userIds.map((id) => BigInt(id)),
        })),
      }));
    },
    async listGroups(_req, ctx) {
      return wrap(async () => ({ groups: (await deps.contacts.listPeers(requireAuth(ctx).accountId, 'group')).map(peerToProto) }));
    },
    async getUserProfile(req, ctx) {
      return wrap(async () => {
        const res = await deps.contacts.userProfile(requireAuth(ctx).accountId, toSafeNumber(req.userId, 'user_id'), req.refresh);
        return { profile: userProfile(res.profile), stale: res.stale };
      });
    },
    async getGroupProfile(req, ctx) {
      return wrap(async () => {
        const res = await deps.contacts.groupProfile(requireAuth(ctx).accountId, toSafeNumber(req.groupId, 'group_id'), req.refresh);
        return {
          stale: res.stale,
          profile: {
            peer: peerToProto(res.profile.peer),
            maxMemberCount: res.profile.maxMemberCount,
            ownerId: BigInt(res.profile.ownerId),
            refreshedAt: secs(res.profile.refreshedAt),
          },
        };
      });
    },
    async listGroupMembers(req, ctx) {
      return wrap(async () => {
        const res = await deps.contacts.groupMembers(requireAuth(ctx).accountId, toSafeNumber(req.groupId, 'group_id'), {
          refresh: req.refresh,
          offset: Math.max(0, req.offset),
          limit: clampLimit(req.limit, 200, 2000),
        });
        return {
          total: res.total,
          stale: res.stale,
          members: res.members.map((m) => ({ ...m, userId: BigInt(m.userId), joinedAt: secs(m.joinedAt), lastSentAt: secs(m.lastSentAt) })),
        };
      });
    },
    async listGroupNotices(req, ctx) {
      return groupContent(async () => ({
        notices: (await deps.groupContent.notices(requireAuth(ctx).accountId, toSafeNumber(req.groupId, 'group_id'))).map((n) => ({
          id: n.id,
          senderId: BigInt(n.senderId),
          senderName: n.senderName,
          time: BigInt(n.time),
          text: n.text,
          imageUrls: n.imageUrls,
          confirmRequired: n.confirmRequired,
          readCount: n.readCount,
        })),
      }));
    },
    async listGroupEssence(req, ctx) {
      return groupContent(async () => ({
        items: (await deps.groupContent.essence(requireAuth(ctx).accountId, toSafeNumber(req.groupId, 'group_id'))).map((e) => ({
          seq: BigInt(e.seq),
          senderId: BigInt(e.senderId),
          senderName: e.senderName,
          operatorName: e.operatorName,
          time: BigInt(e.time),
          ...(e.message ? { message: messageToProto(e.message) } : {}),
          text: e.text,
          imageUrls: e.imageUrls,
        })),
      }));
    },
    async listGroupFiles(req, ctx) {
      return groupContent(async () => {
        const res = await deps.groupContent.files(requireAuth(ctx).accountId, toSafeNumber(req.groupId, 'group_id'), req.folderId);
        return {
          folders: res.folders.map((f) => ({ ...f, modifyTime: BigInt(f.modifyTime) })),
          files: res.files.map((f) => ({
            ...f,
            size: BigInt(f.size),
            modifyTime: BigInt(f.modifyTime),
            deadTime: BigInt(f.deadTime),
            uploaderId: BigInt(f.uploaderId),
            sha256: f.sha256 ?? '',
          })),
        };
      });
    },
    async fetchGroupFile(req, ctx) {
      return groupContent(async () => {
        const f = await deps.groupContent.fetchFile(requireAuth(ctx).accountId, toSafeNumber(req.groupId, 'group_id'), req.fileId, req.busid, req.name);
        return { sha256: f.sha256, size: BigInt(f.size), mime: f.mime ?? '' };
      });
    },
    async getAvatars(req, ctx) {
      const accountId = requireAuth(ctx).accountId;
      const ids = req.userIds.map((id) => toSafeNumber(id, 'user_ids')).filter((id) => id > 0);
      const groupIds = req.groupIds.map((id) => toSafeNumber(id, 'group_ids')).filter((id) => id > 0);
      const found = ids.length > 0 ? await wrap(() => deps.contacts.avatars(accountId, ids)) : new Map<number, string>();
      const groups = groupIds.length > 0 ? await wrap(() => deps.contacts.groupAvatars(accountId, groupIds)) : new Map<number, string>();
      deps.logger.debug({ requested: ids.length + groupIds.length, found: found.size + groups.size }, 'GetAvatars');
      return {
        avatars: [...found].map(([userId, sha256]) => ({ userId: BigInt(userId), sha256 })),
        groups: [...groups].map(([groupId, sha256]) => ({ userId: BigInt(groupId), sha256 })),
      };
    },
    async deleteFriend(req, ctx) {
      const userId = toSafeNumber(req.userId, 'user_id');
      await wrap(() => deps.contacts.deleteFriend(requireAuth(ctx).accountId, userId));
      return {};
    },
    async refreshContacts(_req, ctx) {
      const auth = requireAuth(ctx);
      const qq = await maybeOne<{ id: number }>(deps.db, sql`select id from qq_accounts where account_id = ${auth.accountId} order by id limit 1`);
      if (!qq) throw new ConnectError('no QQ account is linked', Code.NotFound);
      if (!deps.upstream?.isConnected(qq.id)) throw new ConnectError('QQ is offline', Code.Unavailable);
      return deps.contacts.refreshLists(qq.id);
    },
  };
}

function adminService(deps: ApiDeps): ServiceImpl<typeof AdminService> {
  const secs = (d: Date | null) => BigInt(d ? Math.floor(d.getTime() / 1000) : 0);
  return {
    async getStatus(_req, ctx) {
      const s = await deps.admin.status(requireAuth(ctx).accountId);
      return {
        qq: s.qq.map((q) => ({ ...q, qqAccountId: BigInt(q.qqAccountId), uin: BigInt(q.uin), connectedAt: secs(q.connectedAt), lastEventAt: secs(q.lastEventAt) })),
        inbox: s.inbox,
        archive: { ...s.archive, missingSeqs: BigInt(s.archive.missingSeqs) },
        media: s.media,
        outbox: s.outbox,
        calls: {
          ...s.calls,
          ...(s.calls.activeCall ? { activeCall: callToProto(s.calls.activeCall) } : { activeCall: undefined }),
        },
        storage: { hotBytes: BigInt(s.storage.hotBytes), coldBytes: BigInt(s.storage.coldBytes), coldTierEnabled: s.storage.coldTierEnabled },
        serverStartedAt: secs(s.serverStartedAt),
      };
    },
    async getQqLogin(_req, ctx) {
      requireAuth(ctx);
      if (!deps.napcatWebUi) return { unavailable: true };
      try {
        return await deps.napcatWebUi.loginState();
      } catch (error) {
        return { unavailable: true, error: error instanceof Error ? error.message : String(error) };
      }
    },
    async refreshQqLoginQrcode(_req, ctx) {
      requireAuth(ctx);
      if (!deps.napcatWebUi) throw new ConnectError('NAPCAT_WEBUI_TOKEN is not configured', Code.FailedPrecondition);
      try {
        return { qrcodeUrl: await deps.napcatWebUi.refreshQrcode() };
      } catch (error) {
        throw new ConnectError(error instanceof Error ? error.message : String(error), Code.Unavailable);
      }
    },
    async listArchiveStatus(req, ctx) {
      const list = await deps.admin.archiveStatus(requireAuth(ctx).accountId, clampLimit(req.limit, 100, 1000));
      return {
        chats: list.map((c) => ({
          ...c,
          chatId: BigInt(c.chatId),
          scene: sceneToProto(c.scene),
          peerId: BigInt(c.peerId),
          earliestSeq: BigInt(c.earliestSeq),
          topSeq: BigInt(c.topSeq),
          missingSeqs: BigInt(c.missingSeqs),
        })),
      };
    },
    async setDeepArchive(req, ctx) {
      const ok = await deps.admin.setDeepArchive(requireAuth(ctx).accountId, toSafeNumber(req.chatId, 'chat_id'), req.enabled);
      if (!ok) throw new ConnectError(`chat ${req.chatId} not found`, Code.NotFound);
      return {};
    },
    async fillHolesNow(_req, ctx) {
      await deps.admin.fillHolesNow(requireAuth(ctx).accountId);
      return {};
    },
  };
}

/** 群公告 / 精华 / 文件的错误 → Connect 错误码。 */
async function groupContent<T>(fn: () => Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    if (error instanceof GroupContentError) {
      const code = { not_found: Code.NotFound, offline: Code.Unavailable, unavailable: Code.FailedPrecondition }[error.code];
      throw new ConnectError(error.message, code);
    }
    throw error;
  }
}

export function registerServices(router: ConnectRouter, deps: ApiDeps): void {
  router.service(AdminService, adminService(deps));
  router.service(ContactService, contactService(deps));
  router.service(CallService, callService(deps));
  router.service(AuthService, authService(deps));
  router.service(SyncService, syncService(deps));
  router.service(DialogService, dialogService(deps));
  router.service(MessageService, messageService(deps));
  router.service(MediaService, mediaService(deps));
}

function interactionError(error: unknown): unknown {
  if (error instanceof InteractionError) {
    const code = { not_found: Code.NotFound, unsupported: Code.FailedPrecondition, offline: Code.Unavailable, upstream: Code.FailedPrecondition }[error.code];
    return new ConnectError(error.message, code);
  }
  if (error instanceof UpstreamCallError) return new ConnectError(error.message, Code.FailedPrecondition);
  return error;
}

function clampLimit(value: number, fallback: number, max: number): number {
  if (!value) return fallback;
  return Math.max(1, Math.min(value, max));
}
