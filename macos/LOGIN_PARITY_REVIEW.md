# Mac 登录入口补齐（2026-10-15）

Opus 5.5 实现服务器预设、实际连接地址、连通性状态与可滚动布局；Codex 补 APIError 文案、密码 editingChanged 同步和取消时结束健康检查。健康查询不携带登录凭据，地址规则复用 AppModel.normalize，400ms 防抖、5 秒超时，离开页面取消并隔离迟到结果。

## 已验证

- `LoginViewModelCheck` 实际编译运行通过：防抖、旧请求隔离、无效地址、状态码、重试、预设、离开和释放。
- `MacLoginLayoutTests` 五项通过（`/tmp/betterchat-login-share-tests.log`）：最小/宽窗口、长地址与双错误滚动可达、健康状态刷新不擦除密码，以及服务器错误语义。
- 真实生产控制器的隔离入口在 440×480 窗口展示本机 `/healthz` 成功；改成不可连接端口后失败/重试正常，改回本机后恢复成功，密码仍保留。
- 本机与 Tailscale 预设均存在，选择后实际 URL 更新。Tailscale 此次出现 TLS 连接失败，按原错误显示，未降低校验要求。
- 假认证服务产生长错误后可滚动到完整提示。此入口不发登录请求、不保存偏好，已从源码移除。

截图：`/tmp/betterchat-ui-review/login-health-440.png`、`login-error-scroll-440.png`。

## 边界

未退出用户有效账号，也没有替用户输入真实凭据；上述验证不能替代重新登录端到端验收。密码实际编辑事件另由 UIKit 测试覆盖，UI 工具填充使用辅助功能 setValue。

最终构建：Mac `/tmp/betterchat-drop-diagnostics-final-build.log`、iOS `/tmp/betterchat-login-share-final-ios-build.log` 均成功，Mac 严格签名及差异检查通过。Package.resolved 无变化。Mac 包含正在等待真实拖放证据的 DEBUG 插桩，详见 [拖放诊断](FILE_DROP_REVIEW.md)。
