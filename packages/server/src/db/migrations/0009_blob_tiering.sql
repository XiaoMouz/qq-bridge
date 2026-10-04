ALTER TABLE "blobs" ADD COLUMN "cold_since" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "blobs" ADD COLUMN "access_count" integer DEFAULT 0 NOT NULL;