# 下载选择指南

QuotaDock 当前是 Windows-first 桌面应用。下载页只发布已经实际构建和验证过的文件，不用“Mac 版”“ARM 原生版”等名称包装未实现的版本。

## 应该下载什么

| 系统 | 文件 | 说明 |
|---|---|---|
| Windows 10/11 x64 | `QuotaDock-Setup-X.Y.Z.exe` | 首选版本；在 Windows runner 构建并发布 |
| Windows x86 | 同一个安装包 | Inno Setup 使用 x86 兼容模式；脚本依赖 PowerShell 7+ |
| Windows ARM64 | 暂无原生安装包 | 只有完成 ARM runner、安装测试和截图验收后才会发布 |
| macOS/Linux | 暂不支持 | 当前 UI 使用 PowerShell 7+ + WinForms |

不要把 `SHA256SUMS.txt` 当作安装器。它用于下载后校验：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command '$PSVersionTable.PSVersion'
Get-FileHash .\QuotaDock-Setup-X.Y.Z.exe -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

## 安装器会做什么

- 允许选择安装目录，不要求管理员权限，默认安装到当前用户的程序目录。
- 显示 MIT 许可证确认页。
- 创建开始菜单和桌面快捷方式。
- 可选创建“登录 Windows 时自动启动”的用户启动项。
- 不会把 Cookie、真实额度 JSON 或运行日志打进安装包。
- 卸载时保留 `%LOCALAPPDATA%\QuotaDock`，避免误删用户配置和加密凭据。

## 更新

客户端只检查 GitHub Releases 的版本号。新版本提醒后，用户可以打开下载页、校验 SHA-256、再次运行安装器并选择目标目录。当前版本不做静默更新，也不在后台上传本地数据。

## 为什么没有 Mac/Linux 下载项

这是当前实现边界，不是遗漏：WinForms、PowerShell 7+、用户启动项和 Inno Setup 都是 Windows 方案。跨平台版本需要另做 UI 宿主、安装器、更新器和真实平台验收；在这之前，发布页不会放无法运行的空链接。
