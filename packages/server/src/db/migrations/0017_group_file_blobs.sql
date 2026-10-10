-- 下载过的群文件：群里的 file_id → 服务端里的内容（下过一次就不再下）。
CREATE TABLE "group_file_blobs" (
  "qq_account_id" bigint NOT NULL REFERENCES "qq_accounts"("id") ON DELETE CASCADE,
  "group_id" bigint NOT NULL,
  "file_id" text NOT NULL,
  "sha256" text NOT NULL REFERENCES "blobs"("sha256"),
  "name" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  PRIMARY KEY ("qq_account_id", "group_id", "file_id")
);
--> statement-breakpoint
CREATE INDEX "group_file_blobs_sha256_idx" ON "group_file_blobs" ("sha256");
