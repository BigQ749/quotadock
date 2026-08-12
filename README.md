# QuotaDock

一个 Windows 桌面额度浮窗管理器：把 Codex、Grok、OpenCode Go 或自定义平台的额度卡片分别打开，也可以把多个卡片拖到一起，合成一个可整体移动的浮窗。

QuotaDock 不代理第三方账号，不保存 Cookie 到项目目录，也不承诺突破任何平台额度。它把“额度数据来源”和“桌面呈现”分开：同步器写本地 JSON，QuotaDock 只读取并显示。

QuotaDock is a local-first Windows AI quota dashboard and floating overlay for Codex, ChatGPT, Grok, OpenCode Go, Claude Code, and custom providers. It supports independent or merged cards, weekly / 5-hour / monthly quota windows, local JSON adapters, Chrome bridge sync, per-user installation, GitHub Releases, and user-controlled updates.

![QuotaDock 管理中心](docs/images/quotadock-center.png)

![多平台合体浮窗](docs/images/quota-fusion-window.png)

## 功能

- 一个 QuotaDock 管理中心，按需打开或关闭 Codex、Grok、OpenCode Go 和自定义平台。
- 每个提供商可以独立移动、最小化、关闭；拖近后真正合并为一个宿主窗口，拖出后恢复独立卡片。
- 左、右、上边缘自动藏边；下边不启用藏边。合体窗口与单卡片使用同一套拖拽和藏边逻辑。
- 高 DPI 感知绘制、统一品牌标识、较大的百分比数字和同步状态。
- OpenCode Go 支持 Chrome 页面桥接，也支持配置一次后每 60 秒后台直连官方页面；两种方式都只提取额度数值。
- 自定义平台使用本地 JSON，最多显示 3 个额度窗口，适合 Claude Code 或其他没有统一公开额度 API 的平台。
- 启动时检查 GitHub Releases；发现新版本后只弹窗，用户可选择打开下载页或稍后处理。

搜索关键词：Windows AI quota tracker、AI usage monitor、quota dashboard、floating quota widget、Codex quota、ChatGPT quota、Grok quota、OpenCode Go quota、Claude Code quota、PowerShell WinForms、local-first desktop overlay。

## 安装

从 GitHub Releases 下载 `QuotaDock-Setup-*.exe`，双击安装即可。安装器是当前用户范围安装，默认目录为 `%LOCALAPPDATA%\Programs\QuotaDock`，不要求管理员权限；同时创建开始菜单和桌面快捷方式。

安装包由 GitHub Actions 根据 `packaging/QuotaDock.iss` 构建。源码仓库不包含任何真实额度、凭据、日志或个人桌面截图。

## 第一次配置数据源

安装后复制示例配置：

```powershell
$state = Join-Path $env:LOCALAPPDATA 'QuotaDock'
New-Item -ItemType Directory -Path $state -Force | Out-Null
Copy-Item .\examples\quota_sources.example.json (Join-Path $state 'quota_sources.json')
```

编辑 `%LOCALAPPDATA%\QuotaDock\quota_sources.json`，把路径改成你自己的同步器输出文件。也可以用环境变量覆盖：

```powershell
$env:QUOTADOCK_CODEX_DATA = 'C:\path\to\codex.json'
$env:QUOTADOCK_GROK_DATA = 'C:\path\to\grok.json'
$env:QUOTADOCK_OPENCODE_DATA = 'C:\path\to\opencode_go.json'
```

如果没有真实数据源，程序会先读取 `examples/` 中的虚构 fixture，方便确认界面能正常打开；这些数字不是任何账号的实时额度。

## 数据格式

Codex 示例：`examples/codex.quota.example.json`。Grok 示例：`examples/grok.quota.example.json`。OpenCode Go 示例：`examples/opencode_go.quota.example.json`。

自定义平台可以使用：

```json
{
  "title": "Claude Code",
  "badge": "本地同步",
  "updatedAt": "2026-01-01T00:00:00Z",
  "windows": [
    {
      "label": "周额度",
      "remainingPercent": 75,
      "resetText": "示例：1月3日 12:00"
    }
  ]
}
```

QuotaDock 不会猜测接口，也不会替自定义平台登录。需要用户自行提供合法、合规的同步器，并只把脱敏后的额度结果写入 JSON。

## OpenCode Go

推荐先使用 Chrome 扩展桥接：打开官方已登录页面，加载 `opencode-go-quota-bridge` 解压目录。扩展只匹配 `https://opencode.ai/workspace/*/go`，向 `127.0.0.1` 发送数值，不读取 Cookie、密码或 API Key。详细步骤见 [`opencode-go-quota-bridge/README.md`](opencode-go-quota-bridge/README.md)。

如果希望 Chrome 关闭后仍然每分钟更新，可以在本机执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\configure_opencode_go_background.ps1 -WorkspaceId wrk_xxx
```

脚本会隐藏输入 `auth` Cookie，并用当前 Windows 用户范围 DPAPI 加密保存。Cookie 不要提交到仓库、Issue 或聊天窗口。官方页面结构变化、登录过期、HTTP 401/403 都会使同步失败，这时应重新验证登录状态或重新配置凭据。

## 版本适配

- 支持 Windows 10/11 x64；脚本依赖 Windows PowerShell 5.1 自带的 WinForms。
- 高 DPI 显示器使用原生 DPI 感知；如果系统策略禁用了 PowerShell/WinForms，应用无法正常启动。
- 安装器是 per-user 安装，不需要管理员权限；企业环境如果限制执行脚本，请按组织策略签名或放行本目录。
- OpenCode Go 的页面桥接依赖 Chrome 扩展加载权限；后台模式依赖 Windows .NET `System.Net.Http` 和当前用户 DPAPI。
- 不同平台的额度窗口数量不同：Codex/Grok 可以只有周额度，OpenCode Go 可以是 5 小时、周、月；自定义平台最多 3 个窗口。

## 更新机制

维护者把版本号写入 `VERSION`，创建匹配的 `vX.Y.Z` tag。GitHub Actions 会校验版本、用 Inno Setup 生成安装器、生成 SHA-256 校验文件并创建 Release。

客户端启动时调用 GitHub Releases API，默认每 24 小时检查一次。只在发现更高版本时显示更新弹窗，用户点击“前往下载”后打开 Release 页面；不会静默替换文件，不会自动上传本地数据。

## 从源码运行

```powershell
Set-Location .\quotadock
powershell -NoProfile -ExecutionPolicy Bypass -File .\quota_center.ps1
```

本地构建需要 Inno Setup 6 的 `ISCC.exe`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\build.ps1 -Clean
```

没有 Inno Setup 时也可以直接运行脚本；GitHub Actions 会在 Windows runner 上自动安装 Inno Setup 并构建安装器。

## 常见错误

详见 [`docs/troubleshooting.md`](docs/troubleshooting.md)。最常见的原因不是 UI，而是数据源路径、Cookie 过期、第三方返回 401/403、Chrome 扩展没有加载，或 Windows PowerShell 程序集/执行策略受限。

## 给 AI/自动化工具的入口

项目范围、数据边界、架构、扩展点与常见坑集中在 [`llms.txt`](llms.txt)、[`docs/architecture.md`](docs/architecture.md) 和 [`docs/provider-adapter.md`](docs/provider-adapter.md)。处理本项目时请先阅读这些文件，再修改脚本；不要读取或提交 `%LOCALAPPDATA%\QuotaDock` 下的凭据和真实数据。

## 许可证与商标

代码采用 MIT License。第三方平台的名称、商标和图标归各自权利人所有，详见 [`TRADEMARKS.md`](TRADEMARKS.md)。
