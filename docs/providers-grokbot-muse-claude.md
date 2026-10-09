# Grok Bot / Muse / Claude 内置平台

自 v0.2.4 起，这三个 id 进入 QuotaDock **内置目录**，安装更新后即可在中心勾选，无需再写入本机 `custom_providers.json`。

| Id | 标题 | 默认数据路径 | 同步 |
| --- | --- | --- | --- |
| `grokbot` | Grok Bot | `%LOCALAPPDATA%\QuotaDock\custom-data\grokbot.json` | 可选本地适配器 |
| `muse` | Muse | `%LOCALAPPDATA%\QuotaDock\custom-data\muse.json` | 可选本地适配器 |
| `claude` | Claude | `%LOCALAPPDATA%\QuotaDock\custom-data\claude.json` | 待接入（可选手写 JSON） |

## 数据约定

与自定义平台相同：写入 `windows[]`（通常 1 条周额度）、`remainingPercent`（0–100 剩余）、`resetText` / `updatedAt` / `syncStatus`。示例见 `examples/*quota.example.json`。

实时桌面 **不会** 回退展示仓库里的虚构示例百分比；没有快照时显示等待同步。

环境变量（可选覆盖路径）：

- `QUOTADOCK_GROKBOT_DATA`
- `QUOTADOCK_MUSE_DATA`
- `QUOTADOCK_CLAUDE_DATA`

也可在 `%LOCALAPPDATA%\QuotaDock\quota_sources.json` 使用 `grokbotPath` / `musePath` / `claudePath`。

## 同步与安全

- QuotaDock UI **只读**本地 JSON，不代替登录，不上传 Cookie / Token。
- Grok Bot：参见 `adapters/grokbot/`，从本机 Grok Bot / Cursor 登录态读取用量并写快照。
- Muse：参见 `adapters/muse/`，使用本机 DPAPI 保存的 Cookie，调用 Muse 订阅接口写快照。
- Claude：目前无内置同步脚本；可按 `docs/provider-adapter.md` 自行写适配器，或暂时只展示等待态。

切勿把 Cookie、Token、真实额度快照或个人绝对路径提交进仓库。

## 与自定义平台的关系

若升级前已在 `custom_providers.json` 注册过同名 id，内置定义优先；可从自定义列表中删除同名项以免混淆。品牌图安装包内位于 `assets\brand\`。
