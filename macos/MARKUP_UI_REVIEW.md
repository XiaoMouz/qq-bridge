# 图片标注响应式与坐标复验（2026-10-14）

> 2026-10-15：用户明确要求只下掉 Mac 图片编辑，手机版保留。Mac 的编辑入口、专用工具栏和相关测试已移除。下文为历史调查记录，不代表当前 Mac 仍提供标注，也不再是 Mac 功能待办。

本轮由 Codex 操作真实 Mac 界面，Claude Code（Opus 5.5、auto）复核源码与截图、实现共享画布修复。仅使用 Something 中已有的测试 PNG；临时笔迹全部取消，没有新消息、上传或保存到用户下载目录。完整标注能力仍未全部验收。最终独立复核日志为 `/tmp/betterchat-markup-final-review.jsonl`。

## 发现与修复

- 旧工具栏固定单行，440×480 下直尺按钮被裁切。现用 `MacMarkupToolbarLayout` 让同一组原生控件在窄窗口分两行，600/1024 点保持单行。中间曾使用 ViewThatFits，发现其两份菜单在切换尺寸后可视标签滞留旧值，已替换；最终套索选择跨尺寸时可视文字与辅助功能状态一致。
- 旧画布大小直接跟随窗口 fit，笔迹却保留旧点坐标；窄窗口画的线在放大后偏离原图位置，导出也受当时窗口大小影响。Claude 新增共享 `MarkupCanvasView`，保持固定逻辑坐标，只改变 PencilKit 的显示缩放；导出按固定矩形绘制。布局不重写 drawing，也不修改撤销历史。
- 实现参考 Apple [Drawing with PencilKit](https://developer.apple.com/documentation/pencilkit/drawing-with-pencilkit) 的固定逻辑宽度布局，以及 [PKCanvasView](https://developer.apple.com/documentation/pencilkit/pkcanvasview) 的 UIScrollView 内容尺寸与缩放能力。此处逻辑长边为 768，原图比例不变。

## 实际界面证据

截图位于 `/tmp/betterchat-ui-review/`：

| 截图 | 证明范围 |
|---|---|
| `markup-toolbar-440-before.png` | 旧版直尺按钮右侧被裁切 |
| `markup-toolbar-layout-440-light.png` | 最终两行工具栏，套索、颜色、直尺及粗细完整可见 |
| `markup-toolbar-layout-600-dark.png`、`markup-toolbar-layout-1024-dark.png` | 最终单行工具栏及非默认套索选择保留 |
| `markup-canvas-fixed-440-two-strokes.png` | 在窄窗口的蓝色、黄色色块各画一笔 |
| `markup-canvas-fixed-1024-two-strokes.png` | 放大后两笔仍位于原来的相对位置 |
| `markup-canvas-fixed-1024-undo.png` | 放大后用实际撤销按钮移除最后一笔，第一笔位置保持 |
| `markup-canvas-fixed-440-redo.png` | 缩小后用实际重做按钮恢复最后一笔，位置保持 |
| `markup-canvas-fixed-ruler-440.png` | 固定坐标画布上真实直尺吸附绘制 |
| `markup-toolbar-final-full-width.png`、`markup-toolbar-final-440.png` | 采纳 Claude 建议补齐整行背景后的最终宽/窄截图 |
| `markup-final-workspace.png` | 所有标注取消后恢复 Something 最新消息、宽窗口与系统外观 |

`markup-toolbar-440-*-after.png`、`markup-toolbar-1024-light-after.png` 是中间 ViewThatFits 版本，不能用来代替最终工具栏证据。

## 构建与隔离测试

Mac 与 iOS 工程已重新生成。Mac 应用测试 22 项通过，含新增 5 项画布检查：缩放/偏移、笔迹坐标不被布局改写、宽窄导出 PNG 完全相同且命中预期像素、登记的 UndoManager 历史保持、重复布局稳定。测试中的撤销项是手动登记的；PencilKit 自身手势撤销由上述真实鼠标检查补证。

- Mac：`/tmp/betterchat-markup-canvas-tests.log`
- iOS 构建：`/tmp/betterchat-markup-canvas-ios.log`
- Mac 严格签名与 `git diff --check` 通过；Package.resolved 未变。

测试使用本地生成图片、隔离窗口，不恢复账号、不连接后端。PNG 导出已在真实生产渲染函数中验证；本轮没有实际点击完成后保存用户文件。

## 未通过或尚未证明

- 套索右键“全选”可选中笔画，但拖动移动本轮未成功，不能宣称套索完整通过。
- 切换整笔橡皮擦后的第一次自动化拖动没有擦除，第二次成功。这与此前切笔首笔现象一致；原因尚未区分为输入自动化或应用响应问题，未加入猜测性焦点补丁。
- 标注期间跨断点的标题覆盖已在后续修复，见下节；其他笔型/手势的验收范围不因此扩大。
- 所有笔型、很长/很大图片、iOS 旋转/分屏及工具面板交互仍待专项实测。
- 本轮没有再次验证真实发送，也没有将构建和共用源码当作全功能一致的证明。

## Claude 最终独立复核

Claude 阅读最终画布源码与两笔/缩放/撤销/重做截图，未发现固定逻辑坐标实现的实质回归；确认笔迹相对位置和撤销重做截图一致，并保留套索、首次拖动与 iOS 运行验收边界。其指出宽窗口工具栏背景只占中间区域，Codex 已增加背景前的全宽 frame；最终 Mac 构建 `/tmp/betterchat-markup-final-build.log` 成功，严格签名通过，并截图确认背景铺满、440 点两行仍完整。该末次背景补丁由 Codex 实机复验，未再重复不受影响的画布测试或 iOS 构建。

复核文字将 600 点工具栏误记为两行；Codex 实际截图 `markup-toolbar-layout-600-dark.png` 为单行，按截图记录，不据复核文字扩大通过范围。

## 2026-10-14 全屏覆盖期间的导航标题与返回布局

Codex 实测对照：600→440 点不跨断点时标题仍为“编辑”；1024→440 点跨断点时主工作区重挂导航容器，标题被聊天导航项覆盖。只保护 scene.title 的候选无效，已撤掉。仅延迟搬移而靠 viewDidAppear 恢复的候选也不足：透明覆盖退出后未触发补布局，主窗口仍是挤窄的双栏；这项候选已替换。

最终 MacAdaptiveSplitController 仅在同窗口全屏覆盖期间推迟导航栈搬移，普通表单不阻挡。共享 `platformFullScreenCover` 保留系统 item/bool 绑定与 onDismiss，在实际退出时通过环境动作、当前工作区路由请求布局。页面工厂为独立 HostingController 注入动作，根视图为全局浮层注入。图片查看器、标注、群图片画廊和相机统一使用该入口；iOS 不执行 Mac 回调。

实机检查已完成：

- 1024 打开测试 PNG 标注 → 440，标题保持“编辑”；Esc 退出编辑器与图片查看器后显示真正 Back 按钮的单栏聊天。
- 从 440 再打开标注 → 1024，标题保持“编辑”；退出后恢复并排双栏。
- 3 项真实 UIKit 导航测试覆盖两个方向及普通 formSheet 不阻挡适配，全部通过。测试不读取真实账号、不发消息。

截图在 `/tmp/betterchat-ui-review/`：`markup-title-final-440.png`、`markup-title-final-1024.png`、`markup-title-final-return-440.png`、`markup-title-final-return-1024.png`。`markup-title-fixed-440.png` 属于缺少退出补偿的中间版本，不作为最终证据。

Claude Code Opus 5.5 独立读图确认两种尺寸的编辑标题和退出后的单/双栏，并指出画廊/相机入口需接同样回调，已统一封装。画廊和相机的真实跨断点退出仍未单独实测；本轮不将源码接线等同于硬件功能通过。全部临时诊断代码已移除。

最终共用包装器版本再次完成双向实机检查：`markup-cover-final-440.png`、`markup-cover-final-1024.png`、`markup-cover-final-return-440.png`、`markup-cover-final-return-1024.png`。两平台构建分别为 `/tmp/betterchat-cover-layout-mac.log`、`/tmp/betterchat-cover-layout-ios.log`，均成功；严格签名及 git diff --check 通过，Package.resolved 未变。Claude 对最终包装器的独立源码复核未发现实质问题。
