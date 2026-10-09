# Grok Bot 同步适配器

将 Cursor Grok Bot 周用量写入 `%LOCALAPPDATA%\QuotaDock\custom-data\grokbot.json`。

## 依赖

- Windows + Python 3.10+
- `pip install cryptography`（解密 Grok Bot `sand-secrets` / OSCrypt）

## 运行

```powershell
python .\monitor.py --sync-once
# 或常驻轮询
pythonw .\monitor.py --sync-only
```

可选环境变量：

- `QUOTADOCK_GROKBOT_DATA`：输出 JSON 路径
- `QUOTADOCK_GROKBOT_POLL_SEC`：轮询间隔（默认 60）

脚本优先读取 `%APPDATA%\Grok Bot\` 登录态，失败时回退 Cursor IDE `state.vscdb`。不会打印 Token。
