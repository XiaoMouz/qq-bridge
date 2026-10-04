CREATE TABLE "calls" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"qq_account_id" bigint NOT NULL,
	"call_id" text NOT NULL,
	"incoming" boolean DEFAULT true NOT NULL,
	"media" text DEFAULT 'voice' NOT NULL,
	"peer_uin" bigint,
	"peer_name" text,
	"phase" text NOT NULL,
	"invite_at" timestamp with time zone NOT NULL,
	"accepted_at" timestamp with time zone,
	"connected_at" timestamp with time zone,
	"ended_at" timestamp with time zone,
	"end_reason" integer,
	"answered_device_id" bigint,
	"room" text,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "calls_call_id_unique" UNIQUE("call_id"),
	CONSTRAINT "calls_phase_check" CHECK ("calls"."phase" in ('ringing', 'accepting', 'accepted', 'connected', 'ended'))
);
--> statement-breakpoint
ALTER TABLE "calls" ADD CONSTRAINT "calls_qq_account_id_qq_accounts_id_fk" FOREIGN KEY ("qq_account_id") REFERENCES "public"."qq_accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "calls_account_invite_idx" ON "calls" USING btree ("qq_account_id","invite_at");