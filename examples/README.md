# 示例数据与数据源配置

这里的 JSON 只用于首次启动、开发和测试，数值是虚构的公开 fixture，不代表任何账号的真实额度。

Windows 版默认内置 Codex 同步器：它读取当前 Windows 用户 `%USERPROFILE%\.codex\auth.json` 中的 Codex 登录状态，并把 5 小时与周额度写入 `%LOCALAPPDATA%\QuotaDock\data\codex.json`。其他平台或自定义同步器可通过 `%LOCALAPPDATA%\QuotaDock\quota_sources.json` 配置数据路径；`codexSyncScript` 留空时使用内置 Codex 同步器。

也可以使用同名环境变量覆盖配置：

- `QUOTADOCK_CODEX_DATA`
- `QUOTADOCK_GROK_DATA`
- `QUOTADOCK_OPENCODE_DATA`
- `QUOTADOCK_CODEX_SYNC`
- `QUOTADOCK_GROK_SYNC`
- `QUOTADOCK_PYTHONW`

QuotaDock 只读取本地 JSON，不会因为填写了路径就自动获得第三方账号权限。
