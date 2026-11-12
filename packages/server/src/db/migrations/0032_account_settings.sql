-- 账号级设置（AuthService.SetAccountSettings）：所有设备共享，存在服务端。
-- settings_pts：最后一次改动时分配的全局 pts，差量里据此带上设置；0 = 没改过（默认值）。
ALTER TABLE "accounts" ADD COLUMN IF NOT EXISTS "phone_notifications_off" boolean NOT NULL DEFAULT false;
ALTER TABLE "accounts" ADD COLUMN IF NOT EXISTS "settings_pts" bigint NOT NULL DEFAULT 0;
