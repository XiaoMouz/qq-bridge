-- 客户端主动要的媒体（点开看、显示到时要缩略图）：记下时间，下载时不受自动下载的大小上限限制。
ALTER TABLE "media_refs" ADD COLUMN "requested_at" timestamp with time zone;
