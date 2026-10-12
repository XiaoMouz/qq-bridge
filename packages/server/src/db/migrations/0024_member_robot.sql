-- 群成员是不是 QQ 机器人（官方机器人，消息带按钮 / markdown）。
ALTER TABLE "group_members" ADD COLUMN "is_robot" boolean DEFAULT false NOT NULL;
