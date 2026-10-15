# 语音转文字缓存与恢复复验 · 2026-10-15

## 修复

原实现收起文字时删除状态并重写缓存，重新展开又请求 QQ。本轮从 VoiceExtras 中拆出共享 VoiceTranscripts 模型，保留现有服务协议，将显示状态、已识别文本和请求任务分开。收起后直接从缓存恢复文字；已缓存空结果同样不重复识别，沿用原有语义。

隐藏偏好另行保存，重启后仍保持收起。隐藏持久记录只保存磁盘缓存中仍存在的 key，与原有 500 条缓存上限保持一致；缓存淘汰仍沿用旧实现按 key 排序的规则，本轮没有改成时间 LRU。没有缓存的临时隐藏只在进程内有效。

在途请求按消息 key 和请求 UUID 归属；隐藏时取消并移除请求，旧成功/失败均不可覆盖新请求或写入磁盘。失败不会因滚动/重新出现而自动循环；按钮提供“重试转文字”辅助功能名称，识别中禁用重复点击。断网/超时显示中文提示。

## 验证

七项 VoiceTranscriptsTests 与十二项 AiVoiceTests 共 19 项通过：`/tmp/betterchat-voice-final19-tests.log`。测试运行正式源码，使用 continuation 服务、独立 UserDefaults suite，无账号和网络。覆盖新缓存路径、旧格式、空结果、重复/取消/迟到请求及超过 500 个隐藏 key 的持久化边界。

实机受控页使用生产模型与 VoiceTranscriptView，内存服务首次模拟失败、重试返回短文。收起/恢复时请求计数保持 2，没有再请求。长文完整换行、深浅色均可见。截图位于 `/tmp/betterchat-ui-review/`：`transcript-failed-friendly-light.png`、`transcript-cached-reopen.png`、`transcript-long-dark.png`、`transcript-long-light.png`。页面外框和样本切换器属于临时验收壳，不是新增产品入口。

临时内存验收页面与菜单已移除；没有向任何会话发送语音。构建、签名的最终结果见本页后续记录。

## 联合评审与边界

Claude Code Opus 5.5（auto 模式）只读复核指出重启丢失隐藏状态、独立裁剪隐藏 key 的边界，均已修复并加测试。报告：`/tmp/betterchat-opus-transcripts-plan.jsonl`、`/tmp/betterchat-opus-transcripts-final.jsonl`；实机操作与测试由 Codex 执行。

当前缓存沿用同一服务器/账号的 chatId:seq 键，切换服务器/账号的命名空间隔离仍是既有边界。真实 QQ 识别的一个现有短语音样本随后通过，见下段。声音、麦克风、完整语言/时长矩阵及网络整体断开仍未测试；单元测试与内存 UI 不替代这些验收。


## 正式构建与真实识别

最终 Mac 构建 `/tmp/betterchat-voice-clean-build.log`、iOS 构建 `/tmp/betterchat-voice-final-ios.log` 均成功；严格签名与差异检查通过，Package.resolved 未变。临时源文件与菜单已删除。

在 Something 的已有 2026-10-13 16:57 一秒语音点击正式“转文字”按钮，真实服务返回“嗯。”；加载期间按钮禁用，完成后文字显示。收起后重启到最终构建，该语音仍保持收起，重新展开能立即恢复“嗯。”。截图 `transcript-real-success.png`、`transcript-real-restart-cache.png`。UI 检查没有做请求计数抓包；无重复网络请求的保证另由正式模型测试和缓存命中分支佐证，不以截图单独证明。

识别结果已收起，窗口恢复 1024×640、跟随系统、Something 最新消息和空输入；没有发送消息，也未播放录音。Opus 最终只读代码/截图复核无阻碍本轮交付的问题（`/tmp/betterchat-opus-voice-final-ui.jsonl`）。
