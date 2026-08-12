param(
    [int]$Port = 45731
)

$ErrorActionPreference = 'Stop'
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'QuotaDock'
$sourceConfigPath = Join-Path $stateDir 'quota_sources.json'
$dataPath = Join-Path $stateDir 'data\opencode_go.json'
$envDataPath = [Environment]::GetEnvironmentVariable('QUOTADOCK_OPENCODE_DATA')
if (-not [string]::IsNullOrWhiteSpace($envDataPath)) {
    $dataPath = [Environment]::ExpandEnvironmentVariables($envDataPath.Trim())
}
elseif (Test-Path -LiteralPath $sourceConfigPath) {
    try {
        $sourceConfig = Get-Content -LiteralPath $sourceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $sourceConfig.opencodePath -and -not [string]::IsNullOrWhiteSpace([string]$sourceConfig.opencodePath)) {
            $dataPath = [Environment]::ExpandEnvironmentVariables(([string]$sourceConfig.opencodePath).Trim())
        }
    }
    catch {
    }
}
$bridgeLog = Join-Path $env:TEMP 'quotadock-opencode-bridge.log'

function Write-BridgeLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $bridgeLog -Value ((Get-Date -Format 's') + ' ' + $Message) -Encoding UTF8
    }
    catch {
    }
}

function Send-Json {
    param($Context, [int]$StatusCode, $Payload)
    $json = $Payload | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentEncoding = [System.Text.Encoding]::UTF8
    $Context.Response.Headers['Access-Control-Allow-Origin'] = 'https://opencode.ai'
    $Context.Response.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    $Context.Response.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Send-Empty {
    param($Context, [int]$StatusCode)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.Headers['Access-Control-Allow-Origin'] = 'https://opencode.ai'
    $Context.Response.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    $Context.Response.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
    $Context.Response.Close()
}

function Get-Number {
    param($Value, [string]$Name)
    try {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0 -or $number -gt 100) {
            throw "$Name is outside 0..100"
        }
        return [Math]::Round($number, 2)
    }
    catch {
        throw "$Name is invalid"
    }
}

function Write-QuotaFile {
    param($Payload)
    $windows = @($Payload.windows)
    if ($windows.Count -ne 3) {
        throw 'expected three quota windows'
    }

    $kindOrder = @('five_hour', 'week', 'month')
    $modeMap = @{
        five_hour = 'rolling'
        week      = 'weekly'
        month     = 'monthly'
    }
    $canonical = New-Object System.Collections.ArrayList
    foreach ($kind in $kindOrder) {
        $item = $windows | Where-Object { [string]$_.kind -eq $kind } | Select-Object -First 1
        if ($null -eq $item) {
            throw "missing $kind window"
        }
        $used = Get-Number $item.usedPercent "$kind usedPercent"
        $remaining = Get-Number $item.remainingPercent "$kind remainingPercent"
        $title = [string]$item.title
        if ([string]::IsNullOrWhiteSpace($title)) {
            throw "missing $kind title"
        }
        $resetText = [string]$item.resetText
        if ([string]::IsNullOrWhiteSpace($resetText)) {
            throw "missing $kind resetText"
        }
        [void]$canonical.Add([ordered]@{
            kind             = $kind
            title            = $title
            usedPercent      = $used
            remainingPercent = $remaining
            resetText        = $resetText
            resetMode        = $modeMap[$kind]
        })
    }

    $output = [ordered]@{
        provider  = 'opencode'
        isLive    = $true
        source    = 'official_console_browser'
        updatedAt = [DateTime]::UtcNow.ToString('o')
        note      = 'Official OpenCode Console browser bridge; quota values only.'
        windows   = @($canonical.ToArray())
    }
    $json = $output | ConvertTo-Json -Depth 8
    $directory = Split-Path -Parent $dataPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $tmpPath = "$dataPath.$PID.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    try {
        if (Test-Path -LiteralPath $dataPath) {
            [System.IO.File]::Replace($tmpPath, $dataPath, $null, $true)
        }
        else {
            [System.IO.File]::Move($tmpPath, $dataPath)
        }
    }
    catch {
        Move-Item -LiteralPath $tmpPath -Destination $dataPath -Force
    }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
}
catch {
    Write-BridgeLog ('listener-start: ' + $_.Exception.Message)
    exit 1
}

Write-BridgeLog "started on 127.0.0.1:$Port"
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            if ($context.Request.HttpMethod -eq 'OPTIONS') {
                Send-Empty $context 204
                continue
            }
            $path = $context.Request.Url.AbsolutePath
            if ($context.Request.HttpMethod -eq 'GET' -and $path -eq '/health') {
                Send-Json $context 200 ([ordered]@{ ok = $true; service = 'opencode-go-browser-bridge' })
                continue
            }
            if ($context.Request.HttpMethod -ne 'POST' -or $path -ne '/opencode') {
                Send-Json $context 404 ([ordered]@{ ok = $false; error = 'not found' })
                continue
            }
            # JSON.stringify()/fetch always sends UTF-8. Do not fall back to the
            # HttpListener default encoding when the Content-Type omits charset.
            $reader = New-Object System.IO.StreamReader($context.Request.InputStream, [System.Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd()
            $reader.Dispose()
            $payload = $body | ConvertFrom-Json
            Write-QuotaFile $payload
            Send-Json $context 200 ([ordered]@{ ok = $true })
        }
        catch {
            Write-BridgeLog ('request: ' + $_.Exception.Message)
            try {
                Send-Json $context 400 ([ordered]@{ ok = $false; error = 'invalid quota payload' })
            }
            catch {
            }
        }
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
    Write-BridgeLog 'stopped'
}
