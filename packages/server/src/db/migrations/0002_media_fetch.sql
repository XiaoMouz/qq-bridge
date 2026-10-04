DROP INDEX "media_refs_pending_idx";--> statement-breakpoint
ALTER TABLE "blobs" ADD COLUMN "thumbhash" text;--> statement-breakpoint
ALTER TABLE "media_refs" ADD COLUMN "next_attempt_at" timestamp with time zone;--> statement-breakpoint
CREATE INDEX "media_refs_pending_idx" ON "media_refs" USING btree ("fetch_state","next_attempt_at") WHERE "media_refs"."fetch_state" in ('pending', 'failed', 'fetching');