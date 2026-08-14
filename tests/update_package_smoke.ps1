$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root 'update-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw -Encoding UTF8).Trim()
$repository = [Environment]::GetEnvironmentVariable('QUOTADOCK_UPDATE_REPO')
if ([string]::IsNullOrWhiteSpace($repository)) { $repository = 'BigQ749/quotadock' }
$packagePath = Join-Path $root ('dist\QuotaDock-v' + $version + '.zip')
if ([string]$manifest.version -ne $version) {
    throw ('更新清单版本不匹配: ' + $manifest.version + ' / ' + $version)
}
$expectedDownloadUrl = 'https://github.com/' + $repository + '/releases/download/v' + $version + '/QuotaDock-v' + $version + '.zip'
if ([string]$manifest.downloadUrl -ne $expectedDownloadUrl) {
    throw ('更新清单下载地址必须指向对应 Release 资产: ' + $manifest.downloadUrl)
}
if ([string]$manifest.downloadUrl -match 'raw\.githubusercontent\.com/.*/dist/') {
    throw '更新清单不能再指向源码仓库中的 dist 二进制包。'
}
if (-not (Test-Path -LiteralPath $packagePath)) {
    throw ('缺少直接更新包: ' + $packagePath)
}
if ([string]$manifest.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
    throw '更新清单缺少有效 SHA-256'
}
$actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne ([string]$manifest.sha256).ToLowerInvariant()) {
    throw ('更新包 SHA-256 不匹配: ' + $actualHash)
}
$inspectRoot = Join-Path $env:TEMP ('quotadock-package-smoke-' + $PID)
try {
    Expand-Archive -LiteralPath $packagePath -DestinationPath $inspectRoot -Force
    foreach ($name in @('quota_center.ps1', 'quota_fusion_host.ps1', 'check_for_updates.ps1', 'install_quota_update.ps1', 'VERSION')) {
        if (-not (Test-Path -LiteralPath (Join-Path $inspectRoot $name))) {
            throw ('更新包缺少运行文件: ' + $name)
        }
    }
    if (Test-Path -LiteralPath (Join-Path $inspectRoot 'opencode_go_live.json')) {
        throw '更新包不应包含本地 OpenCode 额度快照'
    }
    Write-Output ('UPDATE_PACKAGE_SMOKE_PASS version=' + $version + ' sha256=' + $actualHash)
}
finally {
    if (Test-Path -LiteralPath $inspectRoot) {
        Remove-Item -LiteralPath $inspectRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
