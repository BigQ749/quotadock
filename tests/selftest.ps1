$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$powershellCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $powershellCommand -or [string]::IsNullOrWhiteSpace($powershellCommand.Source)) {
    throw 'SELFTEST_ENV_FAIL: PowerShell 7+（pwsh.exe）未找到。'
}
$powershell = $powershellCommand.Source
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw ('SELFTEST_ENV_FAIL: 必须使用 PowerShell 7+，当前为 ' + $PSVersionTable.PSVersion)
}

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
$launcherSource = (Get-ChildItem -LiteralPath $root -Filter 'launch_*.vbs' -File | Get-Content -Raw) -join "`n"
if ($centerSource -notmatch 'Resolve-QuotaDockPowerShell' -or $centerSource -notmatch 'pwsh\.exe') {
    throw 'REGRESSION_FAIL: QuotaDock must resolve and launch PowerShell 7+ via pwsh.exe'
}
if ($launcherSource -match 'WindowsPowerShell|powershell\.exe' -or $launcherSource -notmatch 'PowerShell\\7\\pwsh\.exe') {
    throw 'REGRESSION_FAIL: VBS launchers must use PowerShell 7+ and must not default to Windows PowerShell 5.1'
}
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
if ($centerSource -match '\$providers\.ContainsKey') {
    throw 'REGRESSION_FAIL: ordered provider registry must use Keys -contains, not ContainsKey'
}
if ($centerSource -notmatch '\$script:UpdateResultPath' -or $centerSource -notmatch 'Sync-UpdateCheckState') {
    throw 'REGRESSION_FAIL: manual update check must return and display a result'
}
if ($centerSource -notmatch 'System\.Drawing\.Size\(340, 0\)' -or $centerSource -notmatch "New-UiFont 'Microsoft YaHei UI' 16") {
    throw 'REGRESSION_FAIL: center context menus must use the enlarged menu scale'
}
if ($centerSource -notmatch '已打开' -or $centerSource -notmatch '已关闭') {
    throw 'REGRESSION_FAIL: provider actions must expose completion status'
}
if ($hostSource -notmatch 'System\.Drawing\.Size\(340, 0\)' -or $hostSource -notmatch "New-HostFont 'Microsoft YaHei UI' 16") {
    throw 'REGRESSION_FAIL: floater context menu must use the enlarged menu scale'
}
Write-Output 'QUOTADOCK_SELFTEST_PASS'
