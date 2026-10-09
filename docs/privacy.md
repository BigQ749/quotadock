# 隐私说明

QuotaDock 是本地优先（local-first）的额度浮窗与管理中心。

## 我们不会做什么

- **无遥测**：不收集使用统计、崩溃上报、设备指纹或“改进计划”类后台数据。
- **不上传额度**：本地 JSON 快照、浮窗状态、同步结果只留在本机，不会发往 QuotaDock 作者或第三方分析服务。
- **不上传 Cookie / Token**：适配器若需要登录态，仅在本机读写（例如 Windows DPAPI 加密文件）。仓库、安装包和更新包都不包含真实凭据。
- **更新检查只读公开清单**：启动或手动“检查更新”时，会请求公开的 `update-manifest.json` / GitHub Release 元数据。该请求不含额度内容、不含 Cookie、不含个人路径。

## 本机存放位置

| 位置 | 内容 |
|---|---|
| `%LOCALAPPDATA%\QuotaDock\`（Windows） | 额度 JSON、宿主状态、加密凭据、更新检查缓存、新手引导标记 |
| `~/Library/Application Support/QuotaDock/`（macOS） | 预览版 `providers.json` 等本地快照 |

卸载安装器时默认**保留**上述用户数据目录，避免误删配置与凭据。

## 可选同步适配器

`adapters/` 下的脚本由用户自愿运行，用于把本机登录态写成 QuotaDock 可读的 JSON。请勿把 Cookie、Token、真实额度快照或含个人路径的截图提交到公开仓库。详见 [`SECURITY.md`](../SECURITY.md) 与 [`providers-grokbot-muse-claude.md`](providers-grokbot-muse-claude.md)。

## 商标与第三方

平台名称与品牌标识分属各自权利人；QuotaDock 仅为本地展示层，不代表任何平台官方产品。见 [`TRADEMARKS.md`](../TRADEMARKS.md)。
