-- QQ 的好友分组（刷新好友列表时从 QQ 同步）。好友属于哪个分组记在 peers.extra（categoryId、specialCare）。
CREATE TABLE "friend_categories" (
  "qq_account_id" bigint NOT NULL REFERENCES "qq_accounts"("id") ON DELETE CASCADE,
  "category_id" integer NOT NULL,
  "name" text NOT NULL,
  "sort" integer NOT NULL DEFAULT 0,
  PRIMARY KEY ("qq_account_id", "category_id")
);
