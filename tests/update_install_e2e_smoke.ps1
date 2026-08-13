$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $root 'update-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$packagePath = Join-Path $root ('dist\QuotaDock-v' + [string]$manifest.version + '.zip')
$hash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
$targetRoot = Join-Path $env:TEMP ('quotadock-install-e2e-' + [guid]::NewGuid().ToString('N'))
try {
    Expand-Archive -LiteralPath $packagePath -DestinationPath $targetRoot -Force
    Set-Content -LiteralPath (Join-Path $targetRoot 'VERSION') -Value '0.1.2' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $targetRoot 'opencode_go_live.json') -Value '{"smoke":"preserve"}' -Encoding UTF8
    $output = & (Get-Command pwsh.exe).Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $targetRoot 'install_quota_update.ps1') `
        -PackagePath $packagePath `
        -ExpectedSha256 $hash `
        -TargetVersion ([string]$manifest.version) `
        -InstallRoot $targetRoot 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('本地替换执行失败：' + ($output -join "`n"))
    }
    $installedVersion = (Get-Content -LiteralPath (Join-Path $targetRoot 'VERSION') -Raw -Encoding UTF8).Trim()
    if ($installedVersion -ne [string]$manifest.version) {
        throw ('替换后版本错误：' + $installedVersion)
    }
    $preserved = Get-Content -LiteralPath (Join-Path $targetRoot 'opencode_go_live.json') -Raw -Encoding UTF8
    if ($preserved -notmatch 'preserve') {
        throw '更新不应覆盖本地额度快照'
    }
    Write-Output ('UPDATE_INSTALL_E2E_SMOKE_PASS version=' + $installedVersion + ' local-data=preserved')
}
finally {
    if (Test-Path -LiteralPath $targetRoot) {
        Remove-Item -LiteralPath $targetRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
