// 数据库表结构（docs/design.md 4.4 / 4.6 / 4.7）。迁移由 drizzle-kit 从这里生成：pnpm db:generate。
// 所有 int8 列都按 JS number 处理（见 db/client.ts 的解析器）：id、pts、seq、QQ 号都远小于 2^53。
import { sql } from 'drizzle-orm';
import {
  bigint,
  bigserial,
  boolean,
  check,
  customType,
  index,
  integer,
  jsonb,
  pgTable,
  primaryKey,
  text,
  timestamp,
  unique,
} from 'drizzle-orm/pg-core';

const bytea = customType<{ data: Buffer; driverData: Buffer }>({ dataType: () => 'bytea' });
const int8multirange = customType<{ data: string; driverData: string }>({ dataType: () => 'int8multirange' });

const id = () => bigserial('id', { mode: 'number' }).primaryKey();
const ref = (name: string) => bigint(name, { mode: 'number' });
const ts = (name: string) => timestamp(name, { withTimezone: true, mode: 'date' });

// ==================== 账号与设备 ====================

export const accounts = pgTable('accounts', {
  id: id(),
  username: text('username').notNull().unique(),
  passwordHash: text('password_hash').notNull(),
  createdAt: ts('created_at').notNull().defaultNow(),
});

/** 每个服务端账号一行：全局 pts。用行锁串行化分配，保证"序号顺序 = 提交顺序"。 */
export const syncState = pgTable('sync_state', {
  accountId: ref('account_id')
    .primaryKey()
    .references(() => accounts.id, { onDelete: 'cascade' }),
  pts: ref('pts').notNull().default(0),
  /** 低于这个 pts 的墓碑已被清理；客户端游标比它旧时只能全量重拉（TooLong）。 */
  tombstoneHorizonPts: ref('tombstone_horizon_pts').notNull().default(0),
});

export const devices = pgTable(
  'devices',
  {
    id: id(),
    accountId: ref('account_id')
      .notNull()
      .references(() => accounts.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    platform: text('platform').notNull(),
    /** sha256(令牌)：库里不存令牌原文。 */
    tokenHash: bytea('token_hash').notNull().unique(),
    apnsToken: text('apns_token'),
    apnsVoipToken: text('apns_voip_token'),
    apnsEnv: text('apns_env'),
    createdAt: ts('created_at').notNull().defaultNow(),
    lastSeenAt: ts('last_seen_at'),
    revokedAt: ts('revoked_at'),
  },
  (t) => [index('devices_account_idx').on(t.accountId)],
);

// ==================== QQ 号、联系人与会话 ====================

export const qqAccounts = pgTable('qq_accounts', {
  id: id(),
  accountId: ref('account_id')
    .notNull()
    .references(() => accounts.id, { onDelete: 'cascade' }),
  uin: ref('uin').notNull().unique(),
  uid: text('uid'),
  nickname: text('nickname'),
  upstreamKind: text('upstream_kind').notNull().default('napcat'),
  createdAt: ts('created_at').notNull().defaultNow(),
});

/** 好友、群等资料。按 QQ 号隔离（备注、群名片都是相对某个 QQ 号的）。 */
export const peers = pgTable(
  'peers',
  {
    qqAccountId: ref('qq_account_id')
      .notNull()
      .references(() => qqAccounts.id, { onDelete: 'cascade' }),
    kind: text('kind').notNull(),
    peerId: ref('peer_id').notNull(),
    uid: text('uid'),
    name: text('name'),
    remark: text('remark'),
    isFriend: boolean('is_friend').notNull().default(false),
    memberCount: integer('member_count'),
    avatarSha256: text('avatar_sha256'),
    /** 个性签名（好友）/ 群简介。 */
    sign: text('sign'),
    /** 群：全员禁言中。 */
    muteAll: boolean('mute_all').notNull().default(false),
    /** 群：自己被禁言到什么时候（空 = 没被禁言）。 */
    selfMutedUntil: ts('self_muted_until'),
    /** 群：自己的身份 owner / admin / member（不知道时为空）。 */
    selfRole: text('self_role'),
    /** 其他资料（性别、等级、群主等），按 QQ 返回的原样挑选保存。 */
    extra: jsonb('extra').notNull().default({}),
    /** 最后一次从 QQ 刷新资料、检查头像的时间。 */
    profileRefreshedAt: ts('profile_refreshed_at'),
    /** 最后一次变更时的全局 pts。 */
    pts: ref('pts').notNull(),
    updatedAt: ts('updated_at').notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.qqAccountId, t.kind, t.peerId] }),
    index('peers_pts_idx').on(t.qqAccountId, t.pts),
    check('peers_kind_check', sql`${t.kind} in ('user', 'group')`),
  ],
);

/** 会话（Telegram 的 dialog）。chat_pts 是会话内消息流的序号；dialog_pts 是会话行最后变更时的全局 pts。 */
export const chats = pgTable(
  'chats',
  {
    id: id(),
    qqAccountId: ref('qq_account_id')
      .notNull()
      .references(() => qqAccounts.id, { onDelete: 'cascade' }),
    scene: text('scene').notNull(),
    peerId: ref('peer_id').notNull(),
    topSeq: ref('top_seq'),
    topTime: ts('top_time'),
    unreadCount: integer('unread_count').notNull().default(0),
    /** 未读里 @我 的条数。 */
    unreadMentions: integer('unread_mentions').notNull().default(0),
    /** 未读里 @全体成员 的条数（不含同时 @我 的）。 */
    unreadMentionAll: integer('unread_mention_all').notNull().default(0),
    /** 未读里回复我的条数。 */
    unreadReplies: integer('unread_replies').notNull().default(0),
    readInboxMaxSeq: ref('read_inbox_max_seq').notNull().default(0),
    pinned: boolean('pinned').notNull().default(false),
    /** 置顶时间（置顶会话按它倒序排）。 */
    pinnedAt: ts('pinned_at'),
    /** default / all / mentions / muted / archived（收进群助手）。 */
    notifyPolicy: text('notify_policy').notNull().default('default'),
    /** @全体成员 是否提醒。 */
    mentionAllNotify: boolean('mention_all_notify').notNull().default(true),
    /** 用户在本 App 里改过置顶 / 通知设置：之后从 QQ 同步的设置不再覆盖它。 */
    pinnedLocal: boolean('pinned_local').notNull().default(false),
    notifyLocal: boolean('notify_local').notNull().default(false),
    draft: jsonb('draft'),
    chatPts: ref('chat_pts').notNull().default(0),
    dialogPts: ref('dialog_pts').notNull(),
    /** 已与 QQ 对账确认完整的 seq 区间；区间内由撤回造成的空洞视为正常。 */
    verifiedRanges: int8multirange('verified_ranges').notNull().default('{}'),
    /** 深度归档：要求从头补全历史的时间；为空表示只补 [最早一条, 最新一条] 之间的缺口。 */
    deepArchiveAt: ts('deep_archive_at'),
    createdAt: ts('created_at').notNull().defaultNow(),
  },
  (t) => [
    unique('chats_peer_unique').on(t.qqAccountId, t.scene, t.peerId),
    index('chats_dialog_pts_idx').on(t.qqAccountId, t.dialogPts),
    index('chats_top_time_idx').on(t.qqAccountId, t.topTime),
    check('chats_scene_check', sql`${t.scene} in ('friend', 'group', 'temp')`),
  ],
);

export const messages = pgTable(
  'messages',
  {
    id: id(),
    chatId: ref('chat_id')
      .notNull()
      .references(() => chats.id, { onDelete: 'cascade' }),
    seq: ref('seq').notNull(),
    /** NT msgId（64 位，按文本存）与 NapCat 短 ID 都只是辅助字段。 */
    qqMsgId: text('qq_msg_id'),
    random: ref('random'),
    senderUin: ref('sender_uin').notNull(),
    time: ts('time').notNull(),
    kind: text('kind').notNull().default('normal'),
    segments: jsonb('segments').notNull(),
    text: text('text').notNull().default(''),
    replyToSeq: ref('reply_to_seq'),
    flags: integer('flags').notNull().default(0),
    state: text('state').notNull().default('normal'),
    recalledBy: ref('recalled_by'),
    recalledAt: ts('recalled_at'),
    reactions: jsonb('reactions'),
    /** 最后一次变更时的 chat_pts。 */
    version: ref('version').notNull(),
    source: text('source').notNull(),
    raw: jsonb('raw'),
    createdAt: ts('created_at').notNull().defaultNow(),
  },
  (t) => [
    unique('messages_chat_seq_unique').on(t.chatId, t.seq),
    index('messages_version_idx').on(t.chatId, t.version),
    index('messages_text_pgroonga_idx').using('pgroonga', t.text),
    check('messages_state_check', sql`${t.state} in ('normal', 'recalled')`),
    check('messages_kind_check', sql`${t.kind} in ('normal', 'service', 'call')`),
  ],
);

/** 墓碑：被删除的会话或联系人，带删除时的 pts，供增量同步告诉客户端"这一行没了"。 */
export const tombstones = pgTable(
  'tombstones',
  {
    accountId: ref('account_id')
      .notNull()
      .references(() => accounts.id, { onDelete: 'cascade' }),
    pts: ref('pts').notNull(),
    entity: text('entity').notNull(),
    entityKey: text('entity_key').notNull(),
    createdAt: ts('created_at').notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.accountId, t.pts] })],
);

/** 发送队列：client_random_id 唯一，网络重试不会重复发往 QQ。 */
/**
 * 发件箱（docs/design.md 4.7"发送幂等"）：客户端的发送请求先落在这里，再由服务端发往 QQ。
 * (account_id, client_random_id) 唯一，客户端重试同一条消息不会发出两条。按全局 pts 同步给所有设备。
 */
export const outbox = pgTable(
  'outbox',
  {
    id: id(),
    accountId: ref('account_id')
      .notNull()
      .references(() => accounts.id, { onDelete: 'cascade' }),
    chatId: ref('chat_id')
      .notNull()
      .references(() => chats.id, { onDelete: 'cascade' }),
    deviceId: ref('device_id').references(() => devices.id, { onDelete: 'set null' }),
    clientRandomId: ref('client_random_id').notNull(),
    /** { segments: OutgoingSegment[], replyToSeq?: number } */
    content: jsonb('content').notNull(),
    /** pending → sending → sent | failed（失败后用同一个 client_random_id 重发即回到 pending）。 */
    state: text('state').notNull().default('pending'),
    /** 发送成功后的消息 seq。 */
    resultSeq: ref('result_seq'),
    qqMsgId: text('qq_msg_id'),
    error: text('error'),
    attempts: integer('attempts').notNull().default(0),
    nextAttemptAt: ts('next_attempt_at'),
    /** 最后一次变更时的全局 pts。 */
    pts: ref('pts').notNull(),
    createdAt: ts('created_at').notNull().defaultNow(),
    updatedAt: ts('updated_at').notNull().defaultNow(),
  },
  (t) => [
    unique('outbox_random_unique').on(t.accountId, t.clientRandomId),
    index('outbox_pts_idx').on(t.accountId, t.pts),
    index('outbox_queue_idx')
      .on(t.id)
      .where(sql`${t.state} = 'pending'`),
    check('outbox_state_check', sql`${t.state} in ('pending', 'sending', 'sent', 'failed')`),
  ],
);

// ==================== 媒体 ====================

/** 内容实体：按 sha256 去重，物理上只存一份。 */
export const blobs = pgTable(
  'blobs',
  {
    sha256: text('sha256').primaryKey(),
    md5: text('md5').notNull(),
    /** 前 10 MiB 的 md5：QQ 大文件只提供这个（file10MMd5），配合 size 做下载前去重。 */
    md5Head: text('md5_head').notNull(),
    size: ref('size').notNull(),
    mime: text('mime'),
    kind: text('kind'),
    width: integer('width'),
    height: integer('height'),
    durationMs: integer('duration_ms'),
    /** 图片的模糊占位图；同样的内容再出现时直接复用，不必重新解码。 */
    thumbhash: text('thumbhash'),
    /** 语音波形（base64，64 个 0–255 的振幅），随消息下发，气泡不用下载音频就能画出来。 */
    waveform: text('waveform'),
    /** hot = 热存储（MEDIA_ROOT）；cold = 冷存储（MEDIA_COLD_ROOT，廉价大硬盘）。新内容一律先进热存储。 */
    tier: text('tier').notNull().default('hot'),
    /** 下沉到冷存储的时间。 */
    coldSince: ts('cold_since'),
    /** 原件被访问的次数（同一内容 10 分钟内只算一次；进出冷存储时清零），用于判断要不要提回热存储。 */
    accessCount: integer('access_count').notNull().default(0),
    storageKey: text('storage_key').notNull(),
    /** present = 原件在；purged = 原件已按策略清理（缩略图等变体仍保留）。 */
    state: text('state').notNull().default('present'),
    /** 引用它的不同会话数（增量维护）。 */
    refChats: integer('ref_chats').notNull().default(0),
    createdAt: ts('created_at').notNull().defaultNow(),
    lastAccessAt: ts('last_access_at'),
  },
  (t) => [
    index('blobs_md5_idx').on(t.md5),
    index('blobs_md5_head_idx').on(t.md5Head, t.size),
    check('blobs_state_check', sql`${t.state} in ('present', 'purged')`),
  ],
);

/** 派生版本（缩略图、预览图、语音转码、视频封面…），本身也是 blob。 */
export const blobVariants = pgTable(
  'blob_variants',
  {
    sha256: text('sha256')
      .notNull()
      .references(() => blobs.sha256, { onDelete: 'cascade' }),
    variant: text('variant').notNull(),
    variantSha256: text('variant_sha256')
      .notNull()
      .references(() => blobs.sha256),
  },
  (t) => [primaryKey({ columns: [t.sha256, t.variant] }), index('blob_variants_variant_idx').on(t.variantSha256)],
);

/**
 * 会话里的服务事件（QQ 的"小灰条"）：入群、退群、禁言、戳一戳、设精华、群文件上传等。
 * 没有 QQ 的消息 seq，按时间与消息穿插显示；与消息共用会话的 chat_pts（version）。
 */
export const chatEvents = pgTable(
  'chat_events',
  {
    id: id(),
    chatId: ref('chat_id')
      .notNull()
      .references(() => chats.id, { onDelete: 'cascade' }),
    kind: text('kind').notNull(),
    time: ts('time').notNull(),
    actorId: ref('actor_id'),
    targetId: ref('target_id'),
    /** 相关的消息（例如被设为精华的那条）。 */
    refSeq: ref('ref_seq'),
    data: jsonb('data').notNull().default({}),
    /** 最后一次变更时的 chat_pts。 */
    version: ref('version').notNull(),
    /** 来自哪条上游事件（收件箱重新处理时据此去重）。 */
    sourceEventId: ref('source_event_id').unique(),
    createdAt: ts('created_at').notNull().defaultNow(),
  },
  (t) => [index('chat_events_version_idx').on(t.chatId, t.version), index('chat_events_time_idx').on(t.chatId, t.time)],
);

/** 媒体的每一次出现。下载完成前 sha256 为空。 */
export const mediaRefs = pgTable(
  'media_refs',
  {
    id: id(),
    chatId: ref('chat_id')
      .notNull()
      .references(() => chats.id, { onDelete: 'cascade' }),
    messageSeq: ref('message_seq'),
    /** 不属于消息、而属于服务事件的媒体（例如群文件）。 */
    chatEventId: ref('chat_event_id').references(() => chatEvents.id, { onDelete: 'cascade' }),
    ordinal: integer('ordinal').notNull().default(0),
    forwardBundleId: text('forward_bundle_id'),
    nodePath: integer('node_path').array(),
    role: text('role').notNull(),
    kind: text('kind').notNull(),
    sha256: text('sha256').references(() => blobs.sha256),
    qqMd5: text('qq_md5'),
    qqMd5Partial: boolean('qq_md5_partial').notNull().default(false),
    qqFileUuid: text('qq_file_uuid'),
    qqResourceId: text('qq_resource_id'),
    qqFileId: text('qq_file_id'),
    url: text('url'),
    urlExpiresAt: ts('url_expires_at'),
    size: ref('size'),
    name: text('name'),
    mime: text('mime'),
    fetchState: text('fetch_state').notNull().default('pending'),
    attempts: integer('attempts').notNull().default(0),
    /** 失败后下一次重试的时间；为空表示不再重试（或尚未失败过）。 */
    nextAttemptAt: ts('next_attempt_at'),
    lastError: text('last_error'),
    /** 上游定位信息（NapCat：会话 + msgId + elementId 等），换新下载链接时原样交给上游。 */
    locator: jsonb('locator'),
    thumbhash: text('thumbhash'),
    /** 引用级覆盖：null 表示按策略；false 表示这一处不再需要原件（例如执行了"按条件清理"）。 */
    keepOriginal: boolean('keep_original'),
    senderUin: ref('sender_uin'),
    time: ts('time').notNull(),
    createdAt: ts('created_at').notNull().defaultNow(),
  },
  (t) => [
    index('media_refs_sha256_idx').on(t.sha256),
    index('media_refs_chat_kind_time_idx').on(t.chatId, t.kind, t.time),
    index('media_refs_message_idx').on(t.chatId, t.messageSeq),
    index('media_refs_qq_md5_idx').on(t.qqMd5),
    index('media_refs_pending_idx')
      .on(t.fetchState, t.nextAttemptAt)
      .where(sql`${t.fetchState} in ('pending', 'failed', 'fetching')`),
  ],
);

/** "会话—媒体"的去重关联：同一会话里出现多次只算一份。 */
export const chatBlobUsage = pgTable(
  'chat_blob_usage',
  {
    chatId: ref('chat_id')
      .notNull()
      .references(() => chats.id, { onDelete: 'cascade' }),
    sha256: text('sha256')
      .notNull()
      .references(() => blobs.sha256),
    refCount: integer('ref_count').notNull(),
  },
  (t) => [primaryKey({ columns: [t.chatId, t.sha256] }), index('chat_blob_usage_sha256_idx').on(t.sha256)],
);

/** 按会话的占用统计（增量维护，定期全量校正）。 */
export const chatStorage = pgTable('chat_storage', {
  chatId: ref('chat_id')
    .primaryKey()
    .references(() => chats.id, { onDelete: 'cascade' }),
  logicalBytes: ref('logical_bytes').notNull().default(0),
  exclusiveBytes: ref('exclusive_bytes').notNull().default(0),
  blobCount: integer('blob_count').notNull().default(0),
  updatedAt: ts('updated_at').notNull().defaultNow(),
});

/** 存储策略：全局 / 按会话类型 / 单个会话三层。 */
export const storagePolicies = pgTable(
  'storage_policies',
  {
    id: id(),
    accountId: ref('account_id')
      .notNull()
      .references(() => accounts.id, { onDelete: 'cascade' }),
    scope: text('scope').notNull(),
    scene: text('scene'),
    chatId: ref('chat_id').references(() => chats.id, { onDelete: 'cascade' }),
    /** 原件保留天数：null = 继承上一层（全局也没设 = 永久）；-1 = 永久；0 = 只保留缩略图；N = 保留 N 天。见 media/policies.ts。 */
    keepOriginalDays: integer('keep_original_days'),
    /** 自动下载上限（字节）：null = 继承上一层。 */
    autoFetchMaxBytes: ref('auto_fetch_max_bytes'),
    /** 多少天没被访问就把原件下沉到冷存储：null = 继承；-1 = 永不。 */
    coldAfterDays: integer('cold_after_days'),
    /** 只把不小于这个大小（字节）的原件下沉：null = 继承（全局也没设 = 1 MiB）。 */
    coldMinBytes: ref('cold_min_bytes'),
    /** 热存储配额（字节）：会话级 = 本会话独占原件的热存储上限；全局 = 整体热存储上限。超出时按最久未访问先下沉。 */
    hotQuotaBytes: ref('hot_quota_bytes'),
    recompressAfterDays: integer('recompress_after_days'),
  },
  (t) => [
    unique('storage_policies_scope_unique').on(t.accountId, t.scope, t.scene, t.chatId).nullsNotDistinct(),
    check('storage_policies_scope_check', sql`${t.scope} in ('global', 'scene', 'chat')`),
  ],
);

/**
 * 上游事件队列（插件端的持久队列）在服务端的进度。队列 id 变了（插件数据目录重建）就是新队列，游标从 1 重新开始。
 */
export const upstreamQueues = pgTable('upstream_queues', {
  queueId: text('queue_id').primaryKey(),
  qqAccountId: ref('qq_account_id')
    .notNull()
    .references(() => qqAccounts.id, { onDelete: 'cascade' }),
  /** 已持久保存的最大游标（续传从它之后开始）。 */
  lastCursor: ref('last_cursor').notNull().default(0),
  firstSeenAt: ts('first_seen_at').notNull().defaultNow(),
  lastSeenAt: ts('last_seen_at').notNull().defaultNow(),
});

/**
 * 收件箱：上游原始事件先原样落库再映射（docs/design.md 4.3）。映射有 bug 时修好后可以重新处理，不丢数据。
 * state：pending 待处理 / done 已入库 / ignored 暂不支持的事件（保留原文）/ failed 映射或入库失败。
 */
export const upstreamEvents = pgTable(
  'upstream_events',
  {
    id: id(),
    queueId: text('queue_id')
      .notNull()
      .references(() => upstreamQueues.queueId, { onDelete: 'cascade' }),
    cursor: ref('cursor').notNull(),
    qqAccountId: ref('qq_account_id')
      .notNull()
      .references(() => qqAccounts.id, { onDelete: 'cascade' }),
    kind: text('kind').notNull(),
    payload: jsonb('payload').notNull(),
    /** 插件把事件放进队列的时间。 */
    enqueuedAt: ts('enqueued_at'),
    receivedAt: ts('received_at').notNull().defaultNow(),
    state: text('state').notNull().default('pending'),
    error: text('error'),
    processedAt: ts('processed_at'),
  },
  (t) => [
    unique('upstream_events_cursor_unique').on(t.queueId, t.cursor),
    index('upstream_events_pending_idx')
      .on(t.qqAccountId, t.id)
      .where(sql`${t.state} = 'pending'`),
    index('upstream_events_processed_idx').on(t.processedAt),
    check('upstream_events_state_check', sql`${t.state} in ('pending', 'done', 'ignored', 'failed')`),
  ],
);

/** 断点续传上传（tus 核心协议）。同一账号同一内容只有一个进行中的上传，App 重启后也能接着传。 */
export const uploads = pgTable(
  'uploads',
  {
    id: text('id').primaryKey(),
    accountId: ref('account_id')
      .notNull()
      .references(() => accounts.id, { onDelete: 'cascade' }),
    sha256: text('sha256').notNull(),
    size: ref('size').notNull(),
    mime: text('mime'),
    name: text('name'),
    /** 已收到的字节数。 */
    offset: ref('offset').notNull().default(0),
    createdAt: ts('created_at').notNull().defaultNow(),
    updatedAt: ts('updated_at').notNull().defaultNow(),
  },
  (t) => [unique('uploads_account_sha256_unique').on(t.accountId, t.sha256)],
);

/** 通话（docs/design.md 4.4、5.4）：每通来电一行，按通话桥分配的 call_id 去重。 */
export const calls = pgTable(
  'calls',
  {
    id: id(),
    qqAccountId: ref('qq_account_id')
      .notNull()
      .references(() => qqAccounts.id, { onDelete: 'cascade' }),
    callId: text('call_id').notNull().unique(),
    incoming: boolean('incoming').notNull().default(true),
    media: text('media').notNull().default('voice'),
    peerUin: ref('peer_uin'),
    peerName: text('peer_name'),
    phase: text('phase').notNull(),
    inviteAt: ts('invite_at').notNull(),
    acceptedAt: ts('accepted_at'),
    connectedAt: ts('connected_at'),
    endedAt: ts('ended_at'),
    /** QQ 内核给的结束原因（原样）。 */
    endReason: integer('end_reason'),
    /** 经本系统接听的设备。 */
    answeredDeviceId: ref('answered_device_id'),
    /** LiveKit 房间名。 */
    room: text('room'),
    updatedAt: ts('updated_at').notNull().defaultNow(),
  },
  (t) => [
    index('calls_account_invite_idx').on(t.qqAccountId, t.inviteAt),
    check('calls_phase_check', sql`${t.phase} in ('ringing', 'accepting', 'accepted', 'connected', 'ended')`),
  ],
);

/** 合并转发的内容（GetForward 第一次打开时向 QQ 拉取并缓存）。path：嵌套展开的节点下标，最外层为空串。 */
export const forwardBundles = pgTable(
  'forward_bundles',
  {
    id: id(),
    chatId: ref('chat_id')
      .notNull()
      .references(() => chats.id, { onDelete: 'cascade' }),
    messageSeq: ref('message_seq').notNull(),
    path: text('path').notNull().default(''),
    /** ready = 已拉到；unavailable = QQ 那边已经拉不到。 */
    state: text('state').notNull(),
    /** [{ senderId, senderName, time, msgId, segments }]；节点里的媒体登记在 media_refs（forward_bundle_id = id）。 */
    nodes: jsonb('nodes').notNull().default([]),
    fetchedAt: ts('fetched_at').notNull().defaultNow(),
  },
  (t) => [unique('forward_bundles_unique').on(t.chatId, t.messageSeq, t.path), check('forward_bundles_state_check', sql`${t.state} in ('ready', 'unavailable')`)],
);

/** 群成员（ContactService；定期和打开群资料时从 QQ 刷新）。 */
export const groupMembers = pgTable(
  'group_members',
  {
    qqAccountId: ref('qq_account_id')
      .notNull()
      .references(() => qqAccounts.id, { onDelete: 'cascade' }),
    groupId: ref('group_id').notNull(),
    userId: ref('user_id').notNull(),
    nickname: text('nickname'),
    card: text('card'),
    /** owner / admin / member。 */
    role: text('role').notNull().default('member'),
    title: text('title'),
    level: text('level'),
    joinedAt: ts('joined_at'),
    lastSentAt: ts('last_sent_at'),
    /** QQ 机器人。 */
    isRobot: boolean('is_robot').notNull().default(false),
    updatedAt: ts('updated_at').notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.qqAccountId, t.groupId, t.userId] })],
);
