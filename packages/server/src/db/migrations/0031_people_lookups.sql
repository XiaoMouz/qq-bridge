-- 灰条、合并转发里只有号码的人：向 QQ 要过资料的记录（contacts/people.ts）。
-- 要到了的存进 peers；要不到的（注销、QQ 不给）记下时间，过一阵再试，不每次都去要。
CREATE TABLE IF NOT EXISTS "people_lookups" (
  "qq_account_id" bigint NOT NULL REFERENCES "qq_accounts"("id") ON DELETE CASCADE,
  "user_id" bigint NOT NULL,
  "tried_at" timestamp with time zone NOT NULL DEFAULT now(),
  "found" boolean NOT NULL,
  PRIMARY KEY ("qq_account_id", "user_id")
);
