-- 在 App 里看过的 @我 / 回复我 / @全体成员：不再算进会话的未读 @ 数，也不再出现在"有人@我"里（已读位置不动）。
ALTER TABLE "messages" ADD COLUMN "mention_seen" boolean DEFAULT false NOT NULL;
