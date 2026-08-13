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
Invoke-QuotaDockSelfTest 'install_quota_update.ps1' @('-SelfTest')
Invoke-QuotaDockSelfTest 'tests/floater_menu_smoke.ps1' @()
Invoke-QuotaDockSelfTest 'tests/update_package_smoke.ps1' @()
Invoke-QuotaDockSelfTest 'tests/update_install_e2e_smoke.ps1' @()

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
if ($centerSource -notmatch '\$script:UpdateResultConsumed' -or $centerSource -notmatch 'Consume the result before showing') {
    throw 'REGRESSION_FAIL: update results must be consumed before showing a modal result'
}
if ($centerSource -notmatch 'Start-QuotaDockLocalUpdate' -or
    $centerSource -notmatch 'install_quota_update\.ps1' -or
    $centerSource -match 'Start-Process \$releaseUrl') {
    throw 'REGRESSION_FAIL: update result must start the local verified installer, not open a release page'
}
if ($centerSource -match '\$nameLabel\.Add_Click' -or
    $centerSource -match '\$descriptionLabel\.Add_Click' -or
    $centerSource -match '\$toggle\.Add_Click') {
    throw 'REGRESSION_FAIL: provider right-click controls must not use Click handlers that can toggle state'
}
if ($centerSource -notmatch '\$nameLabel\.Add_MouseDown' -or
    $centerSource -notmatch '\$descriptionLabel\.Add_MouseDown' -or
    $centerSource -notmatch '\$toggle\.Add_MouseDown') {
    throw 'REGRESSION_FAIL: provider left-click behavior must be explicit MouseDown handlers'
}
if ($centerSource -match '\$menu\.Add_Closed\s*\(\{\s*\$menu\.Dispose') {
    throw 'REGRESSION_FAIL: provider menus must not dispose themselves during Closed'
}
if ($centerSource -notmatch 'Get-Process -Id \$hostPid' -or $centerSource -match 'Get-CimInstance Win32_Process -Filter') {
    throw 'REGRESSION_FAIL: runtime polling must avoid WMI command-line inspection on the UI timer'
}
if ($hostSource -notmatch '\$script:LastHostStateWriteAt' -or $hostSource -notmatch '\$script:CustomProvidersLastWriteUtc') {
    throw 'REGRESSION_FAIL: host polling must throttle state writes and cache custom-provider imports'
}
if ($centerSource -notmatch 'System\.Drawing\.Size\(340, 0\)' -or $centerSource -notmatch "New-UiFont 'Microsoft YaHei UI' 16") {
    throw 'REGRESSION_FAIL: center context menus must use the enlarged menu scale'
}
if ($centerSource -notmatch '已打开' -or $centerSource -notmatch '已关闭') {
    throw 'REGRESSION_FAIL: provider actions must expose completion status'
}
if ($hostSource -notmatch 'System\.Drawing\.Size\(380, 0\)' -or $hostSource -notmatch "New-HostFont 'Microsoft YaHei UI' 17") {
    throw 'REGRESSION_FAIL: floater context menu must use the enlarged menu scale'
}
if ($centerSource -notmatch '\$menuText = \[System\.Drawing\.Color\]::FromArgb\(239, 243, 249\)' -or
    $centerSource -notmatch '\$item\.ForeColor = \$menuText') {
    throw 'REGRESSION_FAIL: center context menu items must explicitly use a readable light foreground'
}
if ($hostSource -notmatch '\$formCardsMap = \$script:FormCards' -or
    $hostSource -notmatch '\$cards = @\(\$formCardsMap\[\$owner\]\)') {
    throw 'REGRESSION_FAIL: floater context menu must capture host state for WinForms callbacks'
}
if ($hostSource -notmatch '\$state\.ContextMenuHold = \$true' -or
    $hostSource -notmatch 'ContextMenuHold = \$false' -or
    $hostSource -notmatch 'ContextMenuOpen = \$false') {
    throw 'REGRESSION_FAIL: floater right-click must hold the revealed window open'
}
$updateSource = Get-Content -LiteralPath (Join-Path $root 'check_for_updates.ps1') -Raw -Encoding UTF8
if ($updateSource -notmatch 'Get-LatestReleaseFromVersionFile' -or
    $updateSource -notmatch 'raw\.githubusercontent\.com') {
    throw 'REGRESSION_FAIL: update checks must fall back when the GitHub API is rate-limited'
}
if ($updateSource -notmatch 'Get-LatestReleaseFromManifest' -or
    $updateSource -notmatch 'download_url' -or
    $updateSource -notmatch 'sha256') {
    throw 'REGRESSION_FAIL: update checks must read a direct package manifest and SHA-256'
}
if ($centerSource -notmatch 'GitHub 更新接口暂时限流') {
    throw 'REGRESSION_FAIL: rate-limit update results must use a non-error informational message'
}
$launcherSource = Get-Content -LiteralPath (Join-Path $root 'launch_quota_small_widget.ps1') -Raw -Encoding UTF8
if ($hostSource -notmatch 'D:\\AI\\codex-quota-desktop\\codex_quota_live\.json' -or
    $hostSource -notmatch 'D:\\grok-weekly-quota-widget\\data\.json' -or
    $hostSource -notmatch 'opencode_go_live\.json') {
    throw 'REGRESSION_FAIL: live provider paths must be explicit fallbacks, not example data'
}
if ($hostSource -notmatch 'Get-ActiveQuotaDataPath' -or
    $hostSource -notmatch 'ExplicitDataSources') {
    throw 'REGRESSION_FAIL: host must refresh the active local data path without overriding explicit configuration'
}
if ($hostSource -notmatch '数据已过期' -or
    $hostSource -notmatch '同步失败' -or
    $hostSource -notmatch 'last_success_at') {
    throw 'REGRESSION_FAIL: provider status must distinguish stale data and failed attempts'
}
if ($launcherSource -notmatch 'Keep-One-QuotaDockSyncProcess' -or
    $launcherSource -notmatch 'Sort-Object CreationDate, ProcessId') {
    throw 'REGRESSION_FAIL: provider launch must collapse duplicate sync processes'
}
$backgroundSource = Get-Content -LiteralPath (Join-Path $root 'opencode_go_background_sync.ps1') -Raw -Encoding UTF8
if ($backgroundSource -notmatch 'Write-QuotaFailureState' -or
    $backgroundSource -notmatch 'QuotaDockOpenCodeGoWriteMutex' -or
    $backgroundSource -notmatch 'QuotaFusionDesktop\\opencode_go_credentials') {
    throw 'REGRESSION_FAIL: OpenCode background sync must expose failure state and use a single writer lock'
}
if ($centerSource -notmatch "ValidateSet\('add', 'close', 'remove', 'refresh', 'shutdown'\)" -or
    $centerSource -notmatch 'Stop-QuotaDockHost' -or
    $centerSource -notmatch 'Stop-QuotaDockSyncProcesses') {
    throw 'REGRESSION_FAIL: full QuotaDock exit must shut down the host and owned sync processes'
}
if ($hostSource -notmatch 'function Refresh-CardModels' -or
    $hostSource -notmatch 'function Shutdown-Host' -or
    $hostSource -notmatch "\$action -eq 'shutdown'" -or
    $hostSource -notmatch "\$action -eq 'refresh'") {
    throw 'REGRESSION_FAIL: host must handle refresh and shutdown requests'
}
if ($backgroundSource -notmatch 'Request-HostRefresh' -or
    $backgroundSource -notmatch "refresh\|opencode") {
    throw 'REGRESSION_FAIL: OpenCode background writes must request an immediate host repaint'
}
$bridgeSource = Get-Content -LiteralPath (Join-Path $root 'opencode_go_browser_bridge.ps1') -Raw -Encoding UTF8
if ($bridgeSource -notmatch 'Request-HostRefresh' -or
    $bridgeSource -notmatch "refresh\|opencode") {
    throw 'REGRESSION_FAIL: OpenCode browser bridge writes must request an immediate host repaint'
}
Write-Output 'QUOTADOCK_SELFTEST_PASS'
