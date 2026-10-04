CREATE TABLE "accounts" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"username" text NOT NULL,
	"password_hash" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "accounts_username_unique" UNIQUE("username")
);
--> statement-breakpoint
CREATE TABLE "blob_variants" (
	"sha256" text NOT NULL,
	"variant" text NOT NULL,
	"variant_sha256" text NOT NULL,
	CONSTRAINT "blob_variants_sha256_variant_pk" PRIMARY KEY("sha256","variant")
);
--> statement-breakpoint
CREATE TABLE "blobs" (
	"sha256" text PRIMARY KEY NOT NULL,
	"md5" text NOT NULL,
	"md5_head" text NOT NULL,
	"size" bigint NOT NULL,
	"mime" text,
	"kind" text,
	"width" integer,
	"height" integer,
	"duration_ms" integer,
	"tier" text DEFAULT 'hot' NOT NULL,
	"storage_key" text NOT NULL,
	"state" text DEFAULT 'present' NOT NULL,
	"ref_chats" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_access_at" timestamp with time zone,
	CONSTRAINT "blobs_state_check" CHECK ("blobs"."state" in ('present', 'purged'))
);
--> statement-breakpoint
CREATE TABLE "chat_blob_usage" (
	"chat_id" bigint NOT NULL,
	"sha256" text NOT NULL,
	"ref_count" integer NOT NULL,
	CONSTRAINT "chat_blob_usage_chat_id_sha256_pk" PRIMARY KEY("chat_id","sha256")
);
--> statement-breakpoint
CREATE TABLE "chat_storage" (
	"chat_id" bigint PRIMARY KEY NOT NULL,
	"logical_bytes" bigint DEFAULT 0 NOT NULL,
	"exclusive_bytes" bigint DEFAULT 0 NOT NULL,
	"blob_count" integer DEFAULT 0 NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "chats" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"qq_account_id" bigint NOT NULL,
	"scene" text NOT NULL,
	"peer_id" bigint NOT NULL,
	"top_seq" bigint,
	"top_time" timestamp with time zone,
	"unread_count" integer DEFAULT 0 NOT NULL,
	"unread_mentions" integer DEFAULT 0 NOT NULL,
	"read_inbox_max_seq" bigint DEFAULT 0 NOT NULL,
	"pinned" boolean DEFAULT false NOT NULL,
	"notify_policy" text DEFAULT 'default' NOT NULL,
	"draft" jsonb,
	"chat_pts" bigint DEFAULT 0 NOT NULL,
	"dialog_pts" bigint NOT NULL,
	"verified_ranges" "int8multirange" DEFAULT '{}' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "chats_peer_unique" UNIQUE("qq_account_id","scene","peer_id"),
	CONSTRAINT "chats_scene_check" CHECK ("chats"."scene" in ('friend', 'group', 'temp'))
);
--> statement-breakpoint
CREATE TABLE "devices" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"account_id" bigint NOT NULL,
	"name" text NOT NULL,
	"platform" text NOT NULL,
	"token_hash" "bytea" NOT NULL,
	"apns_token" text,
	"apns_voip_token" text,
	"apns_env" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_seen_at" timestamp with time zone,
	"revoked_at" timestamp with time zone,
	CONSTRAINT "devices_token_hash_unique" UNIQUE("token_hash")
);
--> statement-breakpoint
CREATE TABLE "media_refs" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"chat_id" bigint NOT NULL,
	"message_seq" bigint,
	"ordinal" integer DEFAULT 0 NOT NULL,
	"forward_bundle_id" text,
	"node_path" integer[],
	"role" text NOT NULL,
	"kind" text NOT NULL,
	"sha256" text,
	"qq_md5" text,
	"qq_md5_partial" boolean DEFAULT false NOT NULL,
	"qq_file_uuid" text,
	"qq_resource_id" text,
	"qq_file_id" text,
	"url" text,
	"url_expires_at" timestamp with time zone,
	"size" bigint,
	"name" text,
	"mime" text,
	"fetch_state" text DEFAULT 'pending' NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"last_error" text,
	"thumbhash" text,
	"keep_original" boolean,
	"sender_uin" bigint,
	"time" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "messages" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"chat_id" bigint NOT NULL,
	"seq" bigint NOT NULL,
	"qq_msg_id" text,
	"random" bigint,
	"sender_uin" bigint NOT NULL,
	"time" timestamp with time zone NOT NULL,
	"kind" text DEFAULT 'normal' NOT NULL,
	"segments" jsonb NOT NULL,
	"text" text DEFAULT '' NOT NULL,
	"reply_to_seq" bigint,
	"flags" integer DEFAULT 0 NOT NULL,
	"state" text DEFAULT 'normal' NOT NULL,
	"recalled_by" bigint,
	"recalled_at" timestamp with time zone,
	"reactions" jsonb,
	"version" bigint NOT NULL,
	"source" text NOT NULL,
	"raw" jsonb,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "messages_chat_seq_unique" UNIQUE("chat_id","seq"),
	CONSTRAINT "messages_state_check" CHECK ("messages"."state" in ('normal', 'recalled')),
	CONSTRAINT "messages_kind_check" CHECK ("messages"."kind" in ('normal', 'service', 'call'))
);
--> statement-breakpoint
CREATE TABLE "outbox" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"account_id" bigint NOT NULL,
	"chat_id" bigint NOT NULL,
	"device_id" bigint,
	"client_random_id" bigint NOT NULL,
	"content" jsonb NOT NULL,
	"state" text DEFAULT 'pending' NOT NULL,
	"result_seq" bigint,
	"error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "outbox_random_unique" UNIQUE("account_id","client_random_id")
);
--> statement-breakpoint
CREATE TABLE "peers" (
	"qq_account_id" bigint NOT NULL,
	"kind" text NOT NULL,
	"peer_id" bigint NOT NULL,
	"uid" text,
	"name" text,
	"remark" text,
	"is_friend" boolean DEFAULT false NOT NULL,
	"member_count" integer,
	"avatar_sha256" text,
	"pts" bigint NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "peers_qq_account_id_kind_peer_id_pk" PRIMARY KEY("qq_account_id","kind","peer_id"),
	CONSTRAINT "peers_kind_check" CHECK ("peers"."kind" in ('user', 'group'))
);
--> statement-breakpoint
CREATE TABLE "qq_accounts" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"account_id" bigint NOT NULL,
	"uin" bigint NOT NULL,
	"uid" text,
	"nickname" text,
	"upstream_kind" text DEFAULT 'napcat' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "qq_accounts_uin_unique" UNIQUE("uin")
);
--> statement-breakpoint
CREATE TABLE "storage_policies" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"account_id" bigint NOT NULL,
	"scope" text NOT NULL,
	"scene" text,
	"chat_id" bigint,
	"keep_original_days" integer,
	"auto_fetch_max_bytes" bigint,
	"cold_after_days" integer,
	"recompress_after_days" integer,
	CONSTRAINT "storage_policies_scope_unique" UNIQUE NULLS NOT DISTINCT("account_id","scope","scene","chat_id"),
	CONSTRAINT "storage_policies_scope_check" CHECK ("storage_policies"."scope" in ('global', 'scene', 'chat'))
);
--> statement-breakpoint
CREATE TABLE "sync_state" (
	"account_id" bigint PRIMARY KEY NOT NULL,
	"pts" bigint DEFAULT 0 NOT NULL,
	"tombstone_horizon_pts" bigint DEFAULT 0 NOT NULL
);
--> statement-breakpoint
CREATE TABLE "tombstones" (
	"account_id" bigint NOT NULL,
	"pts" bigint NOT NULL,
	"entity" text NOT NULL,
	"entity_key" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "tombstones_account_id_pts_pk" PRIMARY KEY("account_id","pts")
);
--> statement-breakpoint
ALTER TABLE "blob_variants" ADD CONSTRAINT "blob_variants_sha256_blobs_sha256_fk" FOREIGN KEY ("sha256") REFERENCES "public"."blobs"("sha256") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "blob_variants" ADD CONSTRAINT "blob_variants_variant_sha256_blobs_sha256_fk" FOREIGN KEY ("variant_sha256") REFERENCES "public"."blobs"("sha256") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "chat_blob_usage" ADD CONSTRAINT "chat_blob_usage_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "chat_blob_usage" ADD CONSTRAINT "chat_blob_usage_sha256_blobs_sha256_fk" FOREIGN KEY ("sha256") REFERENCES "public"."blobs"("sha256") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "chat_storage" ADD CONSTRAINT "chat_storage_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "chats" ADD CONSTRAINT "chats_qq_account_id_qq_accounts_id_fk" FOREIGN KEY ("qq_account_id") REFERENCES "public"."qq_accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "devices" ADD CONSTRAINT "devices_account_id_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "media_refs" ADD CONSTRAINT "media_refs_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "media_refs" ADD CONSTRAINT "media_refs_sha256_blobs_sha256_fk" FOREIGN KEY ("sha256") REFERENCES "public"."blobs"("sha256") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "messages_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "outbox" ADD CONSTRAINT "outbox_account_id_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "outbox" ADD CONSTRAINT "outbox_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "outbox" ADD CONSTRAINT "outbox_device_id_devices_id_fk" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "peers" ADD CONSTRAINT "peers_qq_account_id_qq_accounts_id_fk" FOREIGN KEY ("qq_account_id") REFERENCES "public"."qq_accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "qq_accounts" ADD CONSTRAINT "qq_accounts_account_id_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "storage_policies" ADD CONSTRAINT "storage_policies_account_id_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "storage_policies" ADD CONSTRAINT "storage_policies_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "sync_state" ADD CONSTRAINT "sync_state_account_id_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tombstones" ADD CONSTRAINT "tombstones_account_id_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "blob_variants_variant_idx" ON "blob_variants" USING btree ("variant_sha256");--> statement-breakpoint
CREATE INDEX "blobs_md5_idx" ON "blobs" USING btree ("md5");--> statement-breakpoint
CREATE INDEX "blobs_md5_head_idx" ON "blobs" USING btree ("md5_head","size");--> statement-breakpoint
CREATE INDEX "chat_blob_usage_sha256_idx" ON "chat_blob_usage" USING btree ("sha256");--> statement-breakpoint
CREATE INDEX "chats_dialog_pts_idx" ON "chats" USING btree ("qq_account_id","dialog_pts");--> statement-breakpoint
CREATE INDEX "chats_top_time_idx" ON "chats" USING btree ("qq_account_id","top_time");--> statement-breakpoint
CREATE INDEX "devices_account_idx" ON "devices" USING btree ("account_id");--> statement-breakpoint
CREATE INDEX "media_refs_sha256_idx" ON "media_refs" USING btree ("sha256");--> statement-breakpoint
CREATE INDEX "media_refs_chat_kind_time_idx" ON "media_refs" USING btree ("chat_id","kind","time");--> statement-breakpoint
CREATE INDEX "media_refs_message_idx" ON "media_refs" USING btree ("chat_id","message_seq");--> statement-breakpoint
CREATE INDEX "media_refs_qq_md5_idx" ON "media_refs" USING btree ("qq_md5");--> statement-breakpoint
CREATE INDEX "media_refs_pending_idx" ON "media_refs" USING btree ("fetch_state") WHERE "media_refs"."fetch_state" in ('pending', 'failed');--> statement-breakpoint
CREATE INDEX "messages_version_idx" ON "messages" USING btree ("chat_id","version");--> statement-breakpoint
CREATE INDEX "messages_text_pgroonga_idx" ON "messages" USING pgroonga ("text");--> statement-breakpoint
CREATE INDEX "peers_pts_idx" ON "peers" USING btree ("qq_account_id","pts");