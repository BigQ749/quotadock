# 参与贡献

## 开始前

先阅读 [`llms.txt`](llms.txt)、[`docs/architecture.md`](docs/architecture.md) 和 [`SECURITY.md`](SECURITY.md)。这是一个 PowerShell 7+ + WinForms 的 Windows 项目，合体窗口必须保持“一个真实宿主窗口”的模型。

## 提交前检查

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\selftest.ps1
```

如果改动了拖拽、合体、藏边、关闭或托盘状态，请提供实际桌面截图和复现步骤；静态检查不能替代真实窗口验收。

## 不要提交

- Cookie、session token、API key、密码或 DPAPI 明文。
- 真实额度 JSON、日志、个人绝对路径和桌面截图。
- 未验证的 Mac/Linux/ARM 安装器链接。

Bug 报告请注明 Windows 版本、PowerShell 版本、QuotaDock 版本、是否独立/合体/藏边，以及脱敏后的错误日志。
