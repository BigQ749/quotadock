# macOS 版本说明

QuotaDock 的 macOS 版本不是把 Windows 的 PowerShell/WinForms 文件改名后运行，而是单独的原生 AppKit + SwiftUI 目标：

```text
macOS 菜单栏
      |
      v
QuotaDock.app / NSPanel 浮动面板
      |
      v
~/Library/Application Support/QuotaDock/providers.json
```

## 下载与启动

在 GitHub Release 下载 `QuotaDock-macOS-v0.2.1.zip`，解压后把 `QuotaDock.app` 拖入“应用程序”。当前已发布包是在 macOS 14 arm64 runner 上真实构建并验证的 Apple Silicon 版本，要求 macOS 13 或更高版本；Intel x86_64 构建尚未发布。

当前包未做 Apple Developer ID 签名和公证，因此第一次打开可能需要在“系统设置 → 隐私与安全性”确认允许。不要从不明镜像下载，也不要绕过系统安全提示运行被修改过的副本。

## 数据文件

macOS 版只读取：

`~/Library/Application Support/QuotaDock/providers.json`

它支持对象封装：

```json
{
  "providers": [
    {
      "id": "opencode",
      "title": "OpenCode Go",
      "badge": "5 小时 / 周 / 月",
      "updatedAt": "2026-01-01T00:00:00Z",
      "lastSuccessAt": "2026-01-01T00:00:00Z",
      "syncStatus": "success",
      "lastError": null,
      "windows": [
        { "label": "5 小时", "remainingPercent": 100, "resetText": "约 5 小时后重置" },
        { "label": "周", "remainingPercent": 88, "resetText": "约 3 天后重置" },
        { "label": "月", "remainingPercent": 72, "resetText": "约 20 天后重置" }
      ]
    }
  ]
}
```

也可以直接写成上述 `providers` 数组。`remainingPercent` 必须是 0–100 的“剩余额度”，`lastSuccessAt` 和 `updatedAt` 应来自最近一次成功同步；同步失败时应保留原来的成功数据并填写 `lastError`。

## 当前边界

- macOS 预览版已经覆盖菜单栏、浮动面板、多平台选择、每 60 秒重读本地快照和清晰的同步状态。
- Codex、Grok、OpenCode Go 的真实账号同步适配器尚未在 macOS 上承诺完成。Windows 的 DPAPI、Chrome 扩展桥接、PowerShell 路径和本机凭据不可直接复制到 Mac。
- 当前发布包未签名/未公证；正式分发前还需要 Developer ID、Notarization、自动更新和真实三平台同步的独立验收。

这条边界是有意保留的：展示层先可运行，账号和凭据层再逐个平台验证，避免把 Cookie 或未经验证的接口逻辑写进跨平台发行包。
