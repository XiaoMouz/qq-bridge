# 群文件移动目录选择复验（2026-10-15）

## 缺口与修复

共享 `GroupFolderPicker` 加载失败后只显示错误，没有显式重试；Mac 群文件主列表已有的恢复能力没有覆盖这个弹窗。

Mac 新增独立 `MacGroupFolderPicker`，复用生产 `MacGroupListViewModel` 和统一错误反馈，通过 `MacGroupFoldersService` 读取现有根目录 RPC。首次失败可重试，刷新失败保留已加载目录；取消立即使请求失效，关闭后迟到结果不能覆盖新状态。当前目录禁选，成功空列表仍显示根目录，避免将合法移动目标误当空状态隐藏。iOS 继续使用原页面与加载逻辑。

真实 Something 群文件入口发现 SwiftUI 内部 sheet 的鼠标取消不生效；单独改为显式 `showMove = false` 仍未关闭，Esc 可以退出。这说明直接 UIKit 宿主的受控验收不足以证明实际调用链。最终 Mac 改用已有 `MacFormPresenter`，关闭回调清除原页面状态，系统 Esc 和外部关闭也统一清理。iOS 保留 `.sheet` 与原 `dismiss`。

## 验证

- 六项现有 `MacGroupListTests` 全部通过：首次失败/空结果、刷新失败保留、重复加载合并、取消后的迟到成功和失败、返回保留内容。日志 `/tmp/betterchat-folder-picker-tests.log`。没有新增镜像实现测试；这组证据验证共用模型，不替代目录选择页的交互。
- 临时 DEBUG 入口使用生产页面、内存服务，依次返回超时、两个目录、刷新超时、空目录。实际 470×400 表单中重试成功、当前位置禁用、根目录可用、长名称展示、刷新失败保留目录及重试为空后仍有根目录均通过。Esc、重开和鼠标取消通过。没有选择任何真实移动目标。
- 截图 `/tmp/betterchat-ui-review/folder-picker-first-error.png`、`folder-picker-refresh-error.png`、`folder-picker-empty-root.png`。首次截图误采到转场已用稳定错误画面覆盖。
- 临时验收源码和菜单已移除。最终共用列表六项与原生表单八项回归共 **14 项**通过（`/tmp/betterchat-folder-picker-native-tests.log`）；不是一次全量 173 项运行。该命令构建最终 Mac 应用，iOS 最终构建 `/tmp/betterchat-folder-picker-ios.log` 通过；Mac 严格签名和差异检查通过，Package.resolved 未变。
- 确认旧进程退出后，在最终正常应用从 Something 群资料 → 群文件 → 既有 `04-file.txt` 右键 → 移动到打开。实际无子目录，根目录标记当前位置并禁用；鼠标取消确实回到群文件列表。再次打开、刷新完成与 Esc 返回通过。截图 `folder-picker-native-real.png`。最后两次返回回到 Something 主聊天、空输入。

此轮没有创建、删除、重命名、移动群文件或发送消息；真实写操作仍待验收。

## 补查：群文件转发选择页

在同一真实群文件页面，对既有 `04-file.txt` 打开“转发”，鼠标取消也未关闭表单；Esc 可退出。另从主聊天的同一文件消息打开“转发”，鼠标取消正常，因此没有据此修改所有 SwiftUI sheet。

Mac 群文件现由一个原生表单呈现器承载“转发 / 移动到”，绑定按不同标识区分内容，关闭清除对应页面状态。`ChatPicker` 增加可选的 Mac 取消回调，先取消建会话请求，再通知群文件页面关闭；其他调用仍走已有 dismiss，iOS 行为保留。呈现代码拆为独立属性，避免主视图长表达式推断超时。已有请求生命周期检查通过。

最终 Mac 构建 `/tmp/betterchat-group-forward-final-build.log`、iOS 构建 `/tmp/betterchat-group-forward-ios.log` 通过，Mac 严格签名、差异检查通过，Package.resolved 未变。请求生命周期命令行检查通过；未重复运行此前通过的原生呈现器测试，不宣称一次新的全量回归。

确认旧进程退出后，正常应用真实入口实测：转发筛选 Something、鼠标取消返回群文件；接着打开移动目录并取消，再次打开转发时搜索为空；Esc 返回正常。多选模式选中既有测试文件，打开转发后鼠标取消仍保留“已选 1 个”和该文件高亮。最后完成多选并回到 Something 主聊天、空输入。

截图 `group-file-forward-native-filter.png`、`group-file-forward-selection-kept.png` 位于 `/tmp/betterchat-ui-review/`。没有选择转发目的地、发送消息或移动文件。
