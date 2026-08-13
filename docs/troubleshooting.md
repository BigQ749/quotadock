# 故障排查

## 浮窗打不开或一闪而过

先用 PowerShell 前台运行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\quota_center.ps1
```

再运行 `tests/selftest.ps1`。检查 `%TEMP%\quota-center-error.log`、`%TEMP%\quota-fusion-host-error.log` 和 `%TEMP%\quota-fusion-host-paint.log`，日志中不应包含 Cookie 或完整页面 HTML。

## 卡片显示“等待首次同步”

检查 `%LOCALAPPDATA%\QuotaDock\quota_sources.json`、环境变量和目标 JSON 是否存在。第一次启动的示例数值只是 fixture；接入真实同步器后要确认它确实持续覆盖目标文件。

## OpenCode Go 是旧数据或同步失败

- Chrome 桥接：确认扩展已加载、页面 URL 匹配 `https://opencode.ai/workspace/*/go`，本地桥接端口为 `45731`。
- 后台模式：确认 `opencode_go_credentials.json` 存在，并重新运行配置脚本；不要把 Cookie 放进命令行参数。
- HTTP 401/403 通常表示会话过期或 Cookie 不再被官方页面接受，不是 UI 刷新问题。
- 页面字段变化会导致解析器自测或同步失败，应更新解析器并增加 fixture，不要把异常当作有效额度。

## 额度框与 QuotaDock 状态不一致

不要同时运行旧版独立脚本和新宿主。退出 QuotaDock 后重新从安装目录启动；宿主状态文件是 `%LOCALAPPDATA%\QuotaDock\host_state.json`，它只记录窗口状态，不包含额度凭据。

## 更新弹窗没有出现

启动时更新检查每 24 小时一次；当前版本没有高于 `VERSION` 的 GitHub Release 时不会自动弹窗。点击管理中心的 `↑ 检查更新` 会显示当前版本，并立即检查 GitHub Release；网络失败会显示可重试提示。调试时可删除 `%LOCALAPPDATA%\QuotaDock\update_check.json`，或设置 `QUOTADOCK_DISABLE_UPDATE_CHECK=1` 暂时关闭。
