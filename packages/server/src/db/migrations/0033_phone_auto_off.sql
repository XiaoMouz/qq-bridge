-- 「本机在线时自动停用通知到手机」：服务端根据设备的在线租约算出来的状态（push/phone-auto-mute.ts），
-- 存在库里是为了和手动开关一起经 settings_pts 进差量；服务端启动时清零（租约在内存里，重启后由设备重新报到）。
ALTER TABLE "accounts" ADD COLUMN IF NOT EXISTS "phone_auto_off" boolean NOT NULL DEFAULT false;
