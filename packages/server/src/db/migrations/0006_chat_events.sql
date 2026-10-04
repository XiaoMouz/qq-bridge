CREATE TABLE "chat_events" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"chat_id" bigint NOT NULL,
	"kind" text NOT NULL,
	"time" timestamp with time zone NOT NULL,
	"actor_id" bigint,
	"target_id" bigint,
	"ref_seq" bigint,
	"data" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"version" bigint NOT NULL,
	"source_event_id" bigint,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "chat_events_source_event_id_unique" UNIQUE("source_event_id")
);
--> statement-breakpoint
ALTER TABLE "media_refs" ADD COLUMN "chat_event_id" bigint;--> statement-breakpoint
ALTER TABLE "chat_events" ADD CONSTRAINT "chat_events_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "chat_events_version_idx" ON "chat_events" USING btree ("chat_id","version");--> statement-breakpoint
CREATE INDEX "chat_events_time_idx" ON "chat_events" USING btree ("chat_id","time");--> statement-breakpoint
ALTER TABLE "media_refs" ADD CONSTRAINT "media_refs_chat_event_id_chat_events_id_fk" FOREIGN KEY ("chat_event_id") REFERENCES "public"."chat_events"("id") ON DELETE cascade ON UPDATE no action;