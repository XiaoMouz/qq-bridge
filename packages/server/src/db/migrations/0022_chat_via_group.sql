-- 从群成员资料卡发起的私聊（对方不是好友）：记下是哪个群，发送时带上它，QQ 会走群临时会话。
ALTER TABLE "chats" ADD COLUMN "via_group_id" bigint;
