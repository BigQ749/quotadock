$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$helperPath = Join-Path $root 'quota_dock_paths.ps1'
if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw 'PATH_DISCOVERY_FAIL: shared path resolver is missing'
}

$fixtureRoot = Join-Path $env:TEMP ('quotadock-path-smoke-' + [Guid]::NewGuid().ToString('N'))
$appRoot = Join-Path $fixtureRoot 'codex项目集\token中转站\quota-fusion-desktop'
$codexPath = Join-Path $fixtureRoot 'codex-quota-desktop\codex_quota_fetch_loop.ps1'
$grokPath = Join-Path $fixtureRoot 'grok-weekly-quota-widget\monitor.py'

try {
    New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $codexPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $grokPath) -Force | Out-Null
    Set-Content -LiteralPath $codexPath -Value '# fixture' -Encoding UTF8
    Set-Content -LiteralPath $grokPath -Value '# fixture' -Encoding UTF8

    . $helperPath
    $resolvedCodex = Resolve-QuotaDockIntegrationPath -AppRoot $appRoot -RelativePath 'codex-quota-desktop\codex_quota_fetch_loop.ps1'
    $resolvedGrok = Resolve-QuotaDockIntegrationPath -AppRoot $appRoot -RelativePath 'grok-weekly-quota-widget\monitor.py'

    if ([System.IO.Path]::GetFullPath($resolvedCodex) -ne [System.IO.Path]::GetFullPath($codexPath)) {
        throw ('PATH_DISCOVERY_FAIL: Codex path mismatch: ' + $resolvedCodex)
    }
    if ([System.IO.Path]::GetFullPath($resolvedGrok) -ne [System.IO.Path]::GetFullPath($grokPath)) {
        throw ('PATH_DISCOVERY_FAIL: Grok path mismatch: ' + $resolvedGrok)
    }

    Write-Output 'PATH_DISCOVERY_SMOKE_PASS'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
