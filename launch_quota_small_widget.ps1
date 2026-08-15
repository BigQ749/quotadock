param(
    [string]$Provider,
    [switch]$SkipHost,
    [switch]$Once
)

$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:IntegrationRoot = Split-Path -Parent $root
$pathResolverPath = Join-Path $root 'quota_dock_paths.ps1'
if (-not (Test-Path -LiteralPath $pathResolverPath -PathType Leaf)) {
    throw ('缺少共享路径解析器：' + $pathResolverPath)
}
. $pathResolverPath
$hostPath = Join-Path $root 'quota_fusion_host.ps1'
$sourceConfigPath = Join-Path $env:LOCALAPPDATA 'QuotaDock\quota_sources.json'
$powershell7 = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if ([string]::IsNullOrWhiteSpace($powershell7)) {
    $powershell7 = 'pwsh.exe'
}

# One WMI snapshot per launcher run. A full Win32_Process enumeration costs
# roughly half a second, and startup previously repeated it for every check.
$script:ProcessSnapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)

function Read-QuotaDockSourceConfig {
    if (-not (Test-Path -LiteralPath $sourceConfigPath)) {
        return [pscustomobject]@{}
    }
    try {
        return Get-Content -LiteralPath $sourceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{}
    }
}

function Resolve-ConfiguredPath {
    param([string]$EnvironmentName, [string]$ConfigName)
    $value = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ([string]::IsNullOrWhiteSpace($value)) {
        $config = Read-QuotaDockSourceConfig
        $property = $config.PSObject.Properties[$ConfigName]
        if ($null -ne $property) {
            $value = [string]$property.Value
        }
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ''
    }
    return [Environment]::ExpandEnvironmentVariables($value.Trim())
}

function Get-QuotaDockSiblingIntegrationPath {
    param([string]$RelativePath)
    $resolved = Resolve-QuotaDockIntegrationPath -AppRoot $root -RelativePath $RelativePath
    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
        return $resolved
    }
    $candidates = @(Get-QuotaDockIntegrationCandidates -AppRoot $root -RelativePath $RelativePath)
    if ($candidates.Count -gt 0) {
        return [string]$candidates[0]
    }
    return ''
}

function Get-QuotaDockSyncProcesses {
    param([string]$Pattern)
    return @($script:ProcessSnapshot |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.Name -in @('pwsh.exe', 'powershell.exe', 'python.exe', 'pythonw.exe') -and
            [string]$_.CommandLine -like $Pattern
        } |
        Sort-Object CreationDate, ProcessId)
}

function Keep-One-QuotaDockSyncProcess {
    param(
        [string]$Pattern,
        [string]$ScriptPath,
        [string]$ExpectedProcessName
    )
    $items = @(Get-QuotaDockSyncProcesses $Pattern)
    $valid = New-Object System.Collections.ArrayList
    $lastWriteUtc = if (Test-Path -LiteralPath $ScriptPath -PathType Leaf) {
        (Get-Item -LiteralPath $ScriptPath).LastWriteTimeUtc
    }
    foreach ($item in $items) {
        $isCurrent = ($ExpectedProcessName -eq '' -or [string]$item.Name -eq $ExpectedProcessName)
        if ($isCurrent -and $null -ne $lastWriteUtc) {
            try {
                $startUtc = (Get-Process -Id ([int]$item.ProcessId) -ErrorAction Stop).StartTime.ToUniversalTime()
                $isCurrent = $startUtc -ge $lastWriteUtc
            }
            catch {
                $isCurrent = $false
            }
        }
        if ($isCurrent) {
            [void]$valid.Add($item)
        }
        else {
            Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
    if ($valid.Count -gt 1) {
        foreach ($extra in @($valid | Select-Object -Skip 1)) {
            Stop-Process -Id ([int]$extra.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
    if ($valid.Count -gt 0) {
        return $valid[0]
    }
    return $null
}

function Test-ScriptSupportsOnce {
    param(
        [string]$Path,
        [string]$Marker
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) -match $Marker
    }
    catch {
        return $false
    }
}

# 停掉旧版独立浮窗和旧大融合面板，避免新旧两套窗口同时存在
$script:ProcessSnapshot |
    Where-Object {
        $_.ProcessId -ne $PID -and $_.Name -in @('pwsh.exe', 'powershell.exe') -and
        ($_.CommandLine -like '*quota_small_widget.ps1*' -or $_.CommandLine -like '*quota_fusion_desktop.ps1*') -and
        $_.CommandLine -notlike '*launch_quota_small_widget.ps1*' -and
        $_.CommandLine -notlike '*quota_fusion_host.ps1*'
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if ($Provider -eq 'codex') {
    $loopPath = Resolve-ConfiguredPath 'QUOTADOCK_CODEX_SYNC' 'codexSyncScript'
    if ([string]::IsNullOrWhiteSpace($loopPath)) {
        $loopPath = Get-QuotaDockSiblingIntegrationPath 'codex-quota-desktop\codex_quota_fetch_loop.ps1'
    }
    $supportsOnce = $Once -and (Test-ScriptSupportsOnce $loopPath '\[switch\]\$Once')
    if ($supportsOnce) {
        Start-Process -FilePath $powershell7 -WindowStyle Hidden -WorkingDirectory (Split-Path -Parent $loopPath) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $loopPath, '-Once')
    }
    else {
        # Older sibling integrations are kept compatible: fall back to their
        # original resident mode instead of passing an unsupported parameter.
        $loop = Keep-One-QuotaDockSyncProcess '*codex_quota_fetch_loop.ps1*' $loopPath 'pwsh.exe'
        if ($null -eq $loop -and (Test-Path -LiteralPath $loopPath)) {
            Start-Process -FilePath $powershell7 -WindowStyle Hidden -WorkingDirectory (Split-Path -Parent $loopPath) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $loopPath)
        }
    }
}
elseif ($Provider -eq 'grok') {
    $monitorPath = Resolve-ConfiguredPath 'QUOTADOCK_GROK_SYNC' 'grokSyncScript'
    if ([string]::IsNullOrWhiteSpace($monitorPath)) {
        $monitorPath = Get-QuotaDockSiblingIntegrationPath 'grok-weekly-quota-widget\monitor.py'
    }
    $supportsOnce = $Once -and (Test-ScriptSupportsOnce $monitorPath '--sync-once')
    $pythonCandidates = @(
        (Resolve-ConfiguredPath 'QUOTADOCK_PYTHONW' 'pythonwPath'),
        (Join-Path $env:LocalAppData 'Programs\Python\Python314\pythonw.exe'),
        (Join-Path $env:LocalAppData 'Programs\Python\Python313\pythonw.exe')
    )
    $pythonw = $pythonCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($null -ne $pythonw -and (Test-Path -LiteralPath $monitorPath)) {
        if ($supportsOnce) {
            Start-Process -FilePath $pythonw -WindowStyle Hidden -WorkingDirectory (Split-Path -Parent $monitorPath) -ArgumentList @($monitorPath, '--sync-once')
        }
        else {
            $sync = Keep-One-QuotaDockSyncProcess '*grok-weekly-quota-widget*monitor.py*--sync-only*' $monitorPath 'pythonw.exe'
            if ($null -eq $sync) {
                Start-Process -FilePath $pythonw -WindowStyle Hidden -WorkingDirectory (Split-Path -Parent $monitorPath) -ArgumentList @($monitorPath, '--sync-only')
            }
        }
    }
}
elseif ($Provider -eq 'opencode') {
    $credentialCandidates = @(
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'QuotaDock\opencode_go_credentials.json'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'QuotaFusionDesktop\opencode_go_credentials.json')
    )
    $credentialPath = $credentialCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    $backgroundPath = Join-Path $root 'opencode_go_background_sync.ps1'
    if (Test-Path -LiteralPath $credentialPath) {
        $script:ProcessSnapshot |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like '*opencode_go_browser_bridge.ps1*'
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        $supportsOnce = $Once -and (Test-ScriptSupportsOnce $backgroundPath '\[switch\]\$Once')
        if ($supportsOnce) {
            Start-Process -FilePath $powershell7 -WindowStyle Hidden -WorkingDirectory $root -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backgroundPath, '-Once')
        }
        else {
            $sync = Keep-One-QuotaDockSyncProcess '*opencode_go_background_sync.ps1*' $backgroundPath 'pwsh.exe'
            if ($null -eq $sync -and (Test-Path -LiteralPath $backgroundPath)) {
                Start-Process -FilePath $powershell7 -WindowStyle Hidden -WorkingDirectory $root -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backgroundPath, '-IntervalSeconds', '60')
            }
        }
    }
    else {
        $script:ProcessSnapshot |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like '*opencode_go_background_sync.ps1*'
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        $bridgePath = Join-Path $root 'opencode_go_browser_bridge.ps1'
        $bridge = Keep-One-QuotaDockSyncProcess '*opencode_go_browser_bridge.ps1*' $bridgePath 'pwsh.exe'
        if ($null -eq $bridge -and (Test-Path -LiteralPath $bridgePath)) {
            Start-Process -FilePath $powershell7 -WindowStyle Hidden -WorkingDirectory $root -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bridgePath)
        }
    }
}

if (-not $SkipHost -and (Test-Path -LiteralPath $hostPath)) {
    Start-Process pwsh.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hostPath, '-Provider', $Provider)
}
