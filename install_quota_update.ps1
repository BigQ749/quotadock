param(
    [string]$PackageUrl = '',
    [string]$PackagePath = '',
    [string]$ExpectedSha256 = '',
    [string]$TargetVersion = '',
    [string]$InstallRoot = '',
    [int]$ParentPid = 0,
    [int]$CloseProcessId = 0,
    [switch]$RestartCenter,
    [string]$CenterScript = 'quota_center.ps1',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$scriptPath = $MyInvocation.MyCommand.Path
$scriptRoot = Split-Path -Parent $scriptPath
$powershell = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$updateLog = Join-Path $env:TEMP 'quotadock-update.log'
$failureLog = Join-Path $env:TEMP 'quotadock-update-error.log'

function Write-UpdateLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $updateLog -Value ((Get-Date).ToString('o') + ' ' + $Message) -Encoding UTF8
    }
    catch {
    }
}

function Wait-QuotaDockProcessExit {
    param(
        [int]$ProcessId,
        [int]$TimeoutSeconds = 30,
        [switch]$ForceAfterTimeout
    )
    if ($ProcessId -le 0 -or $ProcessId -eq $PID) {
        return
    }
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    if ($ForceAfterTimeout) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }
}

function Close-QuotaDockProcess {
    param([int]$ProcessId)
    if ($ProcessId -le 0 -or $ProcessId -eq $PID) {
        return
    }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return
    }
    try {
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            [void]$process.CloseMainWindow()
        }
    }
    catch {
    }
    $deadline = [datetime]::UtcNow.AddSeconds(8)
    while ([datetime]::UtcNow -lt $deadline) {
        if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
}

function Stop-QuotaDockHostProcesses {
    param([string]$Root)
    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and
        $_.Name -in @('pwsh.exe', 'powershell.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
        ([string]$_.CommandLine -like '*quota_fusion_host.ps1*') -and
        ([string]$_.CommandLine -like ('*' + $normalizedRoot + '*'))
    })
    foreach ($entry in $processes) {
        Write-UpdateLog ('stop host pid=' + $entry.ProcessId)
        Stop-Process -Id ([int]$entry.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    foreach ($entry in $processes) {
        Wait-QuotaDockProcessExit ([int]$entry.ProcessId) 10
    }
}

function Resolve-PackageRoot {
    param([string]$ExtractRoot)
    $required = @('quota_center.ps1', 'quota_fusion_host.ps1', 'VERSION', 'install_quota_update.ps1')
    $direct = $true
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $ExtractRoot $name))) {
            $direct = $false
            break
        }
    }
    if ($direct) {
        return $ExtractRoot
    }
    $directories = @(Get-ChildItem -LiteralPath $ExtractRoot -Directory -Force)
    foreach ($directory in $directories) {
        $candidate = $directory.FullName
        if (($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $candidate $_)) }).Count -eq 0) {
            return $candidate
        }
    }
    throw '更新包结构无效：找不到 QuotaDock 运行文件。'
}

function Copy-QuotaDockTree {
    param([string]$SourceRoot, [string]$DestinationRoot)
    foreach ($entry in @(Get-ChildItem -LiteralPath $SourceRoot -Force)) {
        $destination = Join-Path $DestinationRoot $entry.Name
        if ($entry.PSIsContainer) {
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Copy-QuotaDockTree $entry.FullName $destination
        }
        else {
            Copy-Item -LiteralPath $entry.FullName -Destination $destination -Force
        }
    }
}

function Restore-QuotaDockBackup {
    param([string]$BackupRoot, [string]$DestinationRoot)
    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        return
    }
    try {
        Copy-QuotaDockTree $BackupRoot $DestinationRoot
        Write-UpdateLog 'backup restored'
    }
    catch {
        Write-UpdateLog ('backup restore failed: ' + $_.Exception.Message)
    }
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'QuotaDock 本地更新器需要 PowerShell 7+（pwsh.exe）。'
}

if ($SelfTest) {
    if ($null -eq $powershell -or -not (Test-Path -LiteralPath $powershell)) {
        throw 'UPDATE_INSTALLER_SELFTEST_FAIL: 未找到 PowerShell 7+。'
    }
    foreach ($name in @('quota_center.ps1', 'quota_fusion_host.ps1', 'VERSION', 'check_for_updates.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $scriptRoot $name))) {
            throw ('UPDATE_INSTALLER_SELFTEST_FAIL: 缺少 ' + $name)
        }
    }
    Write-Output 'UPDATE_INSTALLER_SELFTEST_PASS powershell=7+ mode=download-verify-stage-replace-restart'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = $scriptRoot
}
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    throw ('安装目录不存在：' + $InstallRoot)
}
if ($InstallRoot.Length -lt 5 -or $InstallRoot -match '^[A-Za-z]:$') {
    throw '拒绝把更新安装到磁盘根目录。'
}
if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
    throw '更新包缺少有效的 SHA-256 校验值，已停止安装。'
}
if ([string]::IsNullOrWhiteSpace($PackagePath) -and [string]::IsNullOrWhiteSpace($PackageUrl)) {
    throw '缺少更新包地址。'
}

$nonce = [guid]::NewGuid().ToString('N')
$workRoot = Join-Path $env:TEMP ('QuotaDock-update-' + $nonce)
$packageFile = Join-Path $workRoot 'QuotaDock-update.zip'
$extractRoot = Join-Path $workRoot 'extracted'
$backupRoot = Join-Path $env:TEMP ('QuotaDock-backup-' + $nonce)
$backupCreated = $false

try {
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
        Copy-Item -LiteralPath ([System.IO.Path]::GetFullPath($PackagePath)) -Destination $packageFile -Force
    }
    else {
        Write-UpdateLog ('download start url=' + $PackageUrl)
        Invoke-WebRequest -Uri $PackageUrl -OutFile $packageFile -TimeoutSec 180
    }
    $actualHash = (Get-FileHash -LiteralPath $packageFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $ExpectedSha256.ToLowerInvariant()) {
        throw ('更新包 SHA-256 校验失败：期望 ' + $ExpectedSha256 + '，实际 ' + $actualHash)
    }
    Write-UpdateLog ('download verified sha256=' + $actualHash)

    Expand-Archive -LiteralPath $packageFile -DestinationPath $extractRoot -Force
    $packageRoot = Resolve-PackageRoot $extractRoot
    if (-not [string]::IsNullOrWhiteSpace($TargetVersion)) {
        $packageVersion = (Get-Content -LiteralPath (Join-Path $packageRoot 'VERSION') -Raw -Encoding UTF8).Trim()
        if ($packageVersion.TrimStart('v') -ne $TargetVersion.Trim().TrimStart('v')) {
            throw ('更新包版本与目标版本不一致：' + $packageVersion + ' / ' + $TargetVersion)
        }
    }

    if ($CloseProcessId -gt 0) {
        Close-QuotaDockProcess $CloseProcessId
    }
    elseif ($ParentPid -gt 0) {
        Wait-QuotaDockProcessExit $ParentPid 30 -ForceAfterTimeout
    }
    Stop-QuotaDockHostProcesses $InstallRoot

    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    Copy-QuotaDockTree $InstallRoot $backupRoot
    $backupCreated = $true
    Write-UpdateLog ('backup created=' + $backupRoot)

    Copy-QuotaDockTree $packageRoot $InstallRoot
    $installedVersion = (Get-Content -LiteralPath (Join-Path $InstallRoot 'VERSION') -Raw -Encoding UTF8).Trim()
    if (-not [string]::IsNullOrWhiteSpace($TargetVersion) -and $installedVersion.TrimStart('v') -ne $TargetVersion.Trim().TrimStart('v')) {
        throw ('本地替换后版本不一致：' + $installedVersion + ' / ' + $TargetVersion)
    }
    Write-UpdateLog ('install success version=' + $installedVersion)

    if ($RestartCenter) {
        $centerPath = Join-Path $InstallRoot $CenterScript
        if (-not (Test-Path -LiteralPath $centerPath)) {
            throw ('更新后找不到中心脚本：' + $centerPath)
        }
        Start-Process -FilePath $powershell -WindowStyle Hidden -WorkingDirectory $InstallRoot -ArgumentList @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            $centerPath
        ) | Out-Null
        Write-UpdateLog 'center restarted'
    }
}
catch {
    $message = $_.Exception.Message
    Write-UpdateLog ('update failed: ' + $message)
    try {
        [System.IO.File]::WriteAllText($failureLog, ((Get-Date).ToString('o') + "`r`n" + $message), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
    }
    if ($backupCreated) {
        Restore-QuotaDockBackup $backupRoot $InstallRoot
    }
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        ('QuotaDock 更新失败，已尝试恢复原版本。' + [Environment]::NewLine + [Environment]::NewLine + $message),
        'QuotaDock 更新失败',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $backupRoot) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ('QUOTADOCK_UPDATE_PASS version=' + $installedVersion)
