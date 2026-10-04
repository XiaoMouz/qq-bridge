CREATE TABLE "upstream_events" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"queue_id" text NOT NULL,
	"cursor" bigint NOT NULL,
	"qq_account_id" bigint NOT NULL,
	"kind" text NOT NULL,
	"payload" jsonb NOT NULL,
	"enqueued_at" timestamp with time zone,
	"received_at" timestamp with time zone DEFAULT now() NOT NULL,
	"state" text DEFAULT 'pending' NOT NULL,
	"error" text,
	"processed_at" timestamp with time zone,
	CONSTRAINT "upstream_events_cursor_unique" UNIQUE("queue_id","cursor"),
	CONSTRAINT "upstream_events_state_check" CHECK ("upstream_events"."state" in ('pending', 'done', 'ignored', 'failed'))
);
--> statement-breakpoint
CREATE TABLE "upstream_queues" (
	"queue_id" text PRIMARY KEY NOT NULL,
	"qq_account_id" bigint NOT NULL,
	"last_cursor" bigint DEFAULT 0 NOT NULL,
	"first_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_seen_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "media_refs" ADD COLUMN "locator" jsonb;--> statement-breakpoint
ALTER TABLE "upstream_events" ADD CONSTRAINT "upstream_events_queue_id_upstream_queues_queue_id_fk" FOREIGN KEY ("queue_id") REFERENCES "public"."upstream_queues"("queue_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "upstream_events" ADD CONSTRAINT "upstream_events_qq_account_id_qq_accounts_id_fk" FOREIGN KEY ("qq_account_id") REFERENCES "public"."qq_accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "upstream_queues" ADD CONSTRAINT "upstream_queues_qq_account_id_qq_accounts_id_fk" FOREIGN KEY ("qq_account_id") REFERENCES "public"."qq_accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "upstream_events_pending_idx" ON "upstream_events" USING btree ("qq_account_id","id") WHERE "upstream_events"."state" = 'pending';--> statement-breakpoint
CREATE INDEX "upstream_events_processed_idx" ON "upstream_events" USING btree ("processed_at");