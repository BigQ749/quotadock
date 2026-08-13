$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$privacyPatterns = @(
    'Fe26\.[A-Za-z0-9._-]{20,}',
    'ghp_[A-Za-z0-9]{20,}',
    'github_pat_[A-Za-z0-9_]{20,}',
    'sk-[A-Za-z0-9]{20,}',
    'Bearer\s+[A-Za-z0-9._-]{20,}'
)
$scanFiles = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.FullName -notmatch '\\.git\\' -and $_.Extension -notin @('.png', '.ico') }
foreach ($pattern in $privacyPatterns) {
    $matches = Select-String -Path $scanFiles.FullName -Pattern $pattern -AllMatches -ErrorAction SilentlyContinue
    if ($matches) {
        throw ('PRIVACY_SCAN_FAIL pattern=' + $pattern + ' file=' + $matches[0].Path)
    }
}

function Invoke-QuotaDockSelfTest {
    param([string]$Script, [string[]]$Arguments)
    $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $Script) @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($Script + ' self-test failed:`n' + ($output -join "`n"))
    }
    $output
}

Invoke-QuotaDockSelfTest 'quota_center.ps1' @('-SelfTest')
Invoke-QuotaDockSelfTest 'quota_fusion_host.ps1' @('-SelfTest')
Invoke-QuotaDockSelfTest 'opencode_go_background_sync.ps1' @('-SelfTest')
Invoke-QuotaDockSelfTest 'check_for_updates.ps1' @('-SelfTest')

$centerSource = Get-Content -LiteralPath (Join-Path $root 'quota_center.ps1') -Raw -Encoding UTF8
$hostSource = Get-Content -LiteralPath (Join-Path $root 'quota_fusion_host.ps1') -Raw -Encoding UTF8
if ($centerSource -match 'ShowWithoutActivation') {
    throw 'REGRESSION_FAIL: center must not assign unsupported ShowWithoutActivation'
}
if ($hostSource -match 'ShowWithoutActivation') {
    throw 'REGRESSION_FAIL: host must not assign unsupported ShowWithoutActivation'
}
if ($hostSource -notmatch 'RemoveAt\(\$index\)') {
    throw 'REGRESSION_FAIL: fused-card removal must use an explicit ArrayList index'
}
if ($hostSource -notmatch 'Save-HostState\s*\r?\n\s*\$Form\.Close\(\)') {
    throw 'REGRESSION_FAIL: host state must be saved before closing the last card'
}
if ($hostSource -notmatch '\$closeCardMenu') {
    throw 'REGRESSION_FAIL: fused floaters must expose per-card close actions'
}
if ($hostSource -notmatch '\$wasFusedGroup') {
    throw 'REGRESSION_FAIL: fused-card removal must distinguish a merged host from a single host'
}
if ($hostSource -notmatch '\$remaining\.Count -eq 1 -and \$wasFusedGroup -and \$CloseCard') {
    throw 'REGRESSION_FAIL: final remaining card must be converted out of a merged host'
}
if ($hostSource -notmatch '\$script:ClosingForms\[\$Form\] = \$true') {
    throw 'REGRESSION_FAIL: merged-host conversion must protect the remaining card during FormClosed'
}
if ($centerSource -notmatch '\$updateButton\.Text' -or $centerSource -notmatch "'-Interactive'") {
    throw 'REGRESSION_FAIL: manual update check must be an explicit interactive action'
}
Write-Output 'QUOTADOCK_SELFTEST_PASS'
