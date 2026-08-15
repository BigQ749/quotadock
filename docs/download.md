# 下载选择指南

QuotaDock 现在按系统提供 Windows 安装器和 macOS 原生预览包。Windows 普通用户应下载带 `Setup` 的安装器；Windows ZIP 只用于便携运行、故障回退和应用内部更新。下载页只发布已经实际构建的文件，源码分支不保存历史安装包，所有发行二进制统一放在 GitHub Releases。

## 应该下载什么

| 系统 | 文件 | 说明 |
|---|---|---|
| Windows 10/11 x64 | `QuotaDock-Setup-X.Y.Z.exe` | 首选版本；带安装向导、目录选择、许可证和开机启动选项 |
| Windows x86 | 同一个安装包 | Inno Setup 使用 x86 兼容模式；脚本依赖 PowerShell 7+ |
| 便携/更新 | `QuotaDock-vX.Y.Z.zip` | 不显示安装向导；适合便携运行、回退和应用内部更新 |
| Windows ARM64 | 暂无原生安装包 | 只有完成 ARM runner、安装测试和截图验收后才会发布 |
| macOS 13+ Apple Silicon (arm64) | `QuotaDock-macOS-vX.Y.Z.zip` | 原生 SwiftUI 菜单栏/浮动面板预览版；v0.2.1 已在 arm64 runner 验证，读取本地 `providers.json` |
| macOS Intel (x86_64) | 暂无已验证包 | Intel 构建尚未完成真实 CI 构建；不要把 Apple Silicon 包当作 Intel/通用包 |
| Linux | 暂不支持 | 当前没有 Linux UI 宿主与发行版 |

如果 Release 页面没有 `QuotaDock-Setup-X.Y.Z.exe`，说明该版本的 Windows 构建还没有完成；不要把 ZIP 当成安装器。不要把 `SHA256SUMS.txt` 当作安装器。它用于下载后校验：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command '$PSVersionTable.PSVersion'
Get-FileHash .\QuotaDock-Setup-X.Y.Z.exe -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

## 安装向导会做什么

- 显示欢迎页和 MIT 许可证确认页（当前安装器界面为 Inno Setup 默认英文界面）。
- 允许选择安装盘和目录，默认安装到当前用户的 `%LOCALAPPDATA%\Programs\QuotaDock`，不要求管理员权限。
- 创建开始菜单和桌面快捷方式。
- 可选创建“登录 Windows 时自动启动”的用户启动项；默认不勾选。
- 安装前检查 PowerShell 7+；缺少时会提示安装地址。
- 安装完成后可直接启动 QuotaDock。
- 不会把 Cookie、真实额度 JSON 或运行日志打进安装包。
- 卸载时保留 `%LOCALAPPDATA%\QuotaDock`，避免误删用户配置和加密凭据。

安装目录里的 `.vbs` 文件只是隐藏启动包装，桌面用户不需要手动运行它；正常入口是“QuotaDock”桌面或开始菜单快捷方式。

macOS ZIP 解压后，把 `QuotaDock.app` 拖入“应用程序”。预览包目前未做 Developer ID 签名和公证；首次打开可能需要到“系统设置 → 隐私与安全性”允许。macOS 不需要 PowerShell 7+，也不会读取 Windows 的 `%LOCALAPPDATA%`。

## 更新

客户端读取公开的 `update-manifest.json`。清单指向对应 GitHub Release 的版本化 ZIP，而不是源码分支里的旧构建目录。新版本提醒后，用户点击“立即更新”，QuotaDock 会直接下载版本化 ZIP、校验 SHA-256、等待当前中心退出、替换程序文件并自动重启；用户数据仍保存在 `%LOCALAPPDATA%\QuotaDock`，不会上传到仓库。

## macOS 预览版边界

macOS 版本使用 AppKit + SwiftUI 的独立 UI 宿主，读取 `~/Library/Application Support/QuotaDock/providers.json`。首个预览包不复用 Windows 的 PowerShell、DPAPI、Chrome 桥接或账号同步脚本；真实三平台同步需要逐个平台验证后再发布。详见 [`macOS 版本说明`](macos.md)。
