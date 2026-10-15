# AI 语音恢复与桌面交互 · 2026-10-15

## 本轮改动

AI 语音从 VoiceExtras 的视图内状态拆为共享 `AiVoiceViewModel`、`AiVoicePreview` 和 `AiVoiceSheet`；协议适配仍调用 iOS 已有 ListAiVoices/SendAiVoice。分类变化同步选择当前可见角色，空分类禁止发送；加载失败可重试，不覆盖编辑过的文本，旧加载结果隔离。刷新按分类名和角色 ID 保留有效选择。

Mac 用标准分类菜单和 TextEditor，普通 Return 换行，⌘Return 才提交。发送前停止试听，发送中固定按钮位置、禁用输入/分类/取消/交互关闭，防重复触发。同一个模型暂时离开只停加载和 UI 回调，已有发送保持进行中；成功保留完成文本并禁止再次提交，该模型恢复后只交付一次完成回调。真正销毁表单后重建模型不具备跨实例防重能力。超时不自动重发，并提示先检查会话记录。关闭不能撤销已经交给 QQ 的请求。

试听观察具体 AVPlayerItem 的结束、失败、卡顿通知和 status 失败；旧回调按 generation 隔离，关闭时暂停、释放 item 并移除观察。切换分类停止试听，通话接听/连接/本机通话期间禁用并停止试听。此项没有改动通话引擎或系统路由。

## 初步证据

最初九项通过后，已增加到十二项模型和 AVPlayer 专项检查：`/tmp/betterchat-ai-voice-final12-tests.log`。检查不访问真实账号；大部分 AVPlayer 检查使用空 composition、不启动播放、注入空音频配置，通知由测试明确触发。另有不存在的本地媒体文件触发真实 AVPlayer status 失败的检查，覆盖初始加载失败 KVO。均不是实际音频解码/音量验收。

受控 UI 使用生产 AiVoiceSheet 与内存服务，首次模拟超时后改草稿、重试成功，输入保留；普通回车只换行，在角色可发送状态也不会提交；空分类禁用发送；切特色角色后 ⌘Return 的模拟请求为角色 b，文本保持多行；发送中 Esc 不关闭，完成模拟请求后返回聊天。没有向群发 AI 语音。

截图初步位于 `/tmp/betterchat-ui-review/ai-voice-empty-category.png`、`ai-voice-sending-blocks-escape.png`。早期发送截图揭示 Catalyst 未刷新工具栏 label；加按钮 identity 后实际复验仍显示灰色“发送”，已证实无效（`ai-voice-toolbar-stale.png`）。随后改成发送时以独立 ProgressView 替换按钮，最终截图另记。

## 验收边界

真实 AI 语音发送仍未执行；硬件声音、其它 App 音乐恢复、通话中音频路由及整个网络断开需后续实测。不主动全局 deactivate 音频会话，以免影响通话或其它播放器；不能将暂停/释放本页播放器宣称为系统音频路由已验收。SendAiVoice 协议没有幂等键；本页防连点和不自动重发不等于服务端具有幂等保证。

Opus 5.5 参与只读代码复核，报告在 `/tmp/betterchat-opus-ai-voice-plan.jsonl`、`/tmp/betterchat-opus-ai-voice-review.jsonl`、`/tmp/betterchat-opus-ai-voice-final.jsonl`；测试和实机交互由主 agent 执行。


## 最终桌面反馈复验

发送按钮改为忙碌时直接替换成独立 ProgressView；实测默认 tint 在浅色模式几乎不可见，最终改为 primary tint 和 regular 尺寸。1024×640 与 440×480 父窗口下的表单、深浅外观已检查；发送中进度圈可见、辅助功能名称为“正在发送”、输入/取消禁用、Esc 保持页面，完成内存请求后正常关闭。最终截图 `ai-voice-progress-final-light.png`、`ai-voice-progress-final-dark.png`。这些只证明模拟请求下的 UI 状态，不证明 QQ 发送完成。

十二项 AI 语音与七项转文字检查合计 19 项通过（`/tmp/betterchat-voice-final19-tests.log`）。临时验收页面和菜单已删除，最终开发构建不带测试入口。

最终 Mac / iOS 构建分别为 `/tmp/betterchat-voice-clean-build.log`、`/tmp/betterchat-voice-final-ios.log`，均通过；签名、差异检查通过，依赖锁文件未变。Opus 最终只读复核深浅色进度和转文字截图无阻碍项，报告 `/tmp/betterchat-opus-voice-final-ui.jsonl`。
