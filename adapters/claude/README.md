# Claude 同步（待接入）

内置目录已注册 `claude`，默认读取：

`%LOCALAPPDATA%\QuotaDock\custom-data\claude.json`

当前 **没有** 官方/内置同步脚本。可按 `docs/provider-adapter.md` 自行实现：

1. 仅采集剩余百分比、重置文案、同步时间；
2. 原子写入上述 JSON；
3. 失败时保留上次成功窗口，勿把解析错误写成假 0%。

示例形状见 `examples/claude.quota.example.json`。
