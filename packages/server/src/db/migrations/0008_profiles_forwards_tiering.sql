CREATE TABLE "forward_bundles" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"chat_id" bigint NOT NULL,
	"message_seq" bigint NOT NULL,
	"path" text DEFAULT '' NOT NULL,
	"state" text NOT NULL,
	"nodes" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"fetched_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "forward_bundles_unique" UNIQUE("chat_id","message_seq","path"),
	CONSTRAINT "forward_bundles_state_check" CHECK ("forward_bundles"."state" in ('ready', 'unavailable'))
);
--> statement-breakpoint
CREATE TABLE "group_members" (
	"qq_account_id" bigint NOT NULL,
	"group_id" bigint NOT NULL,
	"user_id" bigint NOT NULL,
	"nickname" text,
	"card" text,
	"role" text DEFAULT 'member' NOT NULL,
	"title" text,
	"level" text,
	"joined_at" timestamp with time zone,
	"last_sent_at" timestamp with time zone,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "group_members_qq_account_id_group_id_user_id_pk" PRIMARY KEY("qq_account_id","group_id","user_id")
);
--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "deep_archive_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "peers" ADD COLUMN "sign" text;--> statement-breakpoint
ALTER TABLE "peers" ADD COLUMN "extra" jsonb DEFAULT '{}'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "peers" ADD COLUMN "profile_refreshed_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "storage_policies" ADD COLUMN "cold_min_bytes" bigint;--> statement-breakpoint
ALTER TABLE "storage_policies" ADD COLUMN "hot_quota_bytes" bigint;--> statement-breakpoint
ALTER TABLE "forward_bundles" ADD CONSTRAINT "forward_bundles_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "group_members" ADD CONSTRAINT "group_members_qq_account_id_qq_accounts_id_fk" FOREIGN KEY ("qq_account_id") REFERENCES "public"."qq_accounts"("id") ON DELETE cascade ON UPDATE no action;