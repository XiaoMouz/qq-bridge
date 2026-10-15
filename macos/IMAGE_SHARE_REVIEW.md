# 图片系统分享复验（2026-10-15）

用户解锁后系统分享可正常展开。实测旧版将无扩展名的缓存 SHA 直接分享，系统“拷贝”后粘贴回聊天变成普通文件。Mac 现通过独立 Transferable 创建保留原字节的 `sha.ext` 临时副本；不修改媒体缓存或 Downloads，iOS 分享分支不变。

Opus 5.5 实现导出及测试，Codex 从 Something 的真实图片独立窗口验收：

1. 分享面板识别为 **JPEG Image · 10 KB**，显示“添加到照片”等图片操作。
2. 点“拷贝”后恢复原图片；方向键翻到下一张成功。
3. 关闭图片回聊天，⌘V 出现“第 1 个附件：图片”及缩略图。已移除附件，没有发送。

截图：`/tmp/betterchat-ui-review/image-share-named.png`、`image-share-copy-fixed.png`；旧行为对照 `image-share-copy-before.png`。

`MacImageShareTests` 五项通过，和登录五项合计十项：`/tmp/betterchat-login-share-tests.log`。覆盖 JPEG 扩展名、原字节和缓存不变、GIF、真实 Transferable 导出、目录/符号链接/无效 SHA 拒绝及失败清理。未通过 AirDrop、Mail 或 Messages 对外发送文件，不声明这些目的地已经验收。

最终构建：Mac `/tmp/betterchat-drop-diagnostics-final-build.log`、iOS `/tmp/betterchat-login-share-final-ios-build.log` 均成功，Mac 严格签名及差异检查通过。Package.resolved 无变化。Mac 包含正在等待真实拖放证据的 DEBUG 插桩，详见 [拖放诊断](FILE_DROP_REVIEW.md)。
