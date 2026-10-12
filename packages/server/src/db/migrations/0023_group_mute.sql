-- 群的禁言状态（自己视角）：全员禁言、自己被禁言到什么时候、自己在群里的身份（群主 / 管理员全员禁言时仍能发言）。
ALTER TABLE "peers" ADD COLUMN "mute_all" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "peers" ADD COLUMN "self_muted_until" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "peers" ADD COLUMN "self_role" text;
