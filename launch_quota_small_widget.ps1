param(
    [string]$Provider,
    [switch]$SkipHost
)

$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostPath = Join-Path $root 'quota_fusion_host.ps1'
$sourceConfigPath = Join-Path $env:LOCALAPPDATA 'QuotaDock\quota_sources.json'
$powershell7 = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if ([string]::IsNullOrWhiteSpace($powershell7)) {
    $powershell7 = 'pwsh.exe'
}

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

function Get-QuotaDockSyncProcesses {
    param([string]$Pattern)
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
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

# 停掉旧版独立浮窗和旧大融合面板，避免新旧两套窗口同时存在
Get-CimInstance Win32_Process |
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
        $loopPath = 'D:\AI\codex-quota-desktop\codex_quota_fetch_loop.ps1'
    }
    $loop = Keep-One-QuotaDockSyncProcess '*codex_quota_fetch_loop.ps1*' $loopPath 'pwsh.exe'
    if ($null -eq $loop -and (Test-Path -LiteralPath $loopPath)) {
        Start-Process -FilePath $powershell7 -WindowStyle Hidden -WorkingDirectory (Split-Path -Parent $loopPath) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $loopPath)
    }
}
elseif ($Provider -eq 'grok') {
    $monitorPath = Resolve-ConfiguredPath 'QUOTADOCK_GROK_SYNC' 'grokSyncScript'
    if ([string]::IsNullOrWhiteSpace($monitorPath)) {
        $monitorPath = 'D:\grok-weekly-quota-widget\monitor.py'
    }
    $sync = Keep-One-QuotaDockSyncProcess '*grok-weekly-quota-widget*monitor.py*--sync-only*' $monitorPath 'pythonw.exe'
    $pythonCandidates = @(
        (Resolve-ConfiguredPath 'QUOTADOCK_PYTHONW' 'pythonwPath'),
        (Join-Path $env:LocalAppData 'Programs\Python\Python314\pythonw.exe'),
        (Join-Path $env:LocalAppData 'Programs\Python\Python313\pythonw.exe')
    )
    $pythonw = $pythonCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($null -eq $sync -and $null -ne $pythonw -and (Test-Path -LiteralPath $monitorPath)) {
        Start-Process -FilePath $pythonw -WindowStyle Hidden -WorkingDirectory (Split-Path -Parent $monitorPath) -ArgumentList @($monitorPath, '--sync-only')
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
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like '*opencode_go_browser_bridge.ps1*'
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        $sync = Keep-One-QuotaDockSyncProcess '*opencode_go_background_sync.ps1*' $backgroundPath 'pwsh.exe'
        if ($null -eq $sync -and (Test-Path -LiteralPath $backgroundPath)) {
            Start-Process -FilePath $powershell7 -WindowStyle Hidden -WorkingDirectory $root -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backgroundPath, '-IntervalSeconds', '60')
        }
    }
    else {
        Get-CimInstance Win32_Process |
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
