# 教训（lessons）

**规则：同一类错误犯了三次，就写进这里**（写清楚：现象、原因、以后怎么做、出现过的地方）。犯了一两次的先记在「观察中」，凑满三次再升级成正式条目。写代码前先看一遍；评审时按这里检查。

## L1 · Swift 6 严格并发：跨隔离传非 Sendable 的对象

- **现象**：`sending 'x' risks causing data races`、`passing closure as a 'sending' parameter`；`AsyncStream` 的迭代器跨 actor 调 `next()` 报错。
- **出现过**：MediaReady 的等待器、CallKitBridge（CXAction、PushKit 的 completion）、通知扩展（contentHandler）。
- **怎么做**：
  - 系统回调（`nonisolated` 的 delegate 方法）里**先取出 Sendable 的值**（UUID、Bool、字符串、自定义的 `Sendable` 结构体），再进 `MainActor.assumeIsolated` / `Task`。
  - 系统对象确实只在一处用、没有并发访问时，用 `nonisolated(unsafe) let x = x` 并写一行注释说明为什么安全。
  - 需要「等一个事件」时，写 `@MainActor final class` + 缓冲 + `CheckedContinuation`（见 `App/MediaReady.swift`），不要把 `AsyncStream.Iterator` 传来传去。

## L2 · 没核实就按字段名猜 QQ / NapCat 的语义

- **现象**：把字段当成它名字看起来的意思去处理，结果整条功能错掉。
- **出现过**：
  1. 通话引擎输出 20050 当成「要求重登」→ 2 分钟重登 775 次（其实是引擎日志）。
  2. 「某某邀请某某进群」的群名片当成 NapCat 误报 → 过滤掉了真名片，又撤回（是成员自己设的）。
  3. `onS2CActionToAVSDK` 的 `destroyReason` 是数字就当成通话结束 → 打出去的电话对方一接就断（`destroyReason 0` + 动作 10 是房间状态）。
  4. 群文件 `file_id` 当成稳定的 id 记下载记录 → 每次列出都不一样，下载过的认不出来。
- **怎么做**：
  - 新字段、新事件**先抓原始数据**（插件的 capture 目录、`/v1/debug/raw`、`/v1/debug/rpc`），对照至少两次真实场景（例如正常结束 vs 对方接听）再写判断。
  - 判断条件写成白名单（明确等于某值才处理），并在注释里写「哪天、哪个场景抓到的」。
  - 需要用户配合（打电话、发群语音）时直接请用户配合抓一次，不要靠猜。

## L3 · 模拟器里按列表位置点会话，点错

- **现象**：会话列表一直在变（新消息把会话顶上来），按截图上的坐标点下去打开的是别的会话；横幅被新通知替换。
- **出现过**：测超级表情、测语音转文字、测 @ 布局时都点错过。
- **怎么做**：
  - 用启动参数 `-debugJump <chatId>:<seq>` 打开后跳到指定消息；会话不在可见区时用置顶的会话（Something、DMA 群、中国人能飞）或模拟推送（`xcrun simctl push booted com.xiaomouz.betterchat <json>`，json 里带 `chatId`）。
  - 截图坐标是像素，点击用点：除以 3（1206×2622 → 402×874）。
  - 每次点完先截图确认在对的页面再继续。

## L4 · SwiftUI 尺寸：子视图的理想尺寸撑大 / 截断了外层

- **现象**：气泡、界面被撑宽，或者文字被截成省略号。
- **出现过**：
  1. 语音波形 `frame(maxWidth: .infinity)` 在没有固定宽度的 HStack 里把气泡撑满。
  2. 通话界面背景放了 600pt 的头像在 ZStack 里，整个界面被撑宽、按钮跑出屏幕。
  3. 语音识别结果 `fixedSize(horizontal: true)` + `frame(maxWidth: 260)` → 超过一行被截断。
- **怎么做**：
  - 装饰性的大背景放 `.background { }`，不放进参与排版的 ZStack。
  - 要「最多 N 宽、短的按内容宽、长的换行」：用 `CappedWidth`（`App/VoiceExtras.swift` 的 Layout），不要用 `frame(maxWidth:)`（它会撑满到 N）或 `fixedSize(horizontal:)`（不换行）。
  - 给明确的宽度（`frame(width:)`）而不是 `.infinity`，除非外层确实要撑满。
  - 改完在模拟器里看长、短两种内容。

## 观察中（犯过一两次）

- **热重载留下的状态**：插件重载后内核监听叠加（`15fa774`）、上游队列卡死（`34f6758`）。改插件的长期状态（监听、定时器、队列）时，按「重载很多次」考虑，状态挂在 `globalThis` 的 Symbol 上。
- **轮询代替推送**：用户两次指出「应该是订阅式的」。等服务端结果优先用 Subscribe 的临时事件或本地库的观察（`observeMessage`），轮询只做兜底。
- **系统代理**：本机 `HTTPS_PROXY` 让 curl、模拟器连不上 Tailscale 地址。本机调试用 `--noproxy '*'`，服务端给本机来的客户端返回本机地址。
- **修饰链太长编译器推断超时**：ChatScreen 的 body。新 sheet / 浮层写成单独的 `ViewModifier`。
- **新 Swift 文件不在工程里**：XcodeGen 生成的工程，加文件后要 `xcodegen generate`。
- **一直停在中间状态的记录**：通话停在「响铃」永不结束。有状态机的记录要有超时收尾、新的进来时收掉旧的。
