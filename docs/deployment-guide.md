# 新手部署指南（实测经验版）

这份指南来自一台全新 Windows 电脑上从零安装 QuotaDock 的真实过程，记录了第一次部署会遇到的问题和解决办法。目标是让后来的人少走弯路：半小时内把浮窗跑起来，并且关掉浏览器也能自动同步额度。

## 1. 部署前检查清单

- Windows 10/11 x64 电脑。
- PowerShell 7+（`pwsh.exe`）。经典安装版和微软商店版都支持，见第 2 节。
- 可选：Chrome 浏览器。OpenCode Go 页面桥接模式需要它；后台同步模式不需要它。

## 2. 先确认 PowerShell 7 装好了

打开 PowerShell 7 或 Windows Terminal，运行：

```powershell
pwsh -NoProfile -Command '$PSVersionTable.PSVersion'
where.exe pwsh
```

`pwsh` 有两种常见安装方式：

| 安装方式 | 典型路径 | 说明 |
|---|---|---|
| 经典 MSI 版 | `C:\Program Files\PowerShell\7\pwsh.exe` | 启动器最容易找到 |
| 微软商店 MSIX 版 | `C:\Program Files\WindowsApps\Microsoft.PowerShell_*\pwsh.exe` | 通过 WindowsApps 里的执行别名启动，别名本身不是普通文件 |

商店版可以用下面命令确认版本：

```powershell
Get-AppxPackage -Name Microsoft.PowerShell
```

### 常见坑：弹出 “QuotaDock requires PowerShell 7+”

症状：双击 QuotaDock 快捷方式，弹窗提示需要 PowerShell 7+。

原因：旧版启动器只检查 `C:\Program Files\PowerShell\7\pwsh.exe`，而商店版 PowerShell 装在 WindowsApps 里，于是误判为“没装”。**这不是真的缺 PowerShell，是启动器找不到它。**

解决：

1. 先确认 `where.exe pwsh` 有输出；有输出就说明装好了。
2. 升级到包含启动器修复的版本。修复后的启动器会依次检查 Program Files、WindowsApps 别名、注册表 App Paths 和 `where.exe`（详见 `launch_quota_center.vbs` 等 4 个启动脚本）；如果某个发行版不小心回退了启动器，本机可以直接用修复后的脚本覆盖安装目录里的同名文件。
3. 升级后仍弹窗：检查 Windows 设置里“应用执行别名”是否把 PowerShell 的别名关掉了；或者直接安装经典 MSI 版 PowerShell 7。

## 3. 下载并校验安装包

1. 打开 [Releases](https://github.com/BigQ749/quotadock/releases)，下载 `QuotaDock-Setup-*.exe` 和同版本 `SHA256SUMS.txt`。
2. 校验哈希后再安装：

```powershell
Get-FileHash .\QuotaDock-Setup-*.exe -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

3. 运行安装器：不需要管理员权限，可以自定义安装目录，安装器会创建桌面和开始菜单快捷方式，并可选“登录 Windows 时自动启动”。

## 4. 首次启动会发生什么

- 首次启动会创建数据目录 `%LOCALAPPDATA%\QuotaDock`（额度 JSON、状态、加密凭证都放在这里）。
- 没接真实数据源时，卡片会显示示例 fixture 数据，状态是“等待首次同步”，这是正常的。
- 管理中心有 `↑ 检查更新`，启动时也会自动检查一次公开更新清单，找到新版后下载、校验 SHA-256、替换文件并自动重启，额度数据不会被删除。

## 5. 接入真实额度数据

QuotaDock 只读本地 JSON，额度由同步器写入。三种方式任选：

### 方式 A：自己的同步脚本写 JSON（通用）

把脱敏后的额度写入 `%LOCALAPPDATA%\QuotaDock\quota_sources.json` 里配置的路径，或通过环境变量 `QUOTADOCK_CODEX_DATA`、`QUOTADOCK_GROK_DATA`、`QUOTADOCK_OPENCODE_DATA` 指定。数据结构见 `examples/` 目录和 README。

### 方式 B：OpenCode Go 后台同步（推荐，关掉浏览器也能跑）

只需要配置一次，之后每次启动 OpenCode Go 浮窗都会自动每 60 秒同步一次，不依赖 Chrome 保持打开：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\configure_opencode_go_background.ps1 -WorkspaceId wrk_xxx
```

脚本会：

- 隐藏输入 opencode.ai 的 `auth` Cookie，用当前 Windows 用户的 DPAPI 加密保存到 `%LOCALAPPDATA%\QuotaDock\opencode_go_credentials.json`。
- 自动做一次直连测试，失败会提示查看 `%TEMP%\quotadock-opencode-background.log`。
- 配置成功后，每次打开 OpenCode Go 浮窗都会自动拉起后台同步，每 60 秒更新一次额度。

不要把 Cookie 粘贴到仓库、Issue、截图或聊天记录里。

### 方式 C：Chrome 页面桥接（页面打开时同步）

1. 先启动桌面上的 OpenCode Go 浮窗（会同时启动本机桥接服务 `127.0.0.1:45731`）。
2. Chrome 打开并登录 `https://opencode.ai/workspace/*/go`。
3. 打开 `chrome://extensions`，开启开发者模式，选择“加载已解压的扩展程序”，选择 `opencode-go-quota-bridge` 目录。

页面保持打开时扩展每 60 秒同步一次；关闭页面后浮窗保留最后一次结果，并会标记为过期。这个模式的优点是不保存任何 Cookie，缺点是不能关浏览器。

## 6. 验证部署是否成功

看日志比看界面更可靠：

| 日志/文件 | 作用 |
|---|---|
| `%TEMP%\quotadock-opencode-background.log` | OpenCode Go 后台同步，每分钟一条 `fetch status=200` 就是正常 |
| `%TEMP%\quotadock-opencode-bridge.log` | Chrome 桥接日志 |
| `%TEMP%\quotadock-update.log` | 自动更新日志，含下载、校验、替换、重启记录 |
| `%LOCALAPPDATA%\QuotaDock\host_state.json` | 浮窗宿主状态（窗口开合、吸附），不含凭据 |
| `%TEMP%\quota-center-error.log` | 管理中心启动错误 |

自检清单：

- 卡片显示真实额度，而不是示例数据。
- “上次同步时间”是一分钟以内。
- 关掉 Chrome，等 60 秒，后台日志仍在 `fetch status=200`，说明后台同步生效。
- 重启电脑后（如果开了开机启动）QuotaDock 自动恢复并继续同步。

## 7. 真实踩过的坑和解决办法

### 7.1 “上次同步时间”是很久以前的时间

常见于自动更新重启之后：旧版本进程被替换，新的后台同步进程刚拉起，第一次成功同步前会短暂显示旧的成功时间。等 1-2 分钟再看，通常自动恢复。

如果一直不更新：

1. 看 `%TEMP%\quotadock-opencode-background.log` 最后几行：`fetch status=200` 说明在正常拉取；401/403 说明会话过期。
2. 确认同一个平台只有一个同步进程（`opencode_go_background_sync.ps1` 有写锁互斥，但不要手动再开一份）。
3. 401/403 或持续失败时重新运行 `configure_opencode_go_background.ps1` 更新 Cookie，不要只刷新界面。

### 7.2 “为什么打开的是终端？不能是 exe 吗？”

QuotaDock 是 PowerShell 7 + WinForms 写的 Windows 应用，安装器生成的桌面快捷方式会以隐藏窗口方式启动，所以日常使用不需要自己开终端。`QuotaDock-Setup-*.exe` 是安装包，不是便携版程序；关掉快捷方式启动的窗口，应用进程仍在后台运行。

### 7.3 “我关掉 Chrome 之后额度就不更新了”

说明用的是方式 C（页面桥接）。桥接模式只在页面打开时同步。想关浏览器也更新，改用方式 B 配置一次后台同步即可。

### 7.4 更新弹窗没有出现

启动时更新检查每 24 小时一次，且只有仓库里有更高版本时才提示。点击管理中心的 `↑ 检查更新` 会立即检查一次。调试时可以删除 `%LOCALAPPDATA%\QuotaDock\update_check.json` 再启动。

### 7.5 更新之后我的额度、凭证还在吗

在。所有用户数据都存在 `%LOCALAPPDATA%\QuotaDock`，更新只替换程序文件，不碰数据；卸载时也会保留这个目录。

### 7.6 进程列表里看到好几个更新检查进程

正常。更新检查是幂等的，多个并发检查不会互相冲突，也不会重复下载安装。

## 8. 维护者提醒

这份文档本身也是部署经验的沉淀：每次有新人按它部署并遇到新问题，就把现象、原因、解决办法补进来；同时把能自动规避问题的代码修复（例如启动器对商店版 PowerShell 的兜底）同步到仓库源码，让修复跟着下个版本一起发布。
