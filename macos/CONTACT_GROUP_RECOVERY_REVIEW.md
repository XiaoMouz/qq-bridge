# 联系人群资料恢复与路由保护（2026-10-15）

## 修复

Mac 联系人群资料原先复用 iOS ContactGroupView：请求失败只有错误文字；重复点击同一联系人不会重建页面，因此不能直接恢复。建会话后等前 5000 条列表中出现目标，也没有等待截止时间。

新增 MacContactGroupService / ViewModel / View，并由 MacPageFactory 装配。通过新增的 LocalStore.observeDialog(chatId:) 定向观察会话；整个加载 30 秒超时后显示重试，离开取消，代次隔离迟到成功和失败。加载成功后保留资料和导航栈；返回子页面不重新创建会话。iOS 的 ContactGroupView 未修改，Kit 新增查询不改变既有接口行为。

Opus 只读评审还确认删除好友迟到回调会清空后来打开的联系人或强制切回联系人标签。Mac 协调器现始终刷新列表，仅在当前选择仍是原联系人时清空资料，并且只在联系人分区刷新右侧页面。没有取消服务端写操作，没有执行真实删除。该路由保护目前为代码核对和编译验证，不能称为真实迟到删除验收。

## 验证

- MacContactGroupTests 四项通过：失败重试和已加载页面保留、超时后迟到成功、超时后迟到失败、取消后返回隔离旧响应。日志 `/tmp/betterchat-contact-group-tests.log`。
- Swift 包全部 38 项测试通过，包含新增定向观察的缺失、落库、更新及不受列表窗口限制检查。日志 `/tmp/betterchat-contact-group-kit.log`。
- 最终正常 Mac 构建 `/tmp/betterchat-contact-group-final-build.log`、iOS 构建 `/tmp/betterchat-contact-group-ios.log` 成功；Mac 严格签名与差异检查通过，Package.resolved 未变化。
- 退出旧进程后打开最终构建，从联系人群聊搜索 Something 进入群资料，显示群号与 4/200 人；进入群文件，切换消息再返回仍保留子页面，返回资料后显示成员 4。截图 `/tmp/betterchat-ui-review/contact-group-loaded.png`。
- 恢复 Something、空搜索/输入及联系人好友分段。未发送、删除好友或修改群设置。

Opus 5.5 auto 只读评审见 [原始结论](OPUS_CONTACTS_REVIEW.md)。评审期间代码仍在推进，第一项旧回调已按上文修正；新群资料请求模型得到源码复核，无确定缺陷。实机操作由 Codex 完成；没有实网断开/恢复，也未用 UI 故障注入验证错误布局。

## 明确剩余项

Opus 确认 GroupInfoView 和 GroupMembers 会吞掉资料/成员加载失败，成员 0 可能掩盖错误；聊天详情与联系人资料两入口均需补错误、重试与保留旧数据。该问题已在后续 [群资料与成员恢复](GROUP_PROFILE_RECOVERY_REVIEW.md) 修复，原评审保留作为历史依据。真实删除写操作与迟到回包仍未验收。
