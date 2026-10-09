# 安全说明

## 不要提交的内容

- 第三方平台 Cookie、会话令牌、API Key、密码或 OAuth 文件。
- `%LOCALAPPDATA%\QuotaDock` 下的凭据、日志、运行状态和真实额度快照。
- 包含账号名、workspace ID、设备信息或个人路径的截图。

## OpenCode Go

后台同步凭据按当前 Windows 用户范围使用 DPAPI 加密保存，仅用于向官方页面发起只读请求。Cookie 过期后应在本机重新配置，不要把 Cookie 粘贴到 Issue、Pull Request 或聊天窗口。

如果发现安全问题，请不要公开提交真实凭据或可复现的会话内容；请先通过 GitHub Security Advisories 或仓库维护者的私下渠道报告。

## 隐私与本地优先

QuotaDock 无遥测、不上传额度或 Cookie。完整说明见 [`docs/privacy.md`](docs/privacy.md)。
## Windows 代码签名与 SmartScreen

公开发布的 `QuotaDock-Setup-*.exe` 若未经 Authenticode 签名，SmartScreen 可能显示「未知发布者」。消除该提示需要付费的 OV/EV 代码签名证书与安全的私钥保管；**切勿**把 PFX、密码或令牌提交到本仓库。
