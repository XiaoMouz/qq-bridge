# 共享媒体分页与查询隔离复验（2026-10-15）

## 实现

原共享视图的 `reload()` 在旧请求仍 loading 时清空列表，新的 `loadMore()` 被 loading guard 拦住；旧响应仍能追加到已切换的类型/排序。请求失败被当作 done，没有显式重试。Mac 现拆成服务、ViewModel 和空状态/分页组件；iOS 原加载分支保持。

- 类型或排序变化清空旧查询状态并换代，成功/失败迟到均失效。
- 失败保留已有项和原游标，首屏与末尾都有重试；错误状态下末项出现不会自动循环请求。
- 最新排序使用 before_seq，其他排序使用 offset；游标必须正确推进，空中间页可以继续。
- 相同 seq/kind/ord 更新已有媒体，不重复追加；同一消息不同 ord 均保留。
- Mac 缩略图使用标准 Button，标注图片/视频、发送者、日期和独立窗口提示。
- 大小排序没有分组标题时不显示空标题栏，分页完成不保留空底部行。

## 验证

七项生产模型测试通过：`/tmp/betterchat-shared-media-tests.log`，源码累计 74 项，本轮不是全量运行。覆盖查询乱序、取消、两种游标、首屏与后续失败、空中间页、重复项、游标不推进。Claude Code Opus 5.5 已按 auto 模式只读复核源码及 proto/服务端分页语义，没有发现本轮确定缺陷；原评审见 [Opus 记录](OPUS_SHARED_MEDIA_REVIEW.md)。其附录记录服务端大小相等时排序缺乏 ordinal 兜底的风险，尚未复现，不当作本轮已修复问题。

临时 DEBUG 服务注入生产 SharedMediaView，模拟首屏超时→四张过期占位图→后续页超时→含重复项的八张图。占位项没有触发媒体下载，未上传、发送或修改真实消息。440×480 实测首次重试、后续失败保留四格、末尾重试追加成八格、错误消失，切到文件显示三份虚拟文件，再按大小排序正常显示；1024×640 检查文件列表。临时菜单、协调器入口和源文件已删除。

截图 `/tmp/betterchat-ui-review/shared-media-first-error-440.png`、`shared-media-page-error-440.png`、`shared-media-retry-eight-440.png`。受控故障验证不代表真实后端断网和所有媒体格式验收。

## 最终正常入口复验

Something → 右上角群资料 → 图片、视频与文件：真实图片/视频与月份分组显示，缩略图辅助功能包含明确按钮名称与日期/发送者。点击已有验收图片打开独立“图片 · BetterChat”窗口（1/17），Esc 返回共享媒体列表。切到文件后显示真实文件；大小排序按 309.3 MB、62.8 MB、270 KB、12 KB、11 KB、68 字节递减，宽/440 点窗口均可读，空分组标题已消失，没有下载或打开可执行文件。截图 `shared-media-real-files-size.png`、`shared-media-real-files-size-440.png`。

Mac 最终构建 `/tmp/betterchat-shared-media-final-build.log`、iOS 最终构建 `/tmp/betterchat-shared-media-final-ios.log` 均通过；严格签名、差异检查通过，Package.resolved 未变。应用恢复 1024×640、Something、空搜索和输入。没有发送、上传、修改群设置或改变 QQ 在线状态。真实长会话完整分页终点、真实断网和全部排序边界仍不由上述短列表及受控测试替代。
