param(
    [string]$OutputPath = '',
    [int]$IntervalSeconds = 60,
    [switch]$Once,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:MutexName = 'Local\QuotaDockCodexSyncMutex'

function Get-ObjectValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Set-ObjectValue {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object) { return }
    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Find-CodexWindow {
    param($Usage, [int]$WindowMinutes)
    $rateLimit = Get-ObjectValue $Usage 'rate_limit'
    foreach ($name in @('primary_window', 'secondary_window')) {
        $window = Get-ObjectValue $rateLimit $name
        $seconds = Get-ObjectValue $window 'limit_window_seconds'
        if ($null -eq $seconds) { continue }
        if ([double]$seconds -eq ($WindowMinutes * 60)) { return $window }
    }
    return $null
}

function Convert-CodexWindow {
    param([string]$Title, [int]$ExpectedMinutes, $Window)
    $usedValue = Get-ObjectValue $Window 'used_percent'
    $used = $null
    $remaining = $null
    if ($null -ne $usedValue) {
        $used = [Math]::Max(0, [Math]::Min(100, [double]$usedValue))
        $remaining = [int][Math]::Round(100 - $used)
    }

    $resetAt = $null
    $resetValue = Get-ObjectValue $Window 'reset_at'
    if ($null -ne $resetValue) {
        $resetUnix = [long]$resetValue
        if ($resetUnix -gt 0) {
            $resetAt = [DateTimeOffset]::FromUnixTimeSeconds($resetUnix).ToLocalTime().ToString('o')
        }
    }

    return [ordered]@{
        title            = $Title
        remainingPercent = $remaining
        usedPercent      = if ($null -eq $used) { $null } else { [int][Math]::Round($used) }
        resetAt          = $resetAt
        windowMinutes    = $ExpectedMinutes
    }
}

function Convert-CodexUsage {
    param($Usage)
    $shortWindow = Find-CodexWindow $Usage 300
    $weeklyWindow = Find-CodexWindow $Usage 10080
    if ($null -eq $shortWindow) { throw 'Codex 用量接口未返回 5 小时窗口。' }
    if ($null -eq $weeklyWindow) { throw 'Codex 用量接口未返回周窗口。' }

    $rateLimit = Get-ObjectValue $Usage 'rate_limit'
    $now = [DateTimeOffset]::Now.ToString('o')
    return [ordered]@{
        provider    = 'codex'
        shortWindow = Convert-CodexWindow '5 小时额度' 300 $shortWindow
        weekly      = Convert-CodexWindow '周额度' 10080 $weeklyWindow
        source      = [ordered]@{
            type         = 'api'
            updatedAt    = $now
            lastAttemptAt = $now
            lastSuccessAt = $now
            syncStatus   = 'success'
            lastError    = $null
            planType     = Get-ObjectValue $Usage 'plan_type'
            allowed      = [bool](Get-ObjectValue $rateLimit 'allowed')
            limitReached = [bool](Get-ObjectValue $rateLimit 'limit_reached')
            rejectedFreshWindowCount = 0
        }
    }
}

function Test-TransientFreshWindow {
    param($Current, $Previous)
    $currentWeekly = Get-ObjectValue $Current 'weekly'
    $previousWeekly = Get-ObjectValue $Previous 'weekly'
    if ($null -eq $currentWeekly -or $null -eq $previousWeekly) { return $false }

    $currentUsed = Get-ObjectValue $currentWeekly 'usedPercent'
    $previousUsed = Get-ObjectValue $previousWeekly 'usedPercent'
    if ($null -eq $currentUsed -or $null -eq $previousUsed) { return $false }
    if (-not ([double]$currentUsed -le 2 -and [double]$previousUsed -ge 5)) { return $false }

    try {
        $currentReset = [DateTimeOffset]::Parse([string](Get-ObjectValue $currentWeekly 'resetAt'))
        $previousReset = [DateTimeOffset]::Parse([string](Get-ObjectValue $previousWeekly 'resetAt'))
        return [Math]::Abs(($currentReset - $previousReset).TotalMinutes) -ge 30
    }
    catch {
        return $false
    }
}

function Resolve-OutputPath {
    param([string]$RequestedPath)
    $path = $RequestedPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = [Environment]::GetEnvironmentVariable('QUOTADOCK_CODEX_DATA')
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        $configPath = Join-Path $env:LOCALAPPDATA 'QuotaDock\quota_sources.json'
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            try {
                $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $path = [string](Get-ObjectValue $config 'codexPath')
            }
            catch {
                $path = ''
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path $env:LOCALAPPDATA 'QuotaDock\data\codex.json'
    }
    $path = [Environment]::ExpandEnvironmentVariables($path.Trim())
    if (-not [IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $PSScriptRoot $path
    }
    return [IO.Path]::GetFullPath($path)
}

function Read-ExistingData {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Write-JsonAtomic {
    param([string]$Path, $Data)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporaryPath = $Path + '.' + $PID + '.tmp'
    $json = $Data | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $Path, $null, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    catch {
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
}

function Set-SyncMetadata {
    param($Data, [string]$AttemptAt, [string]$Status, [string]$ErrorText = '')
    $source = Get-ObjectValue $Data 'source'
    if ($null -eq $source) {
        $source = [pscustomobject]@{}
        Set-ObjectValue $Data 'source' $source
    }
    Set-ObjectValue $source 'lastAttemptAt' $AttemptAt
    Set-ObjectValue $source 'syncStatus' $Status
    if ($Status -eq 'success') {
        Set-ObjectValue $source 'updatedAt' $AttemptAt
        Set-ObjectValue $source 'lastSuccessAt' $AttemptAt
        Set-ObjectValue $source 'lastError' $null
    }
    else {
        Set-ObjectValue $source 'lastError' $ErrorText
    }
    return $Data
}

function New-EmptyData {
    return [pscustomobject]@{
        provider = 'codex'
        shortWindow = [pscustomobject]@{ title = '5 小时额度'; remainingPercent = $null; resetAt = $null; windowMinutes = 300 }
        weekly = [pscustomobject]@{ title = '周额度'; remainingPercent = $null; resetAt = $null; windowMinutes = 10080 }
        source = [pscustomobject]@{ type = 'api'; updatedAt = $null; lastSuccessAt = $null }
    }
}

function Invoke-CodexUsageRequest {
    $authPath = Join-Path $env:USERPROFILE '.codex\auth.json'
    if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) {
        throw "找不到 Codex 登录文件：$authPath。请先在 Codex 中登录。"
    }
    $auth = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tokens = Get-ObjectValue $auth 'tokens'
    $token = [string](Get-ObjectValue $tokens 'access_token')
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Codex 登录文件中没有 access_token，请重新登录 Codex。' }

    $headers = @{
        Authorization = 'Bearer ' + $token
        'OAI-Language' = 'zh-CN'
        originator = 'Codex Desktop'
    }
    $request = @{
        Uri        = 'https://chatgpt.com/backend-api/wham/usage?supports_rewardless_invites=true'
        Method     = 'Get'
        Headers    = $headers
        TimeoutSec = 30
    }
    $proxyUrl = [Environment]::GetEnvironmentVariable('QUOTADOCK_PROXY_URL')
    if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) { $request.Proxy = $proxyUrl.Trim() }
    return Invoke-RestMethod @request
}

function Set-FailureState {
    param([string]$Path, $PreviousData, [string]$AttemptAt, [string]$Message)
    $data = if ($null -ne $PreviousData) { $PreviousData } else { New-EmptyData }
    $safeMessage = ($Message -replace '[\r\n]+', ' ').Trim()
    if ($safeMessage.Length -gt 220) { $safeMessage = $safeMessage.Substring(0, 220) }
    $data = Set-SyncMetadata $data $AttemptAt 'error' $safeMessage
    Write-JsonAtomic $Path $data
}

if ($SelfTest) {
    $shortReset = [DateTimeOffset]::UtcNow.AddHours(2)
    $weeklyReset = [DateTimeOffset]::UtcNow.AddDays(6)
    $fixture = [pscustomobject]@{
        plan_type = 'plus'
        rate_limit = [pscustomobject]@{
            allowed = $true
            limit_reached = $false
            primary_window = [pscustomobject]@{ limit_window_seconds = 18000; used_percent = 17; reset_at = $shortReset.ToUnixTimeSeconds() }
            secondary_window = [pscustomobject]@{ limit_window_seconds = 604800; used_percent = 36; reset_at = $weeklyReset.ToUnixTimeSeconds() }
        }
    }
    $snapshot = Convert-CodexUsage $fixture
    if ($snapshot.shortWindow.windowMinutes -ne 300 -or $snapshot.shortWindow.remainingPercent -ne 83 -or
        $snapshot.weekly.windowMinutes -ne 10080 -or $snapshot.weekly.remainingPercent -ne 64 -or
        [Math]::Abs(([DateTimeOffset]::Parse($snapshot.shortWindow.resetAt) - $shortReset).TotalSeconds) -gt 1 -or
        [Math]::Abs(([DateTimeOffset]::Parse($snapshot.weekly.resetAt) - $weeklyReset).TotalSeconds) -gt 1) {
        throw 'CODEX_SYNC_SELFTEST_FAIL: Codex 双窗口数值或各自 reset_at 转换错误。'
    }
    $missingWeekly = [pscustomobject]@{ rate_limit = [pscustomobject]@{ primary_window = $fixture.rate_limit.primary_window } }
    if ($null -ne (Find-CodexWindow $missingWeekly 10080)) {
        throw 'CODEX_SYNC_SELFTEST_FAIL: 不应把 5 小时窗口误认成周窗口。'
    }
    Write-Output 'CODEX_QUOTA_SYNC_SELFTEST_PASS windows=300,10080 reset_at=verified'
    exit 0
}

$resolvedOutputPath = Resolve-OutputPath $OutputPath
$mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
$ownsMutex = $false
try { $ownsMutex = $mutex.WaitOne(0) } catch { $ownsMutex = $false }
if (-not $ownsMutex) {
    $mutex.Dispose()
    exit 0
}

try {
    do {
        $attemptAt = [DateTimeOffset]::Now.ToString('o')
        $previous = Read-ExistingData $resolvedOutputPath
        try {
            $usage = Invoke-CodexUsageRequest
            $data = Convert-CodexUsage $usage
            if (Test-TransientFreshWindow $data $previous) {
                $source = Get-ObjectValue $previous 'source'
                $rejected = [int](Get-ObjectValue $source 'rejectedFreshWindowCount') + 1
                Set-ObjectValue $source 'rejectedFreshWindowCount' $rejected
                if ($rejected -lt 3) {
                    Set-SyncMetadata $previous $attemptAt 'error' ('暂缓采用疑似瞬时空周额度窗口（' + $rejected + '/3）。') | Out-Null
                    Write-JsonAtomic $resolvedOutputPath $previous
                    if ($Once) { exit 0 }
                    Start-Sleep -Seconds ([Math]::Max(10, $IntervalSeconds))
                    continue
                }
                Set-ObjectValue (Get-ObjectValue $data 'source') 'acceptedAfterTransientChecks' $true
            }
            Write-JsonAtomic $resolvedOutputPath $data
        }
        catch {
            $message = $_.Exception.Message
            try { Set-FailureState $resolvedOutputPath $previous $attemptAt $message } catch {}
            if ($Once) { throw }
        }

        if ($Once) { break }
        Start-Sleep -Seconds ([Math]::Max(10, $IntervalSeconds))
    } while ($true)
}
finally {
    if ($ownsMutex) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
}
