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
  - 停顿一会儿之后的第一次点击常被模拟器操作工具丢掉（2026-10-15 标签栏、搜索按钮、退出登录按钮都遇到过）：没变化就再点一次，不要据此认定 App 没反应；弹出确认框之类危险操作后不要靠「点空白处」关闭，直接结束 App。
  - Windows 客户端同理（2026-10-17）：会话列表按位置会变，UI 自动化的滚动对消息 ListView 不生效；用 `-debugJump chatId:seq` 打开指定消息，按 AutomationId / 名字找元素，不按坐标点。

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

## L5 · SwiftUI 大表达式与闭包类型推断失败

- **现象**：复杂 body 报类型推断超时，或 `failed to produce diagnostic for expression`，错误位置指向整个 body 而非新增参数。
- **出现过**：ChatScreen 的 body；2026-10-14 桌面导航 `.onChange`；2026-10-15 URLGalleryView 新增可选播放闭包，Mac 构建失败。
- **怎么做**：新 sheet / 浮层拆成 ViewModifier，监听与键盘配置拆为独立的 `some View` 属性。复杂可选闭包显式声明类型，不把函数引用三元表达式直接塞入长修饰链。第三次实际将键盘配置独立并标注 `(() -> Void)?` 后构建和三项 UIKit 测试通过。

## L6 · UIKit / Catalyst 窗口层级不能只凭源码猜测

- **现象**：静态评审推断资料卡无法呈现，真实 UIKit 测试和实际入口却通过。
- **出现过**：2026-10-14 假定子控制器看不到祖先呈现的资料卡；随后假定快速回复内 `anchor.view.window.rootViewController` 必然是主工作区根；2026-10-15 Opus 在通用表单提取评审中再次作同一假定，声称嵌套测试必失败，但当轮 `profileInsideQuickReplyPresentsAboveItsOwningSheet` 和 `unrelatedSheetDoesNotReceiveUnderlyingPageProfile` 都实际通过（`/tmp/betterchat-storage-references-native-tests.log`）。
- **原因**：把逻辑上的弹窗层级等同于 UIKit / Catalyst 实际窗口及根控制器层级，忽略系统呈现的独立窗口语义。
- **怎么做**：评审先读现有实际 UIKit 测试和结果；怀疑层级时在生产呈现器的窗口、转场与真实入口复现。推测只能记为疑点，不能标记确定缺陷或据此新增遍历 / 关闭其他弹窗的逻辑。与测试矛盾时先检查测试覆盖，不把“测试一定失败”的推断当证据。

## L7 · 弹窗必须从真实入口验证鼠标关闭

- **现象与出现处**：资料卡、存储引用页、群文件移动/转发页的内部 SwiftUI sheet 出现鼠标关闭后仍留在屏幕上；Esc 或直接 UIKit 临时宿主成功并未覆盖真实调用链。群文件移动页在 2026-10-15 单独改为状态绑定关闭仍未解决。
- **怎么做**：从最终正常构建的真实入口打开，分别验证鼠标关闭、Esc、重复打开、选择/草稿保留；关闭后确认原窗口内容恢复，不能只看到点击反馈。可注入服务验证数据与失败状态，不能替代真实呈现路径。已复现的内部表单复用 `MacFormPresenter`，保留显式关闭回调；没有复现的页面不凭同名 API 批量替换。

## 观察中（犯过一两次）

- **外接盘迁移时未实测就要求修改所有权（2026-10-19，1 次）**：仅凭 APFS 的 `Owners: Disabled` 判定迁移必须管理员授权，造成额外等待；隔离容器中的 PostgreSQL 初始化、读写和停库，以及生产数据库迁移后的查询均通过。以后先验证实际部署用户和存储操作，再决定是否需要修改系统设置，不能只凭卷属性下结论。
- **热重载留下的状态**：插件重载后内核监听叠加（`15fa774`）、上游队列卡死（`34f6758`）。改插件的长期状态（监听、定时器、队列）时，按「重载很多次」考虑，状态挂在 `globalThis` 的 Symbol 上。
- **轮询代替推送**：用户两次指出「应该是订阅式的」。等服务端结果优先用 Subscribe 的临时事件或本地库的观察（`observeMessage`），轮询只做兜底。
- **系统代理**：本机 `HTTPS_PROXY` 让 curl、模拟器连不上 Tailscale 地址。本机调试用 `--noproxy '*'`，服务端给本机来的客户端返回本机地址。
- **新 Swift 文件不在工程里**：XcodeGen 生成的工程，加文件后要 `xcodegen generate`。
- **一直停在中间状态的记录**：通话停在「响铃」永不结束。有状态机的记录要有超时收尾、新的进来时收掉旧的。

- **原生菜单点击后盲目补 Return（2026-10-14，1 次）**：Mac 部分菜单点击只高亮，另一些直接执行并关闭。尺寸菜单已关闭后补 Return，导致测试草稿误发到 Something，已撤回。每次先读取新 UI 状态，只有菜单仍打开且目标项已选中才能按 Return；输入框含草稿时尤其不能连发。

- **页面返回后只重订阅临时事件（2026-10-15，1 次）**：Mac 群精华取消订阅后，图片可能在页面离开期间完成；返回只订阅旧列表会永久错过不重放的 mediaReady。先对仍待完成的媒体补读一次快照，再登记事件并发布列表；用“离开期间完成、返回”场景验证，不能只测页面一直打开时的通知。

- **WinUI 内容「靠左、最宽 N」（2026-10-17，2 次）**：Windows 右栏给 StackPanel 设 MaxWidth + Stretch 会被居中，左边空一大块；改成 Left 又只按内容宽度排，SettingsCard 被挤窄、右侧数值掉到第二行。用星号列加 MaxWidth（`<ColumnDefinition Width="*" MaxWidth="800"/>`）。改完在宽窗口截图看一次。

- **代码里创建的 C# 子类控件（2026-10-17，1 次）**：`ClickableSettingsCard` 只在代码里 new、XAML 没引用，编译器不生成类型信息，运行时按 ButtonBase 套 SettingsCard 样式直接崩溃（事件日志只有 0xc000027b）。新子类控件要在 XAML 里引用一次；崩溃先看 `%LOCALAPPDATA%\BetterChat\crash.log`。
