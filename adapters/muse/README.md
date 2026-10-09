# Muse 同步适配器

将 Muse.ai 周用量写入 `%LOCALAPPDATA%\QuotaDock\custom-data\muse.json`。

## 凭证

在 `%LOCALAPPDATA%\QuotaDock\muse_credentials.json` 存放 **当前用户 DPAPI** 加密后的 Cookie 字段 `cookieDpapi`（Base64）。不要明文保存 Cookie，也不要提交该文件。

可用任意本机小工具调用 `CryptProtectData` 生成；QuotaDock 仓库不包含凭证写入器。

## 运行

```powershell
python .\monitor.py --once
python .\monitor.py --loop
```

脚本会调用 Muse 页面的 `fetchSubscriptionAction`（Next-Action），并在 `%LOCALAPPDATA%\QuotaDock\muse-sync-state.json` 缓存 action id。失败时保留上一份有效额度窗口。
