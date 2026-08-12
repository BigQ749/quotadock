# 安全说明

## 不要提交的内容

- 第三方平台 Cookie、会话令牌、API Key、密码或 OAuth 文件。
- `%LOCALAPPDATA%\QuotaDock` 下的凭据、日志、运行状态和真实额度快照。
- 包含账号名、workspace ID、设备信息或个人路径的截图。

## OpenCode Go

后台同步凭据按当前 Windows 用户范围使用 DPAPI 加密保存，仅用于向官方页面发起只读请求。Cookie 过期后应在本机重新配置，不要把 Cookie 粘贴到 Issue、Pull Request 或聊天窗口。

如果发现安全问题，请不要公开提交真实凭据或可复现的会话内容；请先通过 GitHub Security Advisories 或仓库维护者的私下渠道报告。
