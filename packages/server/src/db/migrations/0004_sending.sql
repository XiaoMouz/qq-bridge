CREATE TABLE "uploads" (
	"id" text PRIMARY KEY NOT NULL,
	"account_id" bigint NOT NULL,
	"sha256" text NOT NULL,
	"size" bigint NOT NULL,
	"mime" text,
	"name" text,
	"offset" bigint DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "uploads_account_sha256_unique" UNIQUE("account_id","sha256")
);
--> statement-breakpoint
ALTER TABLE "outbox" ADD COLUMN "qq_msg_id" text;--> statement-breakpoint
ALTER TABLE "outbox" ADD COLUMN "attempts" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "outbox" ADD COLUMN "next_attempt_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "outbox" ADD COLUMN "pts" bigint NOT NULL;--> statement-breakpoint
ALTER TABLE "outbox" ADD COLUMN "updated_at" timestamp with time zone DEFAULT now() NOT NULL;--> statement-breakpoint
ALTER TABLE "uploads" ADD CONSTRAINT "uploads_account_id_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "outbox_pts_idx" ON "outbox" USING btree ("account_id","pts");--> statement-breakpoint
CREATE INDEX "outbox_queue_idx" ON "outbox" USING btree ("id") WHERE "outbox"."state" = 'pending';--> statement-breakpoint
ALTER TABLE "outbox" ADD CONSTRAINT "outbox_state_check" CHECK ("outbox"."state" in ('pending', 'sending', 'sent', 'failed'));