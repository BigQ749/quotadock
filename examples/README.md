# 示例数据与数据源配置

这里的 JSON 只用于首次启动、开发和测试，数值是虚构的公开 fixture，不代表任何账号的真实额度。

安装后建议把配置复制到 `%LOCALAPPDATA%\QuotaDock\quota_sources.json`，再把 `codexPath`、`grokPath` 和 `opencodePath` 改成你自己的同步器输出文件。也可以使用同名环境变量覆盖配置：

- `QUOTADOCK_CODEX_DATA`
- `QUOTADOCK_GROK_DATA`
- `QUOTADOCK_OPENCODE_DATA`
- `QUOTADOCK_CODEX_SYNC`
- `QUOTADOCK_GROK_SYNC`
- `QUOTADOCK_PYTHONW`

QuotaDock 只读取本地 JSON，不会因为填写了路径就自动获得第三方账号权限。
