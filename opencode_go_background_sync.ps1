param(
    [int]$IntervalSeconds = 60,
    [switch]$Once,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'QuotaDock'
$sourceConfigPath = Join-Path $stateDir 'quota_sources.json'
$dataPath = Join-Path $stateDir 'data\opencode_go.json'
$credentialPath = Join-Path $stateDir 'opencode_go_credentials.json'
$legacyCredentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'QuotaFusionDesktop\opencode_go_credentials.json'
$syncLog = Join-Path $env:TEMP 'quotadock-opencode-background.log'
$mutexName = 'Local\QuotaDockOpenCodeGoWriteMutex'
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36'

if (Test-Path -LiteralPath $sourceConfigPath) {
    try {
        $sourceConfig = Get-Content -LiteralPath $sourceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $sourceConfig.opencodePath -and -not [string]::IsNullOrWhiteSpace([string]$sourceConfig.opencodePath)) {
            $dataPath = [Environment]::ExpandEnvironmentVariables(([string]$sourceConfig.opencodePath).Trim())
        }
    }
    catch {
    }
}
$envDataPath = [Environment]::GetEnvironmentVariable('QUOTADOCK_OPENCODE_DATA')
if (-not [string]::IsNullOrWhiteSpace($envDataPath)) {
    $dataPath = [Environment]::ExpandEnvironmentVariables($envDataPath.Trim())
}

try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
}
catch {
    throw '无法加载 Windows 网络程序集 System.Net.Http；请重新启动后台同步后再试'
}

function Write-BackgroundLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $syncLog -Value ((Get-Date -Format 's') + ' ' + $Message) -Encoding UTF8
    }
    catch {
    }
}

function Write-JsonAtomic {
    param(
        [string]$Path,
        $Payload
    )
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $json = $Payload | ConvertTo-Json -Depth 10
    $tmpPath = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    try {
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($tmpPath, $Path, $null, $true)
        }
        else {
            [System.IO.File]::Move($tmpPath, $Path)
        }
    }
    catch {
        Move-Item -LiteralPath $tmpPath -Destination $Path -Force
    }
}

function Read-ExistingSnapshot {
    $candidates = @($dataPath, (Join-Path $baseDir 'opencode_go_live.json'))
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        try {
            return Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
        }
    }
    return $null
}

function Set-JsonProperty {
    param(
        $Object,
        [string]$Name,
        $Value
    )
    if ($null -eq $Object) {
        return
    }
    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Unprotect-CurrentUserText {
    param([string]$ProtectedText)
    Add-Type -AssemblyName System.Security
    $protected = [Convert]::FromBase64String($ProtectedText)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Get-OpenCodeCredentialPath {
    foreach ($candidate in @($credentialPath, $legacyCredentialPath)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $credentialPath
}

function Get-OpenCodeCredential {
    $activeCredentialPath = Get-OpenCodeCredentialPath
    if (-not (Test-Path -LiteralPath $activeCredentialPath)) {
        throw "未配置 OpenCode Go 后台凭证：$credentialPath"
    }

    $config = Get-Content -Raw -LiteralPath $activeCredentialPath | ConvertFrom-Json
    $workspaceId = [string]$config.workspaceId
    $protectedCookie = [string]$config.authCookieProtected
    if ([string]::IsNullOrWhiteSpace($workspaceId) -or [string]::IsNullOrWhiteSpace($protectedCookie)) {
        throw 'OpenCode Go 后台凭证文件不完整'
    }
    if ([string]$config.protection -ne 'dpapi-current-user') {
        throw 'OpenCode Go 凭证格式需要重新配置；请运行配置终端保存一次'
    }

    $authCookie = Unprotect-CurrentUserText $protectedCookie
    if ([string]::IsNullOrWhiteSpace($authCookie)) {
        throw 'OpenCode Go auth Cookie 为空'
    }

    [pscustomobject]@{
        WorkspaceId = $workspaceId.Trim()
        AuthCookie  = $authCookie.Trim()
    }
}

function Get-QuotaWindowFromSsr {
    param(
        [string]$Html,
        [string]$FieldName
    )

    $number = '-?\d+(?:\.\d+)?'
    $prefix = [regex]::Escape($FieldName) + '\s*:\s*\$R\[\d+\]\s*=\s*\{'
    $patterns = @(
        [pscustomobject]@{
            Pattern = $prefix + '[^}]*?usagePercent\s*:\s*(' + $number + ')[^}]*?resetInSec\s*:\s*(' + $number + ')[^}]*?\}'
            UsageGroup = 1
            ResetGroup = 2
        },
        [pscustomobject]@{
            Pattern = $prefix + '[^}]*?resetInSec\s*:\s*(' + $number + ')[^}]*?usagePercent\s*:\s*(' + $number + ')[^}]*?\}'
            UsageGroup = 2
            ResetGroup = 1
        }
    )

    foreach ($candidate in $patterns) {
        $match = [regex]::Match($Html, $candidate.Pattern)
        if (-not $match.Success) {
            continue
        }
        $usage = [double]$match.Groups[$candidate.UsageGroup].Value
        $reset = [double]$match.Groups[$candidate.ResetGroup].Value
        if ([double]::IsNaN($usage) -or [double]::IsInfinity($usage) -or
            [double]::IsNaN($reset) -or [double]::IsInfinity($reset)) {
            continue
        }
        return [pscustomobject]@{
            UsedPercent = [Math]::Max(0.0, [Math]::Min(100.0, $usage))
            ResetInSec  = [Math]::Max(0, [int][Math]::Ceiling($reset))
        }
    }

    return $null
}

function Convert-HumanDurationToSeconds {
    param([string]$Text)
    $total = 0.0
    $found = $false
    $matches = [regex]::Matches(($Text -replace '<[^>]+>', ' '), '(\d+(?:\.\d+)?)\s*(days?|hours?|minutes?|seconds?|天|小时|分钟|秒)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($match in $matches) {
        $found = $true
        $value = [double]$match.Groups[1].Value
        switch -Regex ($match.Groups[2].Value.ToLowerInvariant()) {
            '^days?$|^天$' { $total += $value * 86400; break }
            '^hours?$|^小时$' { $total += $value * 3600; break }
            '^minutes?$|^分钟$' { $total += $value * 60; break }
            '^seconds?$|^秒$' { $total += $value; break }
        }
    }
    if (-not $found) {
        return $null
    }
    return [Math]::Max(0, [int][Math]::Ceiling($total))
}

function Get-QuotaWindowsFromDataSlots {
    param([string]$Html)

    $result = @{}
    $chunks = [regex]::Split($Html, 'data-slot="usage-item"')
    for ($index = 1; $index -lt $chunks.Count; $index++) {
        $chunk = $chunks[$index]
        $labelMatch = [regex]::Match($chunk, 'data-slot="usage-label"[^>]*>\s*([^<]+)')
        $valueMatch = [regex]::Match($chunk, 'data-slot="usage-value"[^>]*>[^0-9-]*(-?\d+(?:\.\d+)?)')
        $resetMatch = [regex]::Match($chunk, 'data-slot="(?:reset-time|reset-now)"[^>]*>([\s\S]*?)</span>')
        if (-not $labelMatch.Success -or -not $valueMatch.Success -or -not $resetMatch.Success) {
            continue
        }

        $label = $labelMatch.Groups[1].Value.Trim().ToLowerInvariant()
        $resetInSec = if ($chunk -match 'data-slot="reset-now"') { 0 } else { Convert-HumanDurationToSeconds $resetMatch.Groups[1].Value }
        if ($null -eq $resetInSec) {
            continue
        }
        $key = if ($label -match 'rolling|滚动') { 'five_hour' } elseif ($label -match 'weekly|每周') { 'week' } elseif ($label -match 'monthly|每月') { 'month' } else { $null }
        if ($null -eq $key) {
            continue
        }
        $used = [double]$valueMatch.Groups[1].Value
        $result[$key] = [pscustomobject]@{
            UsedPercent = [Math]::Max(0.0, [Math]::Min(100.0, $used))
            ResetInSec  = [int]$resetInSec
        }
    }
    return $result
}

function Get-QuotaWindows {
    param([string]$Html)

    $definitions = @(
        [pscustomobject]@{ Kind = 'five_hour'; Field = 'rollingUsage'; Title = '5 小时额度'; Mode = 'rolling' },
        [pscustomobject]@{ Kind = 'week'; Field = 'weeklyUsage'; Title = '周额度'; Mode = 'weekly' },
        [pscustomobject]@{ Kind = 'month'; Field = 'monthlyUsage'; Title = '月额度'; Mode = 'monthly' }
    )
    $parsed = @{}
    foreach ($definition in $definitions) {
        $window = Get-QuotaWindowFromSsr -Html $Html -FieldName $definition.Field
        if ($null -ne $window) {
            $parsed[$definition.Kind] = $window
        }
    }

    if ($parsed.Count -eq 0) {
        $parsed = Get-QuotaWindowsFromDataSlots -Html $Html
    }
    if ($parsed.Count -eq 0) {
        throw '无法从 OpenCode Go 官方页面解析额度窗口'
    }

    $output = New-Object System.Collections.ArrayList
    foreach ($definition in $definitions) {
        if (-not $parsed.ContainsKey($definition.Kind)) {
            throw "缺少 $($definition.Kind) 额度窗口"
        }
        $window = $parsed[$definition.Kind]
        [void]$output.Add([ordered]@{
            kind             = $definition.Kind
            title            = $definition.Title
            usedPercent      = [Math]::Round([double]$window.UsedPercent, 2)
            remainingPercent = [Math]::Round(100 - [double]$window.UsedPercent, 2)
            resetText        = Get-ResetText -Seconds ([int]$window.ResetInSec)
            resetMode        = $definition.Mode
        })
    }
    return @($output.ToArray())
}

function Get-ResetText {
    param([int]$Seconds)
    $seconds = [Math]::Max(0, $Seconds)
    if ($seconds -eq 0) {
        return '现在重置'
    }

    $days = [int][Math]::Floor($seconds / 86400)
    $hours = [int][Math]::Floor(($seconds % 86400) / 3600)
    $minutes = [int][Math]::Floor(($seconds % 3600) / 60)
    $parts = New-Object System.Collections.ArrayList
    if ($days -gt 0) { [void]$parts.Add("$days 天") }
    if ($hours -gt 0) { [void]$parts.Add("$hours 小时") }
    if ($minutes -gt 0 -and $parts.Count -lt 2) { [void]$parts.Add("$minutes 分钟") }
    if ($parts.Count -eq 0) { [void]$parts.Add('少于 1 分钟') }
    return '约 ' + ($parts -join ' ') + '后重置'
}

function Fetch-OpenCodeGoHtml {
    param($Credential)

    $workspaceId = [uri]::EscapeDataString($Credential.WorkspaceId)
    $url = "https://opencode.ai/workspace/$workspaceId/go"
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd($userAgent)
        $client.DefaultRequestHeaders.Accept.ParseAdd('text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8')
        $client.DefaultRequestHeaders.Add('Accept-Language', 'en-US,en;q=0.8')
        $client.DefaultRequestHeaders.Add('Cookie', 'auth=' + $Credential.AuthCookie)
        $response = $client.GetAsync($url).GetAwaiter().GetResult()
        $html = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        $finalUrl = [string]$response.RequestMessage.RequestUri.AbsoluteUri
        $locationHost = ''
        $locationPath = ''
        if ($response.Headers.Location) {
            $locationUri = [uri]$response.Headers.Location
            $locationHost = $locationUri.Host
            $locationPath = $locationUri.AbsolutePath
        }
        $titleMatch = [regex]::Match($html, '<title[^>]*>([\s\S]*?)</title>', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $safeTitle = if ($titleMatch.Success) { ($titleMatch.Groups[1].Value -replace '\s+', ' ').Trim() } else { '' }
        $safeLoginMarker = [bool]($html -match '/(?:auth/authorize|sign-in|login)')
        $safeMarkers = @(
            'rollingUsage=' + ([regex]::Matches($html, 'rollingUsage').Count),
            'weeklyUsage=' + ([regex]::Matches($html, 'weeklyUsage').Count),
            'monthlyUsage=' + ([regex]::Matches($html, 'monthlyUsage').Count),
            'dataSlot=' + ([regex]::Matches($html, 'data-slot').Count),
            'login=' + $safeLoginMarker,
            'title=' + $safeTitle
        )
        Write-BackgroundLog ('fetch status=' + $status + ' finalUrl=' + $finalUrl + ' locationHost=' + $locationHost + ' locationPath=' + $locationPath + ' length=' + $html.Length + ' ' + ($safeMarkers -join ' '))
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }

    if ($status -eq 401 -or $status -eq 403) {
        throw "OpenCode Go 认证失败（HTTP $status），auth Cookie 可能已过期"
    }
    if ($status -ge 300 -and $status -lt 400) {
        throw "OpenCode Go 请求被重定向到登录授权页（HTTP $status），后台 Cookie 未被官方会话识别"
    }
    if ($status -lt 200 -or $status -ge 300) {
        throw "OpenCode Go 页面请求失败（HTTP $status）"
    }
    if ($finalUrl -match '/(?:auth/authorize|sign-in|login)') {
        throw 'OpenCode Go 会话已过期，请重新配置 auth Cookie'
    }
    if ($html -match '/(?:auth/authorize|sign-in|login)' -and $html -notmatch 'rollingUsage') {
        throw 'OpenCode Go 会话已过期，请重新配置 auth Cookie'
    }
    return $html
}

function Write-QuotaSnapshot {
    param([array]$Windows)

    $now = [DateTime]::UtcNow.ToString('o')
    $output = [ordered]@{
        provider  = 'opencode'
        isLive    = $true
        source    = 'official_console_background'
        updatedAt = $now
        lastSuccessAt = $now
        lastAttemptAt = $now
        syncStatus = 'success'
        lastError = $null
        note      = 'Official OpenCode Go dashboard direct fetch; quota values only.'
        windows   = @($Windows)
    }
    Write-JsonAtomic $dataPath $output
}

function Write-QuotaFailureState {
    param([string]$Message)

    $now = [DateTime]::UtcNow.ToString('o')
    $existing = Read-ExistingSnapshot
    if ($null -eq $existing) {
        $existing = [pscustomobject]@{
            provider = 'opencode'
            source = 'official_console_background'
            windows = @()
        }
    }
    Set-JsonProperty $existing 'isLive' $false
    Set-JsonProperty $existing 'source' 'official_console_background'
    Set-JsonProperty $existing 'lastAttemptAt' $now
    Set-JsonProperty $existing 'syncStatus' 'error'
    Set-JsonProperty $existing 'lastError' $Message
    if ([string]::IsNullOrWhiteSpace([string]$existing.note)) {
        Set-JsonProperty $existing 'note' 'OpenCode Go 后台同步失败；保留最近一次成功额度。'
    }
    Write-JsonAtomic $dataPath $existing
}

function Invoke-BackgroundSync {
    $credential = Get-OpenCodeCredential
    $html = Fetch-OpenCodeGoHtml -Credential $credential
    $windows = Get-QuotaWindows -Html $html
    Write-QuotaSnapshot -Windows $windows
    Write-BackgroundLog ('success workspace=' + $credential.WorkspaceId + ' windows=' + $windows.Count)
    return [pscustomobject]@{ WorkspaceId = $credential.WorkspaceId; Windows = $windows.Count }
}

if ($SelfTest) {
    $fixture = 'rollingUsage:$R[0]={status:"ok",resetInSec:3600,usagePercent:12.5};weeklyUsage:$R[1]={status:"ok",usagePercent:34,resetInSec:86400};monthlyUsage:$R[2]={status:"ok",resetInSec:2592000,usagePercent:3}'
    $selfTestWindows = Get-QuotaWindows -Html $fixture
    if ($selfTestWindows.Count -ne 3 -or $selfTestWindows[0].usedPercent -ne 12.5 -or $selfTestWindows[1].usedPercent -ne 34 -or $selfTestWindows[2].usedPercent -ne 3) {
        throw 'OpenCode Go 后台解析器自测失败'
    }
    Write-Output 'SELFTEST PASS: SSR 三窗口解析与百分比归一化正常'
    exit 0
}

if (-not (Test-Path -LiteralPath (Get-OpenCodeCredentialPath))) {
    Write-BackgroundLog 'not-started: credentials are not configured'
    try {
        Write-QuotaFailureState '未配置 OpenCode Go 后台凭证'
    }
    catch {
        Write-BackgroundLog ('failure-state: ' + $_.Exception.Message)
    }
    exit 2
}

$syncMutex = New-Object System.Threading.Mutex($false, $mutexName)
$ownsSyncMutex = $false
try {
    $ownsSyncMutex = $syncMutex.WaitOne(0)
}
catch {
    $ownsSyncMutex = $false
}
if (-not $ownsSyncMutex) {
    Write-BackgroundLog 'not-started: another OpenCode Go sync process is already running'
    $syncMutex.Dispose()
    exit 0
}

try {
    do {
    try {
        $result = Invoke-BackgroundSync
        if ($Once) {
            Write-Output ('SYNC PASS: ' + $result.WorkspaceId + ' windows=' + $result.Windows)
            exit 0
        }
    }
    catch {
        $message = $_.Exception.Message
        Write-BackgroundLog ('error: ' + $message)
        try { Write-QuotaFailureState $message } catch { Write-BackgroundLog ('failure-state: ' + $_.Exception.Message) }
        if ($Once) {
            Write-Output ('SYNC FAIL: ' + $message)
            exit 1
        }
    }

    if ($Once) {
        exit 1
    }
    Start-Sleep -Seconds ([Math]::Max(15, $IntervalSeconds))
    } while ($true)
}
finally {
    if ($ownsSyncMutex) {
        try { $syncMutex.ReleaseMutex() } catch {}
    }
    $syncMutex.Dispose()
}
