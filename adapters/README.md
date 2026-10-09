# 可选同步适配器

这些脚本 **不是** 安装包必选组件；它们帮助本机把官方/本地登录态同步成 QuotaDock 可读的 JSON。

凭证、Cookie、Token 只应存放在 `%LOCALAPPDATA%\QuotaDock\`（或系统钥匙串/DPAPI），切勿提交仓库。

| 目录 | 输出 | 说明 |
| --- | --- | --- |
| `grokbot/` | `custom-data\grokbot.json` | 读取 Grok Bot / Cursor 登录态 |
| `muse/` | `custom-data\muse.json` | DPAPI Cookie + Muse 订阅接口 |
| `claude/` | `custom-data\claude.json` | 暂无同步实现，仅约定 |
