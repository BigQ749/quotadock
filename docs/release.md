# 发布流程

## 发布前

1. 修改 `VERSION`，保持 `MAJOR.MINOR.PATCH` 三段式；本机正在使用的安装目录也要同步这个版本。
2. 运行 `packaging/build_update_package.ps1 -Clean`，它会在本机 `dist` 生成临时版本化 ZIP、计算 SHA-256，并生成指向对应 GitHub Release 的 `update-manifest.json`。`dist` 目录不提交到源码分支。
3. 运行 `tests/selftest.ps1`。
4. 做隐私扫描：仓库中不得出现 Cookie、令牌、真实额度快照、个人绝对路径或包含桌面的截图。
5. `packaging/QuotaDock.iss` 会由 `packaging/build.ps1` 从 `VERSION` 临时生成版本定义，不要再手工维护第二个版本号。
6. 确认 `docs/releases/vX.Y.Z.md` 已写清修复、已知边界和下载文件。

如果本机已经拉取过 Release 后的 `main`，更新清单里的 SHA-256 代表 GitHub runner 上传的真实 ZIP；不同机器重新压缩出的本地 ZIP 可能因文件时间元数据不同而哈希不同。`selftest.ps1` 会检查本地包内容并提示差异，Release workflow 则会在上传前强制要求清单哈希与 runner 生成的 ZIP 完全一致。

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

tag 触发 `.github/workflows/release.yml`。Windows runner 先生成直接更新 ZIP 和清单，再使用 Inno Setup 生成安装器和 SHA-256 校验文件，把发行文件附加到 GitHub Release，最后把“实际上传 ZIP 的哈希”和 Release 下载地址回写到 `main/update-manifest.json`。这样更新器校验的是 Release 里的真实文件，不依赖源码分支中的二进制副本。

Release 标题使用“QuotaDock X.Y.Z · Windows + macOS”格式；版本说明放在 `docs/releases/vX.Y.Z.md`，不要使用没有上下文的自动生成标题。工作流会先构建并发布 Windows 资产，再在 macOS runner 上构建并把 `QuotaDock-macOS-vX.Y.Z.zip` 附加到同一 Release。macOS 预览版的账号同步边界必须在版本说明中明确写出。

## 为什么 `main` 不保存旧下载包

安装器、便携 ZIP 和校验文件是发行资产，不是源码。旧版本仍保留在 GitHub Releases，方便回退；源码分支只保留构建脚本、文档和当前更新清单，避免每次迭代都把多个 1–2 MB 的 ZIP 带进代码下载和 Git 历史。不要为清理历史直接重写公共仓库；如果将来确实需要压缩 Git 历史，应另行备份并单独确认。

## 回滚

如果新版本启动失败，不要覆盖用户数据目录；发布一个更高的修复版本。用户可以从旧 Release 下载旧安装器，`%LOCALAPPDATA%\QuotaDock` 中的配置与数据不会随卸载删除。
