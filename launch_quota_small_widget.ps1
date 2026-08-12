param(
    [string]$Provider,
    [switch]$SkipHost
)

$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostPath = Join-Path $root 'quota_fusion_host.ps1'
$sourceConfigPath = Join-Path $env:LOCALAPPDATA 'QuotaDock\quota_sources.json'

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

# 停掉旧版独立浮窗和旧大融合面板，避免新旧两套窗口同时存在
Get-CimInstance Win32_Process |
    Where-Object {
        $_.ProcessId -ne $PID -and $_.Name -eq 'powershell.exe' -and
        ($_.CommandLine -like '*quota_small_widget.ps1*' -or $_.CommandLine -like '*quota_fusion_desktop.ps1*') -and
        $_.CommandLine -notlike '*launch_quota_small_widget.ps1*' -and
        $_.CommandLine -notlike '*quota_fusion_host.ps1*'
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if ($Provider -eq 'codex') {
    $loopPath = Resolve-ConfiguredPath 'QUOTADOCK_CODEX_SYNC' 'codexSyncScript'
    $loop = Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -like '*codex_quota_fetch_loop.ps1*' } |
        Select-Object -First 1
    if ($null -eq $loop -and (Test-Path -LiteralPath $loopPath)) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $loopPath)
    }
}
elseif ($Provider -eq 'grok') {
    $monitorPath = Resolve-ConfiguredPath 'QUOTADOCK_GROK_SYNC' 'grokSyncScript'
    $sync = Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -like '*grok-weekly-quota-widget*monitor.py*--sync-only*' } |
        Select-Object -First 1
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
    $credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'QuotaDock\opencode_go_credentials.json'
    $backgroundPath = Join-Path $root 'opencode_go_background_sync.ps1'
    if (Test-Path -LiteralPath $credentialPath) {
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like '*opencode_go_browser_bridge.ps1*'
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        $sync = Get-CimInstance Win32_Process |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like '*opencode_go_background_sync.ps1*'
            } |
            Select-Object -First 1
        if ($null -eq $sync -and (Test-Path -LiteralPath $backgroundPath)) {
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backgroundPath)
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
        $bridge = Get-CimInstance Win32_Process |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like '*opencode_go_browser_bridge.ps1*'
            } |
            Select-Object -First 1
        if ($null -eq $bridge -and (Test-Path -LiteralPath $bridgePath)) {
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bridgePath)
        }
    }
}

if (-not $SkipHost -and (Test-Path -LiteralPath $hostPath)) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hostPath, '-Provider', $Provider)
}
