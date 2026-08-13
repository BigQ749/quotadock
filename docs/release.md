# 发布流程

## 发布前

1. 修改 `VERSION`，保持 `MAJOR.MINOR.PATCH` 三段式。
2. 运行 `tests/selftest.ps1`。
3. 做隐私扫描：仓库中不得出现 Cookie、令牌、真实额度快照、个人绝对路径或包含桌面的截图。
4. 确认 `packaging/QuotaDock.iss` 中的版本与 `VERSION` 一致。
5. 确认 `docs/releases/vX.Y.Z.md` 已写清修复、已知边界和下载文件。

## 发布

```powershell
$PSVersionTable.PSVersion
$version = (Get-Content .\VERSION -Raw).Trim()
git add .
git commit -m "release: v$version"
git tag "v$version"
git push origin main
git push origin "v$version"
```

tag 触发 `.github/workflows/release.yml`。Windows runner 安装 Inno Setup，生成安装器和 SHA-256 校验文件，并把它们附加到 GitHub Release。

Release 标题使用“QuotaDock X.Y.Z · Windows 首发”格式；版本说明放在 `docs/releases/vX.Y.Z.md`，不要使用没有上下文的自动生成标题。当前仓库只发布实际支持的 Windows 构建，Mac/Linux/ARM64 在没有真实构建和验收前不放下载链接。

## 回滚

如果新版本启动失败，不要覆盖用户数据目录；发布一个更高的修复版本。用户可以从旧 Release 下载旧安装器，`%LOCALAPPDATA%\QuotaDock` 中的配置与数据不会随卸载删除。
