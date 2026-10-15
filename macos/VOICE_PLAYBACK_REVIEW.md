# 语音播放器与鼠标拖动复验 · 2026-10-15

## 本轮变更

VoicePlayer 从 ChatModels 拆出，媒体来源通过协议适配已有 Session。播放、停止后重开同一媒体、媒体下载、播放器事件和 seek 各按操作代次隔离；停止取消加载、定时任务、观察和播放器 item。加载阶段设置 30 秒上限，错误归属到发起播放的那条消息，失败后通过原按钮重试。缓存副本写入失败会退回签名流地址，不再播放不存在的临时路径。

播放身份使用会话 ID、消息 seq 与 block 序号，sha 只定位文件。同一语音在不同消息重复出现时只激活当前气泡；波形范围只接受当前消息报告，并在视图离开时清除。弱引用当前播放者实现不同 ChatScreen 之间互斥，避免主会话与快速回复重叠播放。

Mac 使用标准播放/停止按钮，提供加载状态和失败文字；鼠标在当前波形范围内起拖不再依赖起步速度。加载时不启动拖动，取消手势回到当前播放进度、不执行 seek。iOS 保留原来的横向手势判断。

本机通话使用音频时不允许新播放/录音，并停止已播放的语音；开始录音前停止当前语音。播放器收到系统音频中断通知后停止，不自动恢复。没有主动全局 deactivate 音频会话，以免与通话或其他播放器争夺音频配置；音频路由和其他 App 声音恢复仍待硬件验收。

## 验证范围

首轮九项生命周期检查通过（`/tmp/betterchat-voice-player-tests.log`）。最终十六项通过（`/tmp/betterchat-voice-player-final16-tests.log`），增加消息身份、不同页面播放互斥、中断、错误观察、流式卡顿保留、临时副本重建与录音授权占用检查。单元检查使用真实 AVPlayer / AVPlayerItem、空 composition 或不存在的本地文件，禁用音频配置和播放；系统事件由测试注入，不代表真实来电或声音测试。seek 迟到回调检查给 MainActor 事件循环 20ms 处理时间，不用它证明所有设备调度时序。

临时界面使用生产 ChatCollectionView、MessageRow、VoicePlayer 与本地生成的 60 秒 PCM WAV；播放器静音，Session 只连不可达本机端口，使用临时库和隔离转写设置，不恢复真实令牌，不发送消息。验收完成后删除临时页面和菜单，最终构建另记。

Opus 5.5（auto 模式）只读复核提出消息身份、录音/通话冲突和拖动入口的补充意见；代码与实机检查由 Codex 执行。原评审 `/tmp/betterchat-opus-voice-player-plan.jsonl`。最终验证结果另记。


## 联合复核后的恢复修正

流式回退的 PlaybackStalled 只表示暂时等待缓冲，不再当作致命错误；真正失败由 AVPlayerItem.status / FailedToPlayToEndTime 收尾。临时音频副本先写 staging 再移动，已存在但大小不符的半文件会重建。录音器通过弱引用当前实例记录授权等待与录音占用，取消/拒绝/结束时释放；播放入口与实际音频配置均检查录音占用。已有 VoiceRecordingStartCheck 独立授权/取消检查通过，未访问麦克风。

实机发现错误查询先短路未观察 failure，导致按钮变化但错误文字不刷新；已改成先读取可观察错误状态，并补 ObservationTracking 回归。Mac 拖动手势额外记录开始时的播放代次，旧手势不控制后开始的另一条语音。

## 实机过程

本地静音素材正常解码播放；生产消息列表中鼠标向前拖动由约 11% 到 76%，向后拖回约 14%，松手后继续推进。点击同文件的第二条消息后，第一条恢复未播放，第二条单独激活。模拟失败后仅对应气泡显示“语音加载失败，请重试”，关闭失败开关后重试恢复，深浅色错误均可见。截图 `voice-seek-backward.png`、`voice-duplicate-media-selection.png`、`voice-error-final-dark.png`、`voice-error-final-light.png` 位于 `/tmp/betterchat-ui-review/`。

没有听取实际声音，未测试真实网络缓冲/恢复与通话硬件；静音解码、鼠标交互和注入中断不等同这些路径已通过。


最终受控重试后经过 42 秒仍在正常播放（约 68%，`voice-playing-past-load-timeout.png`），证明该次已就绪播放没有被 30 秒加载上限误停。此证据是一次本地文件实测，不能推及所有流式网络时序。

## 最终收尾

本地 60 秒静音素材自然结束后，两条气泡均恢复“播放语音”，状态归零，见 `voice-natural-completion.png`。临时验收页面及菜单已删除并重新生成工程。

Opus 最终代码复核指出 AI 试听与聊天语音可重叠；已为两个播放器添加双向停止，包含下载未结束时切换，新增回归通过。Opus 该次没有打开截图，其余 UI 证据由 Codex 实测。最终 17 项播放测试加 12 项 AI 语音测试共 29 项通过（`/tmp/betterchat-voice-player-clean-tests.log`）；iOS 构建通过（`/tmp/betterchat-voice-player-clean-ios.log`）。Mac 测试构建、严格签名、差异检查通过，Package.resolved 未变化。

清理后的普通应用已重新启动。实际声音、系统音频会话归还、实网缓冲和通话硬件仍未验收，不将模拟通知或静音解码记为硬件通过。
