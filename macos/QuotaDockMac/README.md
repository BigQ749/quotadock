# QuotaDock for macOS

这是 QuotaDock 的 macOS 原生预览版。它使用 AppKit + SwiftUI，不依赖 PowerShell、WinForms 或 Windows 路径；应用常驻菜单栏，并用一个可移动的浮动面板显示选中的额度卡片。

## 当前能力

- macOS 13 Ventura 或更新版本
- Apple Silicon 与 Intel Mac 均由同一 Swift Package 构建目标覆盖
- 菜单栏入口、单个/多个额度卡片选择、统一浮动面板、每 60 秒重新读取本地快照
- 支持 `providers.json` 的对象封装格式或数组格式
- 不读取 Cookie，不在仓库中保存凭据，不假装 Windows 同步脚本可以直接在 macOS 运行

## 本地数据

创建文件：

`~/Library/Application Support/QuotaDock/providers.json`

推荐格式：

```json
{
  "providers": [
    {
      "id": "codex",
      "title": "Codex",
      "badge": "周额度",
      "updatedAt": "2026-01-01T00:00:00Z",
      "lastSuccessAt": "2026-01-01T00:00:00Z",
      "syncStatus": "success",
      "lastError": null,
      "windows": [
        {
          "label": "周额度",
          "remainingPercent": 75,
          "resetText": "约 3 天后重置"
        }
      ]
    }
  ]
}
```

macOS 首个发行包先锁定“展示层 + 本地数据契约”。Codex、Grok、OpenCode Go 的真实账号同步适配器需要分别验证官方登录流程、权限和页面/接口变更后再接入；这避免把 Windows 专用路径或 Cookie 处理错误带到 Mac。

## 从源码构建

```bash
cd macos/QuotaDockMac
swift build -c release
.build/release/QuotaDock
```

发布包由 `packaging/macos/build_app.sh` 生成 `.app` 和 ZIP。GitHub Actions 会在 macOS runner 上构建，Windows 的 PowerShell/WinForms 发布链路保持独立。
