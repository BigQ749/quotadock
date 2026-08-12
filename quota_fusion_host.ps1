param(
    [string]$Provider = '',
    [switch]$SelfTest,
    [ValidateSet('', 'merge', 'merge-eject')]
    [string]$AutoDemo = ''
)

$ErrorActionPreference = 'Stop'

# Keep the independent and merged floaters crisp on high-DPI displays.
# This must run before loading WinForms so Windows does not stretch a
# low-resolution bitmap of the entire floating window.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class QuotaFusionDpiNative {
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")]
    private static extern int SetProcessDpiAwareness(int value);
    public static void Enable() {
        try {
            if (SetProcessDpiAwarenessContext(new IntPtr(-4))) {
                return;
            }
        }
        catch {
        }
        try {
            SetProcessDpiAwareness(2);
        }
        catch {
        }
    }
}
'@
[QuotaFusionDpiNative]::Enable()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$requestFile = Join-Path $env:TEMP 'quotadock-host-requests.txt'
$errorLog = Join-Path $env:TEMP 'quotadock-host-error.log'
$paintLog = Join-Path $env:TEMP 'quotadock-host-paint.log'
$appStateRoot = Join-Path $env:LOCALAPPDATA 'QuotaDock'
$hostStateFile = Join-Path $appStateRoot 'host_state.json'
$sourceConfigPath = Join-Path $appStateRoot 'quota_sources.json'
$customConfigPath = Join-Path $appStateRoot 'custom_providers.json'
$customDataRoot = Join-Path $appStateRoot 'custom-data'
$script:BrandImagePaths = @{
    codex    = Join-Path $baseDir 'assets\brand\chatgpt-mark.png'
    grok     = Join-Path $baseDir 'assets\brand\grok-mark.png'
    opencode = Join-Path $baseDir 'assets\brand\opencode-mark.png'
}
# The official artboards have different internal padding. These factors normalize
# the visible mark height while keeping each logo's original proportions intact.
$script:BrandRenderScales = @{
    codex    = 0.90
    grok     = 0.95
    opencode = 1.10
}
$script:BrandImages = @{}

function Write-Log {
    param([string]$Path, [string]$Message)
    try {
        Add-Content -LiteralPath $Path -Value $Message -Encoding UTF8
    }
    catch {
    }
}

function Save-HostState {
    try {
        $items = New-Object System.Collections.ArrayList
        foreach ($provider in @($script:Cards.Keys)) {
            $card = $script:Cards[$provider]
            if ($null -eq $card) {
                continue
            }
            $form = $card.Window
            if ($null -eq $form -or $form.IsDisposed) {
                continue
            }
            $dock = $script:DockState[$form]
            [void]$items.Add([ordered]@{
                id        = [string]$provider
                open      = $true
                visible   = [bool]$form.Visible
                minimized = [bool]$script:Minimized[$form]
                docked    = ($null -ne $dock -and [bool]$dock.Docked)
                edge      = if ($null -ne $dock) { [string]$dock.Edge } else { '' }
                fused     = [bool]$card.Fused
            })
        }
        $directory = Split-Path -Parent $hostStateFile
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $payload = [ordered]@{
            version   = 1
            hostPid   = [int]$PID
            updatedAt = (Get-Date).ToString('o')
            providers = @($items.ToArray())
        }
        $json = $payload | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($hostStateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-Log $errorLog ('host-state: ' + ($_ | Out-String))
    }
}

function Remove-HostStateEntry {
    param([string]$Provider)
    try {
        Save-HostState
        if (-not (Test-Path -LiteralPath $hostStateFile)) {
            return
        }
        $state = Get-Content -LiteralPath $hostStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $remaining = @(@(Get-JsonValue $state 'providers') | Where-Object { ([string](Get-JsonValue $_ 'id')).Trim().ToLowerInvariant() -ne $Provider })
        $payload = [ordered]@{
            version   = 1
            hostPid   = [int]$PID
            updatedAt = (Get-Date).ToString('o')
            providers = $remaining
        }
        [System.IO.File]::WriteAllText($hostStateFile, ($payload | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-Log $errorLog ('host-state-remove: ' + ($_ | Out-String))
    }
}

function New-HostFont {
    param(
        [string]$Family,
        [single]$Pixels,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    # Use device pixels for the translucent host so text size stays predictable
    # on the user's 200% display and is not double-scaled by GraphicsUnit.Point.
    return New-Object System.Drawing.Font(
        $Family,
        $Pixels,
        $Style,
        [System.Drawing.GraphicsUnit]::Pixel
    )
}

$script:Profiles = @{
    codex = @{
        Title     = 'Codex'
        Accent    = @(120, 188, 255)
        Width     = 460
        Height    = 230
        DefaultX  = 24
        DefaultY  = 170
    }
    grok = @{
        Title     = 'Grok'
        Accent    = @(255, 173, 115)
        Width     = 460
        Height    = 230
        DefaultX  = 308
        DefaultY  = 170
    }
    opencode = @{
        Title     = 'OpenCode Go'
        Accent    = @(170, 145, 255)
        Width     = 560
        Height    = 330
        DefaultX  = 24
        DefaultY  = 330
    }
}

function Read-QuotaDockSourceConfig {
    if (-not (Test-Path -LiteralPath $sourceConfigPath)) {
        return [pscustomobject]@{}
    }
    try {
        return Get-Content -LiteralPath $sourceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Log $errorLog ('source-config: ' + ($_ | Out-String))
        return [pscustomobject]@{}
    }
}

$script:SourceConfig = Read-QuotaDockSourceConfig

function Resolve-QuotaDockSourcePath {
    param(
        [string]$ConfigName,
        [string]$EnvironmentName,
        [string]$FallbackPath
    )
    $value = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ([string]::IsNullOrWhiteSpace($value)) {
        $property = $script:SourceConfig.PSObject.Properties[$ConfigName]
        if ($null -ne $property) {
            $value = [string]$property.Value
        }
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $FallbackPath
    }
    return [Environment]::ExpandEnvironmentVariables($value.Trim())
}

$localDataRoot = Join-Path $appStateRoot 'data'
function Get-QuotaDockDataFallback {
    param([string]$LocalName, [string]$ExampleName)
    $localPath = Join-Path $localDataRoot $LocalName
    if (Test-Path -LiteralPath $localPath) {
        return $localPath
    }
    return Join-Path $baseDir ('examples\' + $ExampleName)
}

$script:DataDefaults = @{
    codex    = Resolve-QuotaDockSourcePath 'codexPath' 'QUOTADOCK_CODEX_DATA' (Get-QuotaDockDataFallback 'codex.json' 'codex.quota.example.json')
    grok     = Resolve-QuotaDockSourcePath 'grokPath' 'QUOTADOCK_GROK_DATA' (Get-QuotaDockDataFallback 'grok.json' 'grok.quota.example.json')
    opencode = Resolve-QuotaDockSourcePath 'opencodePath' 'QUOTADOCK_OPENCODE_DATA' (Get-QuotaDockDataFallback 'opencode_go.json' 'opencode_go.quota.example.json')
}

$script:Cards = @{}
$script:FormCards = @{}
$script:DockState = @{}
$script:Minimized = @{}
$script:Expanded = @{}
$script:DragState = @{}
$script:FusionFx = @{}
$script:DemoTarget = $null
$script:DemoEjectTimer = $null
$script:PulseForms = @{}
$script:PulseTimer = $null
    $script:DockTimer = $null
    $script:ClosingForms = @{}
    $script:MergePending = @{}
    $script:MergeConsumed = @{}
$script:DockRevealDelayMs = 650
$script:DockHideDelayMs = 280
# The first value is the visible depth into the screen; the second is the
# fixed length along the edge. All supported dock edges use the same length.
$script:DockPeekDepth = 14
$script:DockHandleLength = 180

function Get-JsonValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Import-CustomProviders {
    if (-not (Test-Path -LiteralPath $customConfigPath)) {
        return
    }
    try {
        $config = Get-Content -LiteralPath $customConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in @($config.providers)) {
            $id = ([string](Get-JsonValue $entry 'id')).Trim().ToLowerInvariant()
            $title = ([string](Get-JsonValue $entry 'title')).Trim()
            if ([string]::IsNullOrWhiteSpace($id) -or
                $id -notmatch '^[a-z0-9][a-z0-9_-]{1,31}$' -or
                [string]::IsNullOrWhiteSpace($title) -or
                @('codex', 'grok', 'opencode') -contains $id) {
                continue
            }
            $dataPath = [Environment]::ExpandEnvironmentVariables([string](Get-JsonValue $entry 'dataPath')).Trim()
            if ([string]::IsNullOrWhiteSpace($dataPath)) {
                $dataPath = Join-Path $customDataRoot ($id + '.json')
            }
            $accent = @(Get-JsonValue $entry 'accent')
            if ($accent.Count -ne 3) {
                $accent = @(112, 191, 255)
            }
            $brandPath = [Environment]::ExpandEnvironmentVariables([string](Get-JsonValue $entry 'brandPath')).Trim()
            $profile = @{
                Title       = $title
                Description = ([string](Get-JsonValue $entry 'description')).Trim()
                Accent      = @([int]$accent[0], [int]$accent[1], [int]$accent[2])
                Width       = 560
                Height      = 330
                DefaultX    = 24
                DefaultY    = 170
                Kind        = 'custom'
            }
            if ([string]::IsNullOrWhiteSpace($profile.Description)) {
                $profile.Description = '自定义额度 · 本地 JSON'
            }
            $script:Profiles[$id] = $profile
            $script:DataDefaults[$id] = $dataPath
            if (-not [string]::IsNullOrWhiteSpace($brandPath)) {
                $script:BrandImagePaths[$id] = $brandPath
                $script:BrandRenderScales[$id] = 1.0
            }
        }
    }
    catch {
        Write-Log $errorLog ('custom provider config: ' + ($_ | Out-String))
    }
}

Import-CustomProviders

function Read-QuotaData {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-PercentNumber {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    try {
        return [Math]::Max(0, [Math]::Min(100, [double]$Value))
    }
    catch {
        return $null
    }
}

function Format-Percent {
    param($Value)
    $number = Get-PercentNumber $Value
    if ($null -eq $number) {
        return '--'
    }
    return ('{0:0}%' -f $number)
}

function Format-ResetText {
    param($ResetAt)
    if ([string]::IsNullOrWhiteSpace([string]$ResetAt)) {
        return '重置时间未知'
    }
    try {
        $reset = [datetimeoffset]::Parse([string]$ResetAt)
        $left = $reset - [datetimeoffset]::Now
        $local = $reset.LocalDateTime
        if ($left.TotalSeconds -le 0) {
            return '正在重置'
        }
        if ($left.TotalDays -ge 1) {
            return $local.ToString('M月d日 HH:mm')
        }
        return $local.ToString('HH:mm')
    }
    catch {
        return [string]$ResetAt
    }
}

function Format-UpdatedText {
    param($UpdatedAt)
    if ([string]::IsNullOrWhiteSpace([string]$UpdatedAt)) {
        return '等待同步'
    }
    try {
        return '已同步 ' + ([datetimeoffset]::Parse([string]$UpdatedAt).LocalDateTime.ToString('HH:mm'))
    }
    catch {
        return '已同步 ' + [string]$UpdatedAt
    }
}

function New-Row {
    param([string]$Label, [string]$Remaining, [string]$ResetText)
    return [pscustomobject]@{
        Label          = $Label
        Remaining      = $Remaining
        ResetText      = $ResetText
        RemainingNumber = Get-PercentNumber ($Remaining -replace '%', '')
    }
}

function Get-UiModel {
    param([string]$Provider)
    $data = Read-QuotaData $script:DataDefaults[$Provider]
    if ($null -eq $data) {
        return [pscustomobject]@{
            Title  = $script:Profiles[$Provider].Title
            Badge  = '等待数据'
            Status = '等待首次同步'
            Rows   = @()
            Error  = $true
        }
    }

    $profile = $script:Profiles[$Provider]
    if ($null -ne $profile -and $profile.Kind -eq 'custom') {
        $rows = New-Object System.Collections.ArrayList
        # The current 330px custom card has room for three readable rows.
        $customWindows = @(Get-JsonValue $data 'windows') | Select-Object -First 3
        foreach ($window in @($customWindows)) {
            $label = [string](Get-JsonValue $window 'label')
            if ([string]::IsNullOrWhiteSpace($label)) {
                $label = [string](Get-JsonValue $window 'title') -replace '额度$', ''
            }
            if ([string]::IsNullOrWhiteSpace($label)) {
                $label = '额度'
            }
            $percent = Get-JsonValue $window 'remainingPercent'
            if ($null -eq $percent) {
                $percent = Get-JsonValue $window 'percent'
            }
            $resetText = [string](Get-JsonValue $window 'resetText')
            if ([string]::IsNullOrWhiteSpace($resetText)) {
                $resetAt = Get-JsonValue $window 'resetAt'
                $resetText = if ($null -ne $resetAt) { Format-ResetText $resetAt } else { '重置时间未知' }
            }
            if ($null -eq (Get-PercentNumber $percent) -and
                ($resetText -eq '重置时间未知' -or [string]::IsNullOrWhiteSpace($resetText))) {
                $resetText = '等待同步'
            }
            [void]$rows.Add((New-Row $label (Format-Percent $percent) $resetText))
        }
        if ($rows.Count -eq 0) {
            # Keep an empty custom provider visibly understandable. The card is
            # registered, but its adapter has not written a quota payload yet.
            [void]$rows.Add((New-Row '额度' '--' '等待同步'))
        }
        $updatedAt = [string](Get-JsonValue $data 'updatedAt')
        $status = [string](Get-JsonValue $data 'status')
        if ([string]::IsNullOrWhiteSpace($status)) {
            $status = Format-UpdatedText $updatedAt
        }
        $badge = [string](Get-JsonValue $data 'badge')
        if ([string]::IsNullOrWhiteSpace($badge)) {
            $badge = '自定义'
        }
        return [pscustomobject]@{
            Title  = if ([string]::IsNullOrWhiteSpace([string](Get-JsonValue $data 'title'))) { $profile.Title } else { [string](Get-JsonValue $data 'title') }
            Badge  = $badge
            Status = $status
            Rows   = @($rows.ToArray())
            Error  = ($rows.Count -eq 0)
        }
    }

    if ($Provider -eq 'codex') {
        $weekly = Get-JsonValue $data 'weekly'
        $source = Get-JsonValue $data 'source'
        $remaining = Get-JsonValue $weekly 'remainingPercent'
        $resetAt = Get-JsonValue $weekly 'resetAt'
        return [pscustomobject]@{
            Title  = 'Codex'
            Badge  = '本地同步'
            Status = Format-UpdatedText (Get-JsonValue $source 'updatedAt')
            Rows   = @((New-Row '周额度' (Format-Percent $remaining) (Format-ResetText $resetAt)))
            Error  = $false
        }
    }

    if ($Provider -eq 'grok') {
        $remaining = Get-JsonValue $data 'remaining'
        $resetText = Get-JsonValue $data 'reset_txt'
        $syncText = Get-JsonValue $data 'synced_at'
        $errorText = Get-JsonValue $data 'err'
        $status = '等待同步'
        if (-not [string]::IsNullOrWhiteSpace([string]$errorText)) {
            $status = '同步失败 · ' + [string]$errorText
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$syncText)) {
            $status = '已同步 ' + [string]$syncText
        }
        return [pscustomobject]@{
            Title  = 'Grok'
            Badge  = '本地同步'
            Status = $status
            Rows   = @((New-Row '周额度' (Format-Percent $remaining) ([string]$resetText)))
            Error  = $false
        }
    }

    $rows = New-Object System.Collections.ArrayList
    $windows = Get-JsonValue $data 'windows'
    foreach ($window in @($windows)) {
        $title = [string](Get-JsonValue $window 'title')
        $label = $title -replace '额度$', ''
        if ([string]::IsNullOrWhiteSpace($label)) {
            $label = '窗口'
        }
        [void]$rows.Add((New-Row $label (Format-Percent (Get-JsonValue $window 'remainingPercent')) ([string](Get-JsonValue $window 'resetText'))))
    }

    $isLive = [bool](Get-JsonValue $data 'isLive')
    $source = [string](Get-JsonValue $data 'source')
    $updatedAt = [string](Get-JsonValue $data 'updatedAt')
    $liveSources = @('official_console_browser', 'official_console_background')
    if ($isLive -and $liveSources -contains $source) {
        try {
            $age = [DateTime]::UtcNow - [DateTime]::Parse($updatedAt).ToUniversalTime()
            if ($age.TotalMinutes -gt 10) {
                $isLive = $false
            }
        }
        catch {
            $isLive = $false
        }
    }
    $badge = if ($isLive) { '实时' } else { '页面快照' }
    $updatedText = Format-UpdatedText $updatedAt
    if ($updatedText -eq '等待同步') {
        $status = $updatedText
    }
    elseif ($liveSources -contains $source -and -not $isLive) {
        $status = $updatedText -replace '^已同步 ', '上次同步 '
    }
    else {
        $status = $updatedText -replace '^已同步 ', '同步 '
    }

    return [pscustomobject]@{
        Title  = 'OpenCode Go'
        Badge  = $badge
        Status = $status
        Rows   = @($rows.ToArray())
        Error  = $false
    }
}

if ($SelfTest) {
    Write-Output 'QUOTA_FUSION_HOST_SELFTEST_PASS'
    Write-Output ('PROVIDERS=' + (($script:Profiles.Keys -join ',')))
    foreach ($id in $script:Profiles.Keys) {
        Write-Output ($id + '_DATA=' + $script:DataDefaults[$id])
        if ($script:Profiles[$id].Kind -eq 'custom') {
            $model = Get-UiModel $id
            Write-Output ($id + '_ROWS=' + @($model.Rows).Count)
            Write-Output ($id + '_TITLE=' + $model.Title)
        }
    }
    exit 0
}

function Get-RemainingColor {
    param($Value)
    $number = Get-PercentNumber $Value
    if ($null -eq $number) {
        return [System.Drawing.Color]::FromArgb(220, 230, 236)
    }
    if ($number -le 10) {
        return [System.Drawing.Color]::FromArgb(255, 116, 126)
    }
    if ($number -le 30) {
        return [System.Drawing.Color]::FromArgb(255, 204, 102)
    }
    return [System.Drawing.Color]::FromArgb(190, 245, 220)
}

function Get-SafeText {
    param([string]$Text, [int]$MaxLength = 24)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    # The cards now reserve enough width for the real reset/status text. Let
    # DrawString clip at the card edge instead of injecting an ellipsis into
    # Chinese text that is still readable on the wider layout.
    return $Text
}

function Draw-Text {
    param(
        $Graphics,
        [string]$Text,
        [float]$X,
        [float]$Y,
        [float]$Width,
        [float]$Height,
        $Font,
        $Color,
        [System.Drawing.StringAlignment]$Alignment = [System.Drawing.StringAlignment]::Near
    )

    $brush = New-Object System.Drawing.SolidBrush($Color)
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = $Alignment
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $format.Trimming = [System.Drawing.StringTrimming]::None
    $layout = New-Object System.Drawing.RectangleF($X, $Y, $Width, $Height)
    $Graphics.DrawString([string]$Text, $Font, $brush, $layout, $format)
    $format.Dispose()
    $brush.Dispose()
}

function New-PanelPath {
    param([int]$Width, [int]$Height, [int]$Radius, [string[]]$SquareSides)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = [Math]::Min($Radius, [Math]::Min([int]($Width / 2), [int]($Height / 2)))
    $squareLeft = $SquareSides -contains 'Left'
    $squareRight = $SquareSides -contains 'Right'
    $squareTop = $SquareSides -contains 'Top'
    $squareBottom = $SquareSides -contains 'Bottom'

    if ($squareLeft -or $squareTop) { [void]$path.AddLine(0, 0, $Width - $r, 0) } else { [void]$path.AddLine($r, 0, $Width - $r, 0) }
    if ($squareRight -or $squareTop) { [void]$path.AddLine($Width - $r, 0, $Width, 0); [void]$path.AddLine($Width, 0, $Width, $r) } else { [void]$path.AddArc($Width - (2 * $r), 0, 2 * $r, 2 * $r, 270, 90) }
    [void]$path.AddLine($Width, $r, $Width, $Height - $r)
    if ($squareRight -or $squareBottom) { [void]$path.AddLine($Width, $Height - $r, $Width, $Height); [void]$path.AddLine($Width, $Height, $Width - $r, $Height) } else { [void]$path.AddArc($Width - (2 * $r), $Height - (2 * $r), 2 * $r, 2 * $r, 0, 90) }
    [void]$path.AddLine($Width - $r, $Height, $r, $Height)
    if ($squareBottom -or $squareLeft) { [void]$path.AddLine($r, $Height, 0, $Height); [void]$path.AddLine(0, $Height, 0, $Height - $r) } else { [void]$path.AddArc(0, $Height - (2 * $r), 2 * $r, 2 * $r, 90, 90) }
    [void]$path.AddLine(0, $Height - $r, 0, $r)
    if ($squareLeft -or $squareTop) { [void]$path.AddLine(0, $r, 0, 0); [void]$path.AddLine(0, 0, $r, 0) } else { [void]$path.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90) }
    $path.CloseFigure()
    return $path
}

function Get-ProviderVariant {
    param([string]$Provider)
    switch ($Provider) {
        'codex' { return 'round' }
        'grok' { return 'diamond' }
        default { return 'wave' }
    }
}

function Get-SeamVariant {
    param([int]$Index)
    @('round', 'diamond', 'wave')[$Index % 3]
}

function Add-LegoConnector {
    param(
        $Path,
        [int]$Width,
        [int]$Height,
        [string]$Side,
        [string]$Kind,
        [string]$Variant
    )
    if ([string]::IsNullOrWhiteSpace($Kind) -or $Kind -eq 'none') {
        return
    }

    $mid = [single]($Height / 2)
    $span = if ($Variant -eq 'diamond') { 20 } else { 18 }
    $depth = if ($Variant -eq 'diamond') { 8 } else { 7 }
    $y1 = $mid - ($span / 2)
    $y2 = $mid + ($span / 2)
    $out = if ($Kind -eq 'tab') { 1 } else { -1 }
    if ($Side -eq 'Left') {
        $out = -$out
    }

    if ($Side -eq 'Right') {
        [void]$Path.AddLine([single]$Width, $y1, [single]($Width + ($out * $depth)), $y1)
        if ($Variant -eq 'diamond') {
            [void]$Path.AddLine([single]($Width + ($out * $depth)), $y1, [single]($Width + ($out * ($depth + 4))), ($mid - 4))
            [void]$Path.AddLine([single]($Width + ($out * ($depth + 4))), ($mid - 4), [single]($Width + ($out * $depth)), $mid)
            [void]$Path.AddLine([single]($Width + ($out * $depth)), $mid, [single]($Width + ($out * ($depth + 4))), ($mid + 4))
            [void]$Path.AddLine([single]($Width + ($out * ($depth + 4))), ($mid + 4), [single]($Width + ($out * $depth)), $y2)
        }
        else {
            [void]$Path.AddBezier(
                [single]($Width + ($out * $depth)), $y1,
                [single]($Width + ($out * ($depth + 4))), $y1,
                [single]($Width + ($out * ($depth + 4))), ($mid - 4),
                [single]($Width + ($out * $depth)), $mid
            )
            [void]$Path.AddBezier(
                [single]($Width + ($out * $depth)), $mid,
                [single]($Width + ($out * ($depth + 4))), ($mid + 4),
                [single]($Width + ($out * ($depth + 4))), $y2,
                [single]($Width + ($out * $depth)), $y2
            )
        }
        [void]$Path.AddLine([single]($Width + ($out * $depth)), $y2, [single]$Width, $y2)
    }
    else {
        [void]$Path.AddLine(0, $y2, [single]($out * $depth), $y2)
        if ($Variant -eq 'diamond') {
            [void]$Path.AddLine([single]($out * $depth), $y2, [single]($out * ($depth + 4)), ($mid + 4))
            [void]$Path.AddLine([single]($out * ($depth + 4)), ($mid + 4), [single]($out * $depth), $mid)
            [void]$Path.AddLine([single]($out * $depth), $mid, [single]($out * ($depth + 4)), ($mid - 4))
            [void]$Path.AddLine([single]($out * ($depth + 4)), ($mid - 4), [single]($out * $depth), $y1)
        }
        else {
            [void]$Path.AddBezier(
                [single]($out * $depth), $y2,
                [single]($out * ($depth + 4)), $y2,
                [single]($out * ($depth + 4)), ($mid + 4),
                [single]($out * $depth), $mid
            )
            [void]$Path.AddBezier(
                [single]($out * $depth), $mid,
                [single]($out * ($depth + 4)), ($mid - 4),
                [single]($out * ($depth + 4)), $y1,
                [single]($out * $depth), $y1
            )
        }
        [void]$Path.AddLine([single]($out * $depth), $y1, 0, $y1)
    }
}

function New-LegoPanelPath {
    param(
        [int]$Width,
        [int]$Height,
        [int]$Radius,
        [string]$LeftConnector = 'none',
        [string]$RightConnector = 'none',
        [string]$LeftVariant = 'round',
        [string]$RightVariant = 'round'
    )
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = [Math]::Min($Radius, [Math]::Min([int]($Width / 2), [int]($Height / 2)))
    $mid = [int]($Height / 2)
    $span = 20

    [void]$path.AddLine([single]$r, 0, [single]($Width - $r), 0)
    [void]$path.AddArc($Width - (2 * $r), 0, 2 * $r, 2 * $r, 270, 90)
    if ($RightConnector -eq 'none') {
        [void]$path.AddLine([single]$Width, [single]$r, [single]$Width, [single]($Height - $r))
    }
    else {
        [void]$path.AddLine([single]$Width, [single]$r, [single]$Width, [single]($mid - ($span / 2)))
        Add-LegoConnector $path $Width $Height 'Right' $RightConnector $RightVariant
        [void]$path.AddLine([single]$Width, [single]($mid + ($span / 2)), [single]$Width, [single]($Height - $r))
    }
    [void]$path.AddArc($Width - (2 * $r), $Height - (2 * $r), 2 * $r, 2 * $r, 0, 90)
    [void]$path.AddLine([single]($Width - $r), [single]$Height, [single]$r, [single]$Height)
    [void]$path.AddArc(0, $Height - (2 * $r), 2 * $r, 2 * $r, 90, 90)
    if ($LeftConnector -eq 'none') {
        [void]$path.AddLine(0, [single]($Height - $r), 0, [single]$r)
    }
    else {
        [void]$path.AddLine(0, [single]($Height - $r), 0, [single]($mid + ($span / 2)))
        Add-LegoConnector $path $Width $Height 'Left' $LeftConnector $LeftVariant
        [void]$path.AddLine(0, [single]($mid - ($span / 2)), 0, [single]$r)
    }
    [void]$path.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90)
    $path.CloseFigure()
    return $path
}

function Get-AccentColor {
    param($Accent, [int]$Alpha = 255)
    return [System.Drawing.Color]::FromArgb($Alpha, $Accent[0], $Accent[1], $Accent[2])
}

function Get-BrandImage {
    param([string]$Provider)
    $providerKey = ([string]$Provider).ToLowerInvariant()
    if ($script:BrandImages.ContainsKey($providerKey)) {
        return ,$script:BrandImages[$providerKey]
    }
    if (-not $script:BrandImagePaths.ContainsKey($providerKey)) {
        return $null
    }
    $path = $script:BrandImagePaths[$providerKey]
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    try {
        $image = [System.Drawing.Image]::FromFile($path)
        $script:BrandImages[$providerKey] = $image
        return ,$image
    }
    catch {
        Write-Log $paintLog ('brand image: ' + $providerKey + ' ' + ($_ | Out-String))
        return $null
    }
}

function Draw-BrandMark {
    param(
        $Graphics,
        [string]$Provider,
        [float]$X,
        [float]$Y,
        [float]$Size,
        $Accent
    )

    $image = Get-BrandImage $Provider
    if ($null -eq $image) {
        return
    }
    $providerKey = ([string]$Provider).ToLowerInvariant()
    $scale = if ($script:BrandRenderScales.ContainsKey($providerKey)) { [single]$script:BrandRenderScales[$providerKey] } else { [single]1.0 }
    $renderSize = [single]($Size * $scale)
    $renderX = [single]($X + (($Size - $renderSize) / 2))
    $renderY = [single]($Y + (($Size - $renderSize) / 2))
    $state = $Graphics.Save()
    try {
        $Graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $Graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $Graphics.DrawImage($image, $renderX, $renderY, $renderSize, $renderSize)
    }
    finally {
        $Graphics.Restore($state)
    }
}

function Draw-Card {
    param(
        $Graphics,
        $Card,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [string]$LeftConnector = 'none',
        [string]$RightConnector = 'none',
        [string]$LeftVariant = 'round',
        [string]$RightVariant = 'round',
        [bool]$Fused
    )
    $accent = $Card.Accent
    # v2 uses clean rounded tiles. Connector parameters are kept for compatibility
    # with the layout records, but the visual surface no longer has tabs/notches.
    $path = New-PanelPath $W $H 20 @()
    $active = $false
    $owner = $Card.Window
    if ($null -ne $owner -and $script:DragState.ContainsKey($owner)) {
        $drag = $script:DragState[$owner]
        $active = ($null -ne $drag -and $drag.Mode -eq 'Reorder' -and $drag.Card -eq $Card)
    }
    $surfaceAlpha = if ($active) { 248 } else { 236 }
    $surfaceBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($surfaceAlpha, 22, 28, 40))
    $borderWidth = if ($active) { 1.8 } else { 1.0 }
    $borderAlpha = if ($active) { 230 } else { 170 }
    $borderPen = New-Object System.Drawing.Pen((Get-AccentColor $accent $borderAlpha), $borderWidth)
    $Graphics.TranslateTransform($X, $Y)
    $Graphics.FillPath($surfaceBrush, $path)
    $Graphics.DrawPath($borderPen, $path)
    $Graphics.ResetTransform()
    $surfaceBrush.Dispose()
    $borderPen.Dispose()
    $path.Dispose()

    $fontTitle = New-HostFont 'Segoe UI Semibold' 30 ([System.Drawing.FontStyle]::Bold)
    $fontBody = New-HostFont 'Microsoft YaHei UI' 26
    $fontRowValue = New-HostFont 'Segoe UI Semibold' 28 ([System.Drawing.FontStyle]::Bold)
    # Keep the percentage visually large, but reserve enough horizontal room
    # for the percent glyph itself instead of clipping it at the old 108px box.
    $fontValue = New-HostFont 'Segoe UI Semibold' 54 ([System.Drawing.FontStyle]::Bold)
    $fontMeta = New-HostFont 'Microsoft YaHei UI' 24
    $fontReset = New-HostFont 'Microsoft YaHei UI' 20
    $fontButton = New-HostFont 'Segoe UI' 26

    $titleColor = [System.Drawing.Color]::FromArgb(248, 250, 255)
    $muted = [System.Drawing.Color]::FromArgb(157, 171, 190)
    $soft = [System.Drawing.Color]::FromArgb(211, 220, 232)
    $buttonColor = [System.Drawing.Color]::FromArgb(197, 208, 222)
    $statusColor = if ($Card.Model.Error) { [System.Drawing.Color]::FromArgb(255, 145, 150) } else { $muted }

    $model = $Card.Model
    if ($null -eq $model) {
        $model = Get-UiModel $Card.Provider
        $Card.Model = $model
    }

    Draw-BrandMark $Graphics $Card.Provider ($X + 16) ($Y + 10) 34 $accent
    Draw-Text $Graphics (Get-SafeText $model.Title 16) ($X + 62) ($Y + 7) ($W - 176) 42 $fontTitle $titleColor
    if ($Fused) {
        # A fused card is split by dragging it outside the host window.
        # Keep only the close affordance in the card header.
        Draw-Text $Graphics '×' ($X + $W - 42) ($Y + 8) 32 36 $fontButton $buttonColor ([System.Drawing.StringAlignment]::Center)
    }
    else {
        Draw-Text $Graphics '–' ($X + $W - 82) ($Y + 8) 32 36 $fontButton $buttonColor ([System.Drawing.StringAlignment]::Center)
        Draw-Text $Graphics '×' ($X + $W - 42) ($Y + 8) 32 36 $fontButton $buttonColor ([System.Drawing.StringAlignment]::Center)
    }

    Draw-Text $Graphics (Get-SafeText $model.Badge 16) ($X + 16) ($Y + 54) ($W - 32) 28 $fontMeta $muted

    $rows = @($model.Rows)
    $isMultiRow = ($Card.Provider -eq 'opencode' -or $Card.Profile.Kind -eq 'custom')
    if ($isMultiRow) {
        $rowY = $Y + 94
        foreach ($row in $rows) {
            Draw-Text $Graphics (Get-SafeText $row.Label 12) ($X + 16) $rowY 120 42 $fontBody $soft
            Draw-Text $Graphics $row.Remaining ($X + 140) ($rowY - 2) 110 44 $fontRowValue (Get-RemainingColor $row.RemainingNumber) ([System.Drawing.StringAlignment]::Far)
            Draw-Text $Graphics (Get-SafeText $row.ResetText 16) ($X + 264) ($rowY + 1) ($W - 280) 38 $fontReset $muted ([System.Drawing.StringAlignment]::Far)
            $rowY += 60
        }
        $statusY = $Y + $H - 46
    }
    else {
        $row = if ($rows.Count -gt 0) { $rows[0] } else { New-Row '周额度' '--' '读取中' }
        Draw-Text $Graphics $row.Label ($X + 16) ($Y + 86) 84 36 $fontBody $soft
        Draw-Text $Graphics $row.Remaining ($X + 100) ($Y + 66) 160 72 $fontValue (Get-RemainingColor $row.RemainingNumber)
        Draw-Text $Graphics (Get-SafeText $row.ResetText 15) ($X + 270) ($Y + 86) ($W - 286) 36 $fontReset $muted ([System.Drawing.StringAlignment]::Far)
        $statusY = $Y + $H - 46
        $progress = Get-PercentNumber $row.RemainingNumber
        if ($null -ne $progress) {
            $track = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(44, 255, 255, 255))
            $Graphics.FillRectangle($track, ($X + 16), ($Y + 160), ($W - 32), 8)
            $track.Dispose()
            $fill = New-Object System.Drawing.SolidBrush((Get-RemainingColor $progress))
            $fillWidth = [Math]::Max(2, [int](($W - 32) * $progress / 100))
            $Graphics.FillRectangle($fill, ($X + 16), ($Y + 160), $fillWidth, 8)
            $fill.Dispose()
        }
    }

    $status = Get-SafeText $model.Status 32
    Draw-Text $Graphics $status ($X + 16) $statusY ($W - 32) 32 $fontMeta $statusColor

    $fontTitle.Dispose()
    $fontBody.Dispose()
    $fontRowValue.Dispose()
    $fontValue.Dispose()
    $fontMeta.Dispose()
    $fontReset.Dispose()
    $fontButton.Dispose()
}

function Draw-Minimized {
    param($Graphics, $Form, $Cards)
    $W = $Form.ClientSize.Width
    $H = $Form.ClientSize.Height
    $accent = $Cards[0].Accent
    $path = New-PanelPath $W $H 16 @()
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(236, 22, 28, 38))
    $pen = New-Object System.Drawing.Pen((Get-AccentColor $accent 150), 1)
    $Graphics.FillPath($brush, $path)
    $Graphics.DrawPath($pen, $path)
    $brush.Dispose()
    $pen.Dispose()
    $path.Dispose()

    $fontTitle = New-HostFont 'Microsoft YaHei UI' 22 ([System.Drawing.FontStyle]::Bold)
    $fontBody = New-HostFont 'Microsoft YaHei UI' 20
    $fontButton = New-HostFont 'Segoe UI' 24
    $titleColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $soft = [System.Drawing.Color]::FromArgb(205, 214, 224)
    $buttonColor = [System.Drawing.Color]::FromArgb(190, 200, 212)

    if ($Cards.Count -gt 1) {
        Draw-Text $Graphics ('额度融合 · ' + $Cards.Count) 16 8 ($W - 150) 36 $fontTitle $titleColor
    }
    else {
        Draw-BrandMark $Graphics $Cards[0].Provider 12 11 28 $accent
        Draw-Text $Graphics $Cards[0].Title 48 8 ($W - 154) 36 $fontTitle $titleColor
    }
    Draw-Text $Graphics '–' ($W - 82) 9 32 34 $fontButton $buttonColor ([System.Drawing.StringAlignment]::Center)
    Draw-Text $Graphics '×' ($W - 42) 9 32 34 $fontButton $buttonColor ([System.Drawing.StringAlignment]::Center)

    if ($Cards.Count -eq 1) {
        $rows = @($Cards[0].Model.Rows)
        $value = if ($rows.Count -gt 0) { $rows[0].Remaining } else { '--' }
        Draw-Text $Graphics $value ($W - 132) 10 100 32 $fontBody $soft ([System.Drawing.StringAlignment]::Far)
    }
    else {
        Draw-Text $Graphics (($Cards.Count.ToString()) + ' 个窗口') ($W - 132) 10 100 32 $fontBody $soft ([System.Drawing.StringAlignment]::Far)
    }

    $fontTitle.Dispose()
    $fontBody.Dispose()
    $fontButton.Dispose()
}

function Get-FusionMetrics {
    return @{
        Pad = 20
        Gap = 16
        Strip = 56
    }
}

function Get-FusedLayout {
    param($Cards)
    $metrics = Get-FusionMetrics
    $pad = $metrics.Pad
    $gap = $metrics.Gap
    $strip = $metrics.Strip
    $widths = @($Cards | ForEach-Object { [int]$_.Profile.Width })
    $heights = @($Cards | ForEach-Object { [int]$_.Profile.Height })
    $sumW = ($widths | Measure-Object -Sum).Sum + $gap * ($Cards.Count - 1) + $pad * 2
    $maxH = ($heights | Measure-Object -Maximum).Maximum
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($sumW -le [Math]::Max(420, [int]($area.Width * 0.9))) {
        $W = [Math]::Ceiling($sumW)
        $H = [Math]::Ceiling($strip + $pad + $maxH + $pad)
        return @{ Width = [int]$W; Height = [int]$H; Vertical = $false }
    }
    $maxW = ($widths | Measure-Object -Maximum).Maximum
    $sumH = ($heights | Measure-Object -Sum).Sum + $gap * ($Cards.Count - 1) + $pad * 2
    return @{ Width = [int][Math]::Ceiling($maxW + $pad * 2); Height = [int][Math]::Ceiling($strip + $sumH); Vertical = $true }
}

function Get-CardRegions {
    param($Form)
    $cards = @($script:FormCards[$Form])
    $regions = New-Object System.Collections.ArrayList
    if ($cards.Count -eq 0) {
        return @($regions.ToArray())
    }
    if ($cards.Count -eq 1) {
        [void]$regions.Add([pscustomobject]@{
            Card = $cards[0]
            X = 0
            Y = 0
            W = $Form.ClientSize.Width
            H = $Form.ClientSize.Height
            Square = @()
        })
        return @($regions.ToArray())
    }

    $layout = Get-FusedLayout $cards
    $metrics = Get-FusionMetrics
    $pad = $metrics.Pad
    $gap = $metrics.Gap
    $strip = $metrics.Strip
    $count = $cards.Count

    if (-not $layout.Vertical) {
        $maxH = ($cards | ForEach-Object { [int]$_.Profile.Height } | Measure-Object -Maximum).Maximum
        $x = $pad
        $cardTop = $strip + $pad
        for ($i = 0; $i -lt $count; $i++) {
            $w = [int]$cards[$i].Profile.Width
            $h = [int]$cards[$i].Profile.Height
            $y = $cardTop + [int](($maxH - $h) / 2)
            $leftVariant = if ($i -gt 0) { Get-SeamVariant ($i - 1) } else { Get-ProviderVariant $cards[$i].Provider }
            $rightVariant = if ($i -lt ($count - 1)) { Get-SeamVariant $i } else { Get-ProviderVariant $cards[$i].Provider }
            $leftConnector = if ($i -gt 0) { 'socket' } else { 'tab' }
            $rightConnector = if ($i -lt ($count - 1)) { 'tab' } else { 'socket' }
            [void]$regions.Add([pscustomobject]@{
                Card = $cards[$i]
                X = $x
                Y = $y
                W = $w
                H = $h
                Square = @()
                LeftConnector = $leftConnector
                RightConnector = $rightConnector
                LeftVariant = $leftVariant
                RightVariant = $rightVariant
            })
            $x += $w + $gap
        }
    }
    else {
        $maxW = ($cards | ForEach-Object { [int]$_.Profile.Width } | Measure-Object -Maximum).Maximum
        $y = $strip + $pad
        for ($i = 0; $i -lt $count; $i++) {
            $w = [int]$cards[$i].Profile.Width
            $h = [int]$cards[$i].Profile.Height
            $x = $pad + [int](($maxW - $w) / 2)
            $leftVariant = Get-ProviderVariant $cards[$i].Provider
            $rightVariant = Get-ProviderVariant $cards[$i].Provider
            [void]$regions.Add([pscustomobject]@{
                Card = $cards[$i]
                X = $x
                Y = $y
                W = $w
                H = $h
                Square = @()
                LeftConnector = 'tab'
                RightConnector = 'socket'
                LeftVariant = $leftVariant
                RightVariant = $rightVariant
            })
            $y += $h + $gap
        }
    }

    return @($regions.ToArray())
}

function Draw-Window {
    param($Form, $Graphics)
    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # The host form is translucent. ClearType assumes an opaque background and
    # can leave colored fringes after layered-window compositing; grayscale
    # antialiasing keeps the text edges cleaner in the actual floaters.
    $Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $cards = @($script:FormCards[$Form])
    if ($cards.Count -eq 0) {
        return
    }
    $W = $Form.ClientSize.Width
    $H = $Form.ClientSize.Height

    $dockState = $script:DockState[$Form]
    if ($null -ne $dockState -and $dockState.Docked -and @('Left', 'Right', 'Top') -contains [string]$dockState.Edge) {
        $handlePath = New-DockHandlePath $Form ([string]$dockState.Edge)
        $handleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(228, 18, 24, 35))
        $handlePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(138, 255, 255, 255), 1)
        $Graphics.FillPath($handleBrush, $handlePath)
        $Graphics.DrawPath($handlePen, $handlePath)
        $handleRectangle = Get-DockHandleRectangle $Form ([string]$dockState.Edge)
        $gripPen = New-Object System.Drawing.Pen((Get-AccentColor $cards[0].Accent 220), 2.2)
        if ($dockState.Edge -eq 'Top') {
            $gripX1 = [int]($handleRectangle.X + (($handleRectangle.Width - 48) / 2))
            $gripX2 = $gripX1 + 48
            $gripY = [int]($handleRectangle.Y + ($handleRectangle.Height / 2))
            $Graphics.DrawLine($gripPen, $gripX1, $gripY, $gripX2, $gripY)
        }
        else {
            $gripY1 = [int]($handleRectangle.Y + (($handleRectangle.Height - 48) / 2))
            $gripY2 = $gripY1 + 48
            $gripX = [int]($handleRectangle.X + ($handleRectangle.Width / 2))
            $Graphics.DrawLine($gripPen, $gripX, $gripY1, $gripX, $gripY2)
        }
        $gripPen.Dispose()
        $handlePen.Dispose()
        $handleBrush.Dispose()
        $handlePath.Dispose()
        return
    }

    $outerPath = New-PanelPath $W $H 24 @()
    $outerBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 12, 17, 27))
    $outerPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(118, 255, 255, 255), 1)
    $Graphics.FillPath($outerBrush, $outerPath)
    $Graphics.DrawPath($outerPen, $outerPath)
    $outerBrush.Dispose()
    $outerPen.Dispose()
    $outerPath.Dispose()

    if ($script:Minimized[$Form]) {
        Draw-Minimized $Graphics $Form $cards
        return
    }

    if ($cards.Count -eq 1) {
        Draw-Card $Graphics $cards[0] 0 0 $W $H 'none' 'none' 'round' 'round' $false
    }
    else {
        $metrics = Get-FusionMetrics
        $strip = $metrics.Strip
        $accent = $cards[0].Accent
        $fontTitle = New-HostFont 'Segoe UI Semibold' 28 ([System.Drawing.FontStyle]::Bold)
        $fontMeta = New-HostFont 'Microsoft YaHei UI' 22
        $fontButton = New-HostFont 'Segoe UI' 26
        $titleColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
        $buttonColor = [System.Drawing.Color]::FromArgb(190, 200, 212)
        $stripBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(198, 16, 22, 34))
        $Graphics.FillRectangle($stripBrush, 0, 0, $W, $strip)
        $stripBrush.Dispose()
        Draw-Text $Graphics ('额度融合 · ' + $cards.Count) 20 8 220 40 $fontTitle $titleColor
        Draw-Text $Graphics '拖卡片排序' ($W - 236) 11 142 32 $fontMeta ([System.Drawing.Color]::FromArgb(143, 162, 183)) ([System.Drawing.StringAlignment]::Far)
        Draw-Text $Graphics '–' ($W - 82) 10 32 34 $fontButton $buttonColor ([System.Drawing.StringAlignment]::Center)
        Draw-Text $Graphics '×' ($W - 42) 10 32 34 $fontButton $buttonColor ([System.Drawing.StringAlignment]::Center)
        foreach ($region in (Get-CardRegions $Form)) {
            Draw-Card $Graphics $region.Card $region.X $region.Y $region.W $region.H $region.LeftConnector $region.RightConnector $region.LeftVariant $region.RightVariant $true
        }
        $drag = $script:DragState[$Form]
        if ($null -ne $drag -and $drag.Mode -eq 'Reorder' -and $drag.Moved -and -not $drag.DetachOutside -and $drag.ReorderIndex -ge 0) {
            $regions = @(Get-CardRegions $Form)
            $markerPen = New-Object System.Drawing.Pen((Get-AccentColor $drag.Card.Accent 230), 2.5)
            if ($regions.Count -gt 0) {
                if ($drag.ReorderIndex -lt $regions.Count) {
                    $target = $regions[$drag.ReorderIndex]
                    $markerX = [int]($target.X - 4)
                    $Graphics.DrawLine($markerPen, $markerX, $target.Y + 8, $markerX, $target.Y + $target.H - 8)
                }
                else {
                    $target = $regions[$regions.Count - 1]
                    $markerX = [int]($target.X + $target.W + 4)
                    $Graphics.DrawLine($markerPen, $markerX, $target.Y + 8, $markerX, $target.Y + $target.H - 8)
                }
            }
            $markerPen.Dispose()
        }
        $fontTitle.Dispose()
        $fontMeta.Dispose()
        $fontButton.Dispose()
    }

    $fx = [double]$script:FusionFx[$Form]
    if ($fx -gt 0) {
        $accent = $cards[0].Accent
        $alpha = [Math]::Min(255, [int](150 * $fx))
        $pulsePath = New-PanelPath $W $H 24 @()
        $pen = New-Object System.Drawing.Pen((Get-AccentColor $accent $alpha), (1.5 + 3.5 * $fx))
        $Graphics.DrawPath($pen, $pulsePath)
        $pen.Dispose()
        $pulsePath.Dispose()
    }
}

function Get-HitAction {
    param($Form, [int]$X, [int]$Y)
    $cards = @($script:FormCards[$Form])
    if ($cards.Count -eq 0) {
        return ''
    }
    $W = $Form.ClientSize.Width

    if ($script:Minimized[$Form]) {
        if ($X -ge ($W - 42)) { return 'CloseWindow' }
        if ($X -ge ($W - 82)) { return 'MinimizeWindow' }
        return 'Expand'
    }

    if ($cards.Count -eq 1) {
        if ($Y -le 56) {
            if ($X -ge ($W - 42)) { return 'CloseWindow' }
            if ($X -ge ($W - 82)) { return 'MinimizeWindow' }
        }
        return 'Drag'
    }

    if ($Y -le 56) {
        if ($X -ge ($W - 42)) { return 'CloseWindow' }
        if ($X -ge ($W - 82)) { return 'MinimizeWindow' }
        return 'Drag'
    }

    foreach ($region in (Get-CardRegions $Form)) {
        if ($X -ge $region.X -and $X -le ($region.X + $region.W) -and $Y -ge $region.Y -and $Y -le ($region.Y + $region.H)) {
            if ($Y -ge ($region.Y + 8) -and $Y -le ($region.Y + 48)) {
                if ($X -ge ($region.X + $region.W - 42) -and $X -le ($region.X + $region.W - 6)) { return 'CloseCard' }
            }
            break
        }
    }
    return 'Drag'
}

function Get-HitCard {
    param($Form, [int]$X, [int]$Y)
    foreach ($region in (Get-CardRegions $Form)) {
        if ($X -ge $region.X -and $X -le ($region.X + $region.W) -and $Y -ge $region.Y -and $Y -le ($region.Y + $region.H)) {
            return $region.Card
        }
    }
    return $null
}

function Get-ReorderIndex {
    param($Form, $Card, [int]$X, [int]$Y)
    $cards = @($script:FormCards[$Form])
    if ($cards.Count -le 1 -or $null -eq $Card) {
        return 0
    }
    $layout = Get-FusedLayout $cards
    $regions = @(Get-CardRegions $Form)
    $axis = if ($layout.Vertical) { $Y } else { $X }
    $targetIndex = 0
    foreach ($region in $regions) {
        if ($region.Card -eq $Card) {
            continue
        }
        $center = if ($layout.Vertical) { $region.Y + ($region.H / 2) } else { $region.X + ($region.W / 2) }
        if ($axis -gt $center) {
            $targetIndex++
        }
    }
    return [int][Math]::Max(0, [Math]::Min($cards.Count - 1, $targetIndex))
}

function Move-CardOrder {
    param($Form, $Card, [int]$TargetIndex)
    $cards = @($script:FormCards[$Form])
    if ($cards.Count -le 1 -or $null -eq $Card) {
        return
    }
    $ordered = New-Object System.Collections.ArrayList
    foreach ($item in $cards) {
        if ($item -ne $Card) {
            [void]$ordered.Add($item)
        }
    }
    $safeIndex = [Math]::Max(0, [Math]::Min($ordered.Count, $TargetIndex))
    $ordered.Insert($safeIndex, $Card)
    $script:FormCards[$Form] = $ordered
    Start-FusionPulse $Form
    $Form.Invalidate()
}

function Get-WorkingArea {
    return [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
}

function Test-PointOutsideForm {
    param(
        $Form,
        [System.Drawing.Point]$ScreenPoint,
        [int]$Margin = 12
    )
    if ($null -eq $Form -or $Form.IsDisposed) {
        return $false
    }
    $clientPoint = $Form.PointToClient($ScreenPoint)
    return ($clientPoint.X -lt (-1 * $Margin) -or
        $clientPoint.Y -lt (-1 * $Margin) -or
        $clientPoint.X -gt ($Form.ClientSize.Width + $Margin) -or
        $clientPoint.Y -gt ($Form.ClientSize.Height + $Margin))
}

function Get-DetachedLocation {
    param(
        $Card,
        [System.Drawing.Point]$DesiredLocation
    )
    $area = Get-WorkingArea
    $width = [int]$Card.Profile.Width
    $height = [int]$Card.Profile.Height
    $maxX = [Math]::Max($area.Left, $area.Right - $width)
    $maxY = [Math]::Max($area.Top, $area.Bottom - $height)
    $x = [int][Math]::Max($area.Left, [Math]::Min($DesiredLocation.X, $maxX))
    $y = [int][Math]::Max($area.Top, [Math]::Min($DesiredLocation.Y, $maxY))
    return New-Object System.Drawing.Point($x, $y)
}

function Update-WindowRegion {
    param($Form)
    if ($null -eq $Form -or $Form.IsDisposed) {
        return
    }
    $state = $script:DockState[$Form]
    if ($null -ne $state -and $state.Docked -and @('Left', 'Right', 'Top') -contains [string]$state.Edge) {
        $path = New-DockHandlePath $Form ([string]$state.Edge)
    }
    else {
        $path = New-PanelPath $Form.ClientSize.Width $Form.ClientSize.Height 24 @()
    }
    $newRegion = New-Object System.Drawing.Region($path)
    $oldRegion = $Form.Region
    $Form.Region = $newRegion
    if ($null -ne $oldRegion) {
        $oldRegion.Dispose()
    }
    $path.Dispose()
}

function New-RoundedRectanglePath {
    param(
        [System.Drawing.Rectangle]$Rectangle,
        [int]$Radius = 8
    )
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = [Math]::Min($Radius, [Math]::Min([int]($Rectangle.Width / 2), [int]($Rectangle.Height / 2)))
    $d = [int](2 * $r)
    $x = [int]$Rectangle.X
    $y = [int]$Rectangle.Y
    $w = [int]$Rectangle.Width
    $h = [int]$Rectangle.Height
    [void]$path.AddArc($x, $y, $d, $d, 180, 90)
    [void]$path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    [void]$path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    [void]$path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-ToolStripRoundedRegion {
    param(
        $Menu,
        [int]$Radius = 14
    )
    if ($null -eq $Menu -or $Menu.IsDisposed -or $Menu.Width -le 0 -or $Menu.Height -le 0) {
        return
    }
    $path = New-RoundedRectanglePath (New-Object System.Drawing.Rectangle(0, 0, $Menu.Width, $Menu.Height)) $Radius
    try {
        $oldRegion = $Menu.Region
        $Menu.Region = New-Object System.Drawing.Region($path)
        if ($null -ne $oldRegion) {
            $oldRegion.Dispose()
        }
    }
    finally {
        $path.Dispose()
    }
}

function Get-DockHandleRectangle {
    param(
        $Form,
        [string]$Edge
    )
    $width = [int]$Form.ClientSize.Width
    $height = [int]$Form.ClientSize.Height
    $depth = [int][Math]::Min(
        $script:DockPeekDepth,
        [Math]::Max(1, [Math]::Min($width, $height))
    )
    if ($Edge -eq 'Top') {
        $axisLength = $width
    }
    else {
        $axisLength = $height
    }
    $length = [int][Math]::Min($script:DockHandleLength, [Math]::Max(1, $axisLength))
    $offset = [int][Math]::Max(0, (($axisLength - $length) / 2))
    switch ($Edge) {
        'Left' {
            return New-Object System.Drawing.Rectangle(($width - $depth), $offset, $depth, $length)
        }
        'Right' {
            return New-Object System.Drawing.Rectangle(0, $offset, $depth, $length)
        }
        'Top' {
            return New-Object System.Drawing.Rectangle($offset, ($height - $depth), $length, $depth)
        }
        default {
            return New-Object System.Drawing.Rectangle(0, 0, $width, $height)
        }
    }
}

function New-DockHandlePath {
    param(
        $Form,
        [string]$Edge
    )
    $rectangle = Get-DockHandleRectangle $Form $Edge
    if ($Edge -notin @('Left', 'Right', 'Top')) {
        return New-PanelPath $Form.ClientSize.Width $Form.ClientSize.Height 24 @()
    }
    $radius = [Math]::Min(8, [Math]::Min($rectangle.Width / 2, $rectangle.Height / 2))
    return New-RoundedRectanglePath $rectangle ([int]$radius)
}

function Get-DockHandleScreenBounds {
    param(
        $Form,
        [string]$Edge
    )
    $local = Get-DockHandleRectangle $Form $Edge
    if ($Edge -notin @('Left', 'Right', 'Top')) {
        return $Form.Bounds
    }
    return New-Object System.Drawing.Rectangle(
        ([int]$Form.Left + [int]$local.X),
        ([int]$Form.Top + [int]$local.Y),
        ([int]$local.Width),
        ([int]$local.Height)
    )
}

function Get-DockLocation {
    param($Form, [string]$Edge)
    $area = Get-WorkingArea
    # Use one consistent reveal depth on the left, top, and right edges.
    # It is slightly slimmer than the old 18px side peek, so every edge reads
    # as the same compact tab instead of making the top edge feel oversized.
    $visible = 14
    $x = $Form.Left
    $y = $Form.Top
    switch ($Edge) {
        'Left' { $x = $area.Left - $Form.Width + $visible }
        'Right' { $x = $area.Right - $visible }
        'Top' { $y = $area.Top - $Form.Height + $visible }
    }
    return New-Object System.Drawing.Point([int]$x, [int]$y)
}

function Get-RevealLocation {
    param($Form, [string]$Edge)
    $area = Get-WorkingArea
    $x = $Form.Left
    $y = $Form.Top
    switch ($Edge) {
        'Left' { $x = $area.Left }
        'Right' { $x = $area.Right - $Form.Width }
        'Top' { $y = $area.Top }
    }
    return New-Object System.Drawing.Point([int]$x, [int]$y)
}

function Schedule-AutoDock {
    param($Form, [int]$DelayMs = $script:DockHideDelayMs)
    $state = $script:DockState[$Form]
    if ($null -eq $state -or $state.Docked -or $state.ContextMenuOpen -or $state.HoldOpen -or -not $state.HoverRevealed) {
        return
    }
    $state.AutoDockAt = [datetime]::UtcNow.AddMilliseconds($DelayMs)
}

function Dock-AtEdge {
    param($Form, [string]$Edge)
    $state = $script:DockState[$Form]
    if ($null -eq $state -or [string]::IsNullOrWhiteSpace($Edge)) {
        return $false
    }
    if (@('Left', 'Right', 'Top') -notcontains $Edge) {
        return $false
    }
    $state.Docked = $true
    $state.Edge = $Edge
    $state.HoverRevealed = $false
    $state.RevealEdge = ''
    $state.AutoDockAt = $null
    $state.RevealArmed = $false
    $state.HoldOpen = $false
    $Form.Location = Get-DockLocation $Form $Edge
    Update-WindowRegion $Form
    $Form.Invalidate()
    return $true
}

function Process-AutoDock {
    $now = [datetime]::UtcNow
    $cursor = [System.Windows.Forms.Cursor]::Position
    foreach ($form in @($script:DockState.Keys)) {
        try {
            if ($null -eq $form -or $form.IsDisposed -or -not $form.Visible) {
                continue
            }
            $state = $script:DockState[$form]
            if ($null -eq $state -or $state.Docked -or $state.ContextMenuOpen -or $state.HoldOpen -or -not $state.HoverRevealed -or $null -eq $state.AutoDockAt) {
                if ($null -ne $state -and $state.Docked -and -not $state.RevealArmed) {
                    $handleBounds = Get-DockHandleScreenBounds $form ([string]$state.Edge)
                    if (-not $handleBounds.Contains($cursor)) {
                        $state.RevealArmed = $true
                    }
                }
                continue
            }
            if ($null -ne $script:DragState[$form]) {
                continue
            }
            if ($form.Bounds.Contains($cursor)) {
                $state.AutoDockAt = $now.AddMilliseconds(300)
                continue
            }
            if ($now -ge [datetime]$state.AutoDockAt) {
                [void](Dock-AtEdge $form $state.RevealEdge)
            }
        }
        catch {
            Write-Log $errorLog ('autoDock: ' + ($_ | Out-String))
        }
    }
}

function Try-DockToEdge {
    param($Form)
    $area = Get-WorkingArea
    $threshold = 12
    $edge = ''
    if ($Form.Left -le ($area.Left + $threshold)) {
        $edge = 'Left'
    }
    elseif ($Form.Right -ge ($area.Right - $threshold)) {
        $edge = 'Right'
    }
    elseif ($Form.Top -le ($area.Top + $threshold)) {
        $edge = 'Top'
    }
    if ([string]::IsNullOrWhiteSpace($edge)) {
        return $false
    }
    return Dock-AtEdge $Form $edge
}

function Restore-FromDock {
    param($Form)
    $state = $script:DockState[$Form]
    if (-not $state.Docked -or -not $state.RevealArmed) {
        return
    }
    $edge = [string]$state.Edge
    $state.Docked = $false
    $state.HoverRevealed = $true
    $state.RevealEdge = $edge
    $state.AutoDockAt = [datetime]::UtcNow.AddMilliseconds($script:DockRevealDelayMs)
    $Form.Location = Get-RevealLocation $Form $edge
    Update-WindowRegion $Form
    $Form.Invalidate()
}

function Toggle-Minimize {
    param($Form)
    if ($script:Minimized[$Form]) {
        $script:Minimized[$Form] = $false
        $Form.ClientSize = $script:Expanded[$Form]
    }
    else {
        $script:Expanded[$Form] = $Form.ClientSize
        $script:Minimized[$Form] = $true
        $Form.ClientSize = New-Object System.Drawing.Size($Form.ClientSize.Width, 52)
    }
    Update-WindowRegion $Form
    $Form.Invalidate()
}

function Keep-WindowOpen {
    param($Form)
    $state = $script:DockState[$Form]
    if ($null -eq $state) {
        return
    }
    if ($state.Docked) {
        $state.RevealArmed = $true
        Restore-FromDock $Form
    }
    $state.HoldOpen = $true
    $state.AutoDockAt = $null
    $Form.Show()
    $Form.Activate()
    $Form.Invalidate()
}

function Resume-AutoDock {
    param($Form)
    $state = $script:DockState[$Form]
    if ($null -eq $state) {
        return
    }
    $state.HoldOpen = $false
    if (-not $state.Docked -and $state.HoverRevealed) {
        Schedule-AutoDock $Form 700
    }
    $Form.Invalidate()
}

function Get-ContextForm {
    param($Source)
    if ($null -eq $Source) {
        return $null
    }
    if ($Source -is [System.Windows.Forms.ContextMenuStrip]) {
        return $Source.SourceControl
    }
    try {
        $menu = $Source.GetCurrentParent()
        if ($null -ne $menu) {
            return $menu.SourceControl
        }
    }
    catch {
    }
    return $null
}

function New-FloatContextMenu {
    param($Form)
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.ShowImageMargin = $false
    $menu.BackColor = [System.Drawing.Color]::FromArgb(36, 42, 52)
    $menu.ForeColor = [System.Drawing.Color]::FromArgb(239, 243, 249)
    $menu.AutoSize = $true
    $menu.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)
    $menu.MinimumSize = New-Object System.Drawing.Size(250, 0)
    $menu.Font = New-HostFont 'Microsoft YaHei UI' 14

    $keepItem = New-Object System.Windows.Forms.ToolStripMenuItem('保持当前展开')
    $resumeItem = New-Object System.Windows.Forms.ToolStripMenuItem('恢复自动吸附')
    $minimizeItem = New-Object System.Windows.Forms.ToolStripMenuItem('最小化 / 还原')
    $closeItem = New-Object System.Windows.Forms.ToolStripMenuItem('关闭此额度浮窗')
    [void]$menu.Items.Add($keepItem)
    [void]$menu.Items.Add($resumeItem)
    [void]$menu.Items.Add($minimizeItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($closeItem)

    $keepItem.Add_Click({
        if ($null -ne $Form -and -not $Form.IsDisposed) { Keep-WindowOpen $Form }
    }.GetNewClosure())

    $menu.Add_Opened({
        Set-ToolStripRoundedRegion $menu 16
    }.GetNewClosure())
    $resumeItem.Add_Click({
        if ($null -ne $Form -and -not $Form.IsDisposed) { Resume-AutoDock $Form }
    }.GetNewClosure())
    $minimizeItem.Add_Click({
        if ($null -ne $Form -and -not $Form.IsDisposed) { Toggle-Minimize $Form }
    }.GetNewClosure())
    $closeItem.Add_Click({
        if ($null -ne $Form -and -not $Form.IsDisposed) { $Form.Close() }
    }.GetNewClosure())

    $menu.Add_Opening({
        param($sender, $e)
        $owner = $Form
        if ($null -eq $owner -or $owner.IsDisposed) {
            $e.Cancel = $true
            return
        }
        $state = $script:DockState[$owner]
        if ($null -ne $state) {
            $state.ContextMenuOpen = $true
            $state.AutoDockAt = $null
            if ($state.Docked) {
                $state.RevealArmed = $true
                Restore-FromDock $owner
            }
        }
        $keepItem.Enabled = $null -ne $state -and -not $state.HoldOpen
        $resumeItem.Enabled = $null -ne $state -and $state.HoldOpen
        $minimizeItem.Text = if ($script:Minimized[$owner]) { '还原浮窗' } else { '最小化浮窗' }
    }.GetNewClosure())

    $menu.Add_Closing({
        param($sender, $e)
        $owner = $Form
        if ($null -eq $owner -or $owner.IsDisposed) {
            return
        }
        $state = $script:DockState[$owner]
        if ($null -ne $state) {
            $state.ContextMenuOpen = $false
            if (-not $state.HoldOpen -and -not $state.Docked -and $state.HoverRevealed) {
                Schedule-AutoDock $owner 1100
            }
        }
    }.GetNewClosure())

    return ,$menu
}

function Start-FusionPulse {
    param($Form)
    $script:FusionFx[$Form] = 1.0
    $script:PulseForms[$Form] = $true
    if ($null -eq $script:PulseTimer -or $script:PulseTimer.IsDisposed) {
        $timer = New-Object System.Windows.Forms.Timer
        $script:PulseTimer = $timer
        $timer.Interval = 35
        $timer.Add_Tick({
            try {
                foreach ($form in @($script:PulseForms.Keys)) {
                    if ($null -eq $form -or $form.IsDisposed) {
                        $script:PulseForms.Remove($form)
                        $script:FusionFx.Remove($form)
                        continue
                    }
                    $cur = [double]$script:FusionFx[$form]
                    $cur -= 0.14
                    if ($cur -le 0) {
                        $script:PulseForms.Remove($form)
                        $script:FusionFx[$form] = 0.0
                        continue
                    }
                    $script:FusionFx[$form] = $cur
                    $form.Invalidate()
                }
                if ($script:PulseForms.Count -eq 0 -and $null -ne $script:PulseTimer) {
                    $script:PulseTimer.Stop()
                    $script:PulseTimer.Dispose()
                    $script:PulseTimer = $null
                }
            }
            catch {
                Write-Log $errorLog ('pulse: ' + ($_ | Out-String))
            }
        })
        $timer.Start()
    }
    else {
        $script:PulseTimer.Start()
    }
}

function New-FloatWindow {
    param($Cards, [System.Drawing.Point]$Location)
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.Opacity = 0.86
    $form.KeyPreview = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 38)

    $single = $Cards.Count -eq 1
    if ($single) {
        $profile = $Cards[0].Profile
        $size = New-Object System.Drawing.Size([int]$profile.Width, [int]$profile.Height)
        $form.Text = $profile.Title + ' 额度浮窗'
    }
    else {
        $layout = Get-FusedLayout $Cards
        $size = New-Object System.Drawing.Size($layout.Width, $layout.Height)
        $form.Text = '额度融合浮窗'
    }
    $form.ClientSize = $size
    $form.Location = $Location
    Update-WindowRegion $form

    $script:FormCards[$form] = $Cards
    $script:Minimized[$form] = $false
    $script:Expanded[$form] = $size
    $script:DockState[$form] = @{
        Docked = $false
        Edge = ''
        HoverRevealed = $false
        RevealEdge = ''
        AutoDockAt = $null
        RevealArmed = $true
        ContextMenuOpen = $false
        HoldOpen = $false
    }
    $script:DragState[$form] = $null
    $script:FusionFx[$form] = 0.0
    $contextMenu = New-FloatContextMenu $form
    $form.ContextMenuStrip = $contextMenu

    $flags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
    $dbProp = [System.Windows.Forms.Form].GetProperty('DoubleBuffered', $flags)
    if ($null -ne $dbProp) {
        $dbProp.SetValue($form, $true, $null)
    }

    $form.Add_Paint({
        param($sender, $e)
        try {
            Draw-Window $sender $e.Graphics
        }
        catch {
            Write-Log $paintLog ($_ | Out-String)
        }
    })
    $form.Add_MouseEnter({
        param($sender, $e)
        $state = $script:DockState[$sender]
        if ($null -ne $state -and $state.Docked) {
            Restore-FromDock $sender
        }
        elseif ($null -ne $state -and $state.HoverRevealed) {
            Schedule-AutoDock $sender
        }
    })
    $form.Add_MouseLeave({
        param($sender, $e)
        $state = $script:DockState[$sender]
        if ($null -ne $state -and $state.HoverRevealed -and $null -eq $script:DragState[$sender]) {
            Schedule-AutoDock $sender
        }
    })
    $form.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            $state = $script:DockState[$sender]
            if ($null -ne $state) {
                $state.ContextMenuOpen = $true
                $state.AutoDockAt = $null
                if ($state.Docked) {
                    $state.RevealArmed = $true
                    Restore-FromDock $sender
                }
            }
            return
        }
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
            return
        }
        $state = $script:DockState[$sender]
        $cursor = [System.Windows.Forms.Cursor]::Position
        if ($null -ne $state -and $state.Docked) {
            Restore-FromDock $sender
            $x = [int]($cursor.X - $sender.Left)
            $y = [int]($cursor.Y - $sender.Top)
        }
        else {
            $x = [int]$e.X
            $y = [int]$e.Y
        }
        $action = Get-HitAction $sender $x $y
        switch ($action) {
            'CloseWindow' {
                $sender.Close()
                return
            }
            'MinimizeWindow' {
                Toggle-Minimize $sender
                return
            }
            'CloseCard' {
                $card = Get-HitCard $sender $x $y
                if ($null -ne $card) {
                    Remove-CardFromFused $sender $card $true
                }
                return
            }
            'Expand' {
                Toggle-Minimize $sender
                return
            }
        }
        $cards = @($script:FormCards[$sender])
        $mode = 'Move'
        $hitCard = $null
        if ($cards.Count -gt 1 -and $y -gt 56 -and $action -eq 'Drag') {
            $hitCard = Get-HitCard $sender $x $y
            if ($null -ne $hitCard) {
                $mode = 'Reorder'
            }
        }
        $cardOffsetX = $x
        $cardOffsetY = $y
        if ($mode -eq 'Reorder' -and $null -ne $hitCard) {
            foreach ($region in (Get-CardRegions $sender)) {
                if ($region.Card -eq $hitCard) {
                    $cardOffsetX = $x - [int]$region.X
                    $cardOffsetY = $y - [int]$region.Y
                    break
                }
            }
        }
        $sender.Capture = $true
        $script:DragState[$sender] = [pscustomobject]@{
            Mode = $mode
            Card = $hitCard
            OffsetX = $x
            OffsetY = $y
            CardOffsetX = $cardOffsetX
            CardOffsetY = $cardOffsetY
            Moved = $false
            DetachOutside = $false
            ReorderIndex = if ($mode -eq 'Reorder') { Get-ReorderIndex $sender $hitCard $x $y } else { -1 }
            WasHoverRevealed = ($null -ne $state -and $state.HoverRevealed)
        }
    })
    $form.Add_MouseMove({
        param($sender, $e)
        $drag = $script:DragState[$sender]
        if ($null -eq $drag) {
            return
        }
        if ($drag.Mode -eq 'Reorder') {
            $screenPoint = [System.Windows.Forms.Cursor]::Position
            $localPoint = $sender.PointToClient($screenPoint)
            $deltaX = [Math]::Abs([int]$localPoint.X - [int]$drag.OffsetX)
            $deltaY = [Math]::Abs([int]$localPoint.Y - [int]$drag.OffsetY)
            $drag.DetachOutside = Test-PointOutsideForm $sender $screenPoint
            if ($deltaX -ge 6 -or $deltaY -ge 6) {
                $drag.Moved = $true
                if (-not $drag.DetachOutside) {
                    $drag.ReorderIndex = Get-ReorderIndex $sender $drag.Card ([int]$localPoint.X) ([int]$localPoint.Y)
                }
                $sender.Invalidate()
            }
            return
        }
        $cursor = [System.Windows.Forms.Cursor]::Position
        $nextX = [int]($cursor.X - $drag.OffsetX)
        $nextY = [int]($cursor.Y - $drag.OffsetY)
        if ($nextX -ne $sender.Left -or $nextY -ne $sender.Top) {
            $drag.Moved = $true
            $state = $script:DockState[$sender]
            if ($null -ne $state) {
                $state.HoverRevealed = $false
                $state.RevealEdge = ''
                $state.AutoDockAt = $null
            }
        }
        $sender.Location = New-Object System.Drawing.Point($nextX, $nextY)
        $sender.Invalidate()
    })
    $form.Add_MouseUp({
        param($sender, $e)
        try {
            $drag = $script:DragState[$sender]
            if ($null -eq $drag) {
                return
            }
            $script:DragState[$sender] = $null
            $sender.Capture = $false
            if ($drag.Mode -eq 'Reorder') {
                $screenPoint = [System.Windows.Forms.Cursor]::Position
                $detachOutside = Test-PointOutsideForm $sender $screenPoint
                if ($drag.Moved -and $detachOutside -and $null -ne $drag.Card) {
                    $detachLocation = New-Object System.Drawing.Point(
                        ([int]$screenPoint.X - [int]$drag.CardOffsetX),
                        ([int]$screenPoint.Y - [int]$drag.CardOffsetY)
                    )
                    Remove-CardFromFused $sender $drag.Card $false $detachLocation
                }
                elseif ($drag.Moved) {
                    Move-CardOrder $sender $drag.Card $drag.ReorderIndex
                }
            }
            elseif ($drag.Moved) {
                if (-not (Try-DockToEdge $sender)) {
                    Try-MergeWindow $sender
                }
            }
            elseif ($drag.WasHoverRevealed) {
                Schedule-AutoDock $sender
            }
            if ($null -ne $sender -and -not $sender.IsDisposed) {
                $sender.Invalidate()
            }
        }
        catch {
            Write-Log $errorLog ('mouse-up: ' + ($_ | Out-String))
        }
    })
    $form.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $sender.Close()
        }
    })
    $form.Add_FormClosed({
        param($sender, $e)
        try {
            $mergeClosing = $script:ClosingForms.ContainsKey($sender)
            if ($mergeClosing) {
                $script:ClosingForms.Remove($sender)
            }
            if (-not $mergeClosing) {
                $cards = @($script:FormCards[$sender])
                foreach ($card in $cards) {
                    if ($null -eq $card) {
                        continue
                    }
                    $card.Window = $null
                    $card.Fused = $false
                    if ($script:Cards.ContainsKey($card.Provider)) {
                        $script:Cards.Remove($card.Provider)
                    }
                }
            }
            $script:FormCards.Remove($sender)
            $script:DockState.Remove($sender)
            $script:Minimized.Remove($sender)
            $script:Expanded.Remove($sender)
            $script:DragState.Remove($sender)
            $script:FusionFx.Remove($sender)
            $script:PulseForms.Remove($sender)
            $script:MergePending.Remove($sender)
            $script:MergeConsumed.Remove($sender)
            Save-HostState
        }
        catch {
            Write-Log $errorLog ('form-closed: ' + ($_ | Out-String))
        }
    })

    return ,$form
}

function Remove-CardFromFused {
    param($Form, $Card, [bool]$CloseCard, [object]$DetachedLocation = $null)
    $list = $script:FormCards[$Form]
    if ($null -eq $list) {
        return
    }
    if ($list -isnot [System.Collections.ArrayList]) {
        $normalized = New-Object System.Collections.ArrayList
        foreach ($entry in @($list)) {
            if ($null -ne $entry) {
                [void]$normalized.Add($entry)
            }
        }
        $list = $normalized
        $script:FormCards[$Form] = $list
    }
    $index = $list.IndexOf($Card)
    if ($index -lt 0) {
        Write-Log $errorLog ('remove-card: provider not found in form list: ' + [string]$Card.Provider)
        return
    }
    $list.RemoveAt($index)
    $remaining = @($list.ToArray())
    if ($CloseCard -and $script:Cards.ContainsKey($Card.Provider)) {
        $script:Cards.Remove($Card.Provider)
    }
    $Card.Window = $null
    $Card.Fused = $false

    if ($remaining.Count -eq 0) {
        Save-HostState
        $Form.Close()
        return
    }

    if ($remaining.Count -eq 1) {
        $last = $remaining[0]
        $last.Window = $Form
        $last.Fused = $false
        $profile = $last.Profile
        $size = New-Object System.Drawing.Size([int]$profile.Width, [int]$profile.Height)
        $script:Expanded[$Form] = $size
        $Form.Text = $profile.Title + ' 额度浮窗'
        $Form.ClientSize = $size
    }
    else {
        $layout = Get-FusedLayout $remaining
        $size = New-Object System.Drawing.Size($layout.Width, $layout.Height)
        $script:Expanded[$Form] = $size
        $Form.ClientSize = $size
    }
    Update-WindowRegion $Form

    if (-not $CloseCard) {
        $newCards = New-Object System.Collections.ArrayList
        [void]$newCards.Add($Card)
        if ($DetachedLocation -is [System.Drawing.Point]) {
            $loc = Get-DetachedLocation $Card $DetachedLocation
        }
        else {
            $loc = New-Object System.Drawing.Point(($Form.Left + 40), ($Form.Top + 40))
        }
        $newForm = New-FloatWindow $newCards $loc
        $Card.Window = $newForm
        $Card.Fused = $false
        $newForm.Show()
    }
    $Form.Invalidate()
    Save-HostState
}

function Merge-Windows {
    param($FormA, $FormB)
    if ($null -eq $FormA -or $null -eq $FormB -or $FormA -eq $FormB -or
        $FormA.IsDisposed -or $FormB.IsDisposed -or
        -not $script:FormCards.ContainsKey($FormA) -or
        -not $script:FormCards.ContainsKey($FormB) -or
        $script:MergeConsumed.ContainsKey($FormA) -or
        $script:MergeConsumed.ContainsKey($FormB)) {
        return $FormA
    }
    $cardsA = @($script:FormCards[$FormA])
    $cardsB = @($script:FormCards[$FormB])
    $all = New-Object System.Collections.ArrayList
    foreach ($card in $cardsA) {
        [void]$all.Add($card)
    }
    foreach ($card in $cardsB) {
        [void]$all.Add($card)
    }
    $layout = Get-FusedLayout $all
    $area = Get-WorkingArea
    $desiredX = [Math]::Min($FormA.Left, $FormB.Left)
    $desiredY = [Math]::Min($FormA.Top, $FormB.Top)
    $maxX = [Math]::Max($area.Left, $area.Right - [int]$layout.Width)
    $maxY = [Math]::Max($area.Top, $area.Bottom - [int]($layout.Height))
    $loc = New-Object System.Drawing.Point(
        ([int][Math]::Max($area.Left, [Math]::Min($desiredX, $maxX))),
        ([int][Math]::Max($area.Top, [Math]::Min($desiredY, $maxY)))
    )
    $script:MergeConsumed[$FormA] = $true
    $script:MergeConsumed[$FormB] = $true
    $script:ClosingForms[$FormA] = $true
    $script:ClosingForms[$FormB] = $true
    $script:FormCards.Remove($FormA)
    $script:FormCards.Remove($FormB)
    $script:DockState.Remove($FormA)
    $script:DockState.Remove($FormB)
    $script:Minimized.Remove($FormA)
    $script:Minimized.Remove($FormB)
    $script:Expanded.Remove($FormA)
    $script:Expanded.Remove($FormB)
    $script:DragState.Remove($FormA)
    $script:DragState.Remove($FormB)
    $script:FusionFx.Remove($FormA)
    $script:FusionFx.Remove($FormB)
    $script:PulseForms.Remove($FormA)
    $script:PulseForms.Remove($FormB)
    $FormA.Hide()
    $FormB.Hide()
    $FormA.Dispose()
    $FormB.Dispose()

    $newForm = New-FloatWindow $all $loc
    foreach ($card in $all) {
        $card.Window = $newForm
        $card.Fused = $true
    }
    $newForm.Show()
    Start-FusionPulse $newForm
    return $newForm
}

function Try-MergeWindow {
    param($Form)
    $state = if ($null -ne $Form) { $script:DockState[$Form] } else { $null }
    if ($null -eq $Form -or $Form.IsDisposed -or $null -eq $state -or
        $script:MergeConsumed.ContainsKey($Form) -or
        $state.Docked -or $script:Minimized[$Form] -or
        ($script:MergePending.ContainsKey($Form) -and $script:MergePending[$Form])) {
        return
    }
    $myBounds = $Form.Bounds
    foreach ($other in @($script:FormCards.Keys)) {
        if ($null -eq $other -or $other -eq $Form -or $other.IsDisposed -or -not $other.Visible -or
            $script:MergeConsumed.ContainsKey($other)) {
            continue
        }
        $b = $other.Bounds
        $overlapH = [Math]::Max(0, [Math]::Min($myBounds.Bottom, $b.Bottom) - [Math]::Max($myBounds.Top, $b.Top))
        $overlapV = [Math]::Max(0, [Math]::Min($myBounds.Right, $b.Right) - [Math]::Max($myBounds.Left, $b.Left))
        $gapH = if ($b.Right -le $myBounds.Left) { $myBounds.Left - $b.Right } elseif ($myBounds.Right -le $b.Left) { $b.Left - $myBounds.Right } else { 0 }
        $gapV = if ($b.Bottom -le $myBounds.Top) { $myBounds.Top - $b.Bottom } elseif ($myBounds.Bottom -le $b.Top) { $b.Top - $myBounds.Bottom } else { 0 }
        $minH = [Math]::Min($myBounds.Height, $b.Height)
        $minW = [Math]::Min($myBounds.Width, $b.Width)
        $shouldMerge = $false
        if ($overlapH -ge ($minH * 0.35) -and $gapH -le 36) {
            $shouldMerge = $true
        }
        if ($overlapV -ge ($minW * 0.35) -and $gapV -le 36) {
            $shouldMerge = $true
        }
        if ($shouldMerge -and -not ($script:MergePending.ContainsKey($other) -and $script:MergePending[$other])) {
            $formA = $Form
            $formB = $other
            $script:MergePending[$formA] = $true
            $script:MergePending[$formB] = $true
            $mergeContext = [pscustomobject]@{
                FormA = $formA
                FormB = $formB
            }
            $mergeAction = {
                $callbackA = $null
                $callbackB = $null
                try {
                    if ($null -eq $mergeContext) {
                        throw 'merge callback context is null'
                    }
                    $callbackA = $mergeContext.FormA
                    $callbackB = $mergeContext.FormB
                    if ($null -eq $callbackA -or $null -eq $callbackB) {
                        throw 'merge callback received a null form'
                    }
                    if (-not $callbackA.IsDisposed -and -not $callbackB.IsDisposed) {
                        [void](Merge-Windows $callbackA $callbackB)
                    }
                }
                catch {
                    Write-Log $errorLog ('merge: ' + ($_ | Out-String))
                }
                finally {
                    try {
                        if ($null -ne $script:MergePending) {
                            if ($null -ne $callbackA) { [void]$script:MergePending.Remove($callbackA) }
                            if ($null -ne $callbackB) { [void]$script:MergePending.Remove($callbackB) }
                        }
                    }
                    catch {
                        Write-Log $errorLog ('merge-cleanup: ' + ($_ | Out-String))
                    }
                }
            }.GetNewClosure()
            try {
                if ($formA.IsDisposed -or -not $formA.IsHandleCreated) {
                    throw 'merge source form is disposed or has no handle'
                }
                [void]$formA.BeginInvoke([System.Windows.Forms.MethodInvoker]$mergeAction)
            }
            catch {
                if ($null -ne $script:MergePending) {
                    [void]$script:MergePending.Remove($formA)
                    [void]$script:MergePending.Remove($formB)
                }
                Write-Log $errorLog ('merge-queue: ' + ($_ | Out-String))
            }
            return
        }
    }
}

function New-Card {
    param([string]$Provider)
    $profile = $script:Profiles[$Provider]
    $card = @{
        Provider = $Provider
        Title    = $profile.Title
        Accent   = $profile.Accent
        Profile  = $profile
        Model    = Get-UiModel $Provider
        Window   = $null
        Fused    = $false
    }
    return $card
}

function Get-DefaultLocation {
    param([string]$Provider)
    $profile = $script:Profiles[$Provider]
    $area = Get-WorkingArea
    $x = $area.Right - $profile.Width - $profile.DefaultX
    $y = $area.Bottom - $profile.Height - $profile.DefaultY
    return New-Object System.Drawing.Point($x, $y)
}

function Open-Card {
    param([string]$Provider)
    if ($script:Cards.ContainsKey($Provider)) {
        $existing = $script:Cards[$Provider]
        if ($null -ne $existing.Window -and -not $existing.Window.IsDisposed) {
            $state = $script:DockState[$existing.Window]
            if ($null -ne $state -and $state.Docked) {
                # Re-opening a docked card must bring the full card back. A
                # plain Show() only shows the already-hidden edge handle.
                $state.RevealArmed = $true
                Restore-FromDock $existing.Window
            }
            if ($script:Minimized[$existing.Window]) {
                Toggle-Minimize $existing.Window
            }
            $existing.Window.Show()
            $existing.Window.Activate()
            return
        }
        $script:Cards.Remove($Provider)
    }
    $card = New-Card $Provider
    $script:Cards[$Provider] = $card
    $cards = New-Object System.Collections.ArrayList
    [void]$cards.Add($card)
    $loc = Get-DefaultLocation $Provider
    $form = New-FloatWindow $cards $loc
    $card.Window = $form
    $card.Fused = $false
    $form.Show()
}

function Close-Card {
    param([string]$Provider)
    if (-not $script:Cards.ContainsKey($Provider)) {
        return
    }
    $card = $script:Cards[$Provider]
    if ($null -eq $card) {
        [void]$script:Cards.Remove($Provider)
        return
    }
    $form = $card.Window
    if ($null -eq $form -or $form.IsDisposed -or -not $script:FormCards.ContainsKey($form)) {
        [void]$script:Cards.Remove($Provider)
        return
    }
    Remove-CardFromFused $form $card $true
}

function Process-Requests {
    # QuotaDock can add a provider while this host is already running. Reload
    # the small local registry before validating the request ID so a restart
    # of the host is not required.
    Import-CustomProviders
    if (-not (Test-Path -LiteralPath $requestFile)) {
        return
    }
    $lines = @([System.IO.File]::ReadAllLines($requestFile, [System.Text.Encoding]::UTF8))
    Remove-Item -LiteralPath $requestFile -Force -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        $raw = ([string]$line).Trim().Trim([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            continue
        }
        $parts = $raw.Split('|', 2)
        if ($parts.Count -eq 1) {
            $action = 'add'
            $provider = $parts[0]
        }
        else {
            $action = $parts[0].ToLowerInvariant()
            $provider = $parts[1]
        }
        # A custom provider can be removed from the registry before this host
        # gets its next timer tick.  Removal must still close an already-open
        # card, so handle it before validating the current profile registry.
        if ($action -eq 'remove') {
            if ($script:Cards.ContainsKey($provider)) {
                Close-Card $provider
            }
            Remove-HostStateEntry $provider
            continue
        }
        if (-not $script:Profiles.ContainsKey($provider)) {
            continue
        }
        if ($action -eq 'close') {
            Close-Card $provider
        }
        elseif ($action -eq 'add') {
            Open-Card $provider
        }
    }
}

try {
    if ($Provider -and $script:Profiles.ContainsKey($Provider)) {
        try {
            [System.IO.File]::AppendAllText($requestFile, ('add|' + $Provider + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
        }
    }

    $mutex = New-Object System.Threading.Mutex($false, 'Local\QuotaDockHostMutex')
    $hasMutex = $false
    try {
        $hasMutex = $mutex.WaitOne(0)
    }
    catch {
        $hasMutex = $true
    }
    if (-not $hasMutex) {
        Start-Sleep -Milliseconds 600
        $mutex.Dispose()
        exit 0
    }
    $script:Mutex = $mutex

    $dataTimer = New-Object System.Windows.Forms.Timer
    $dataTimer.Interval = 5000
    $dataTimer.Add_Tick({
        try {
            foreach ($provider in @($script:Cards.Keys)) {
                $card = $script:Cards[$provider]
                if ($null -ne $card) {
                    $card.Model = Get-UiModel $provider
                    if ($null -ne $card.Window -and -not $card.Window.IsDisposed) {
                        $card.Window.Invalidate()
                    }
                }
            }
            Save-HostState
        }
        catch {
            Write-Log $errorLog ('dataTimer: ' + ($_ | Out-String))
        }
    })
    $dataTimer.Start()

    $requestTimer = New-Object System.Windows.Forms.Timer
    $requestTimer.Interval = 250
    $requestTimer.Add_Tick({
        try {
            Process-Requests
            Save-HostState
        }
        catch {
            Write-Log $errorLog ('requestTimer: ' + ($_ | Out-String))
        }
    })
    $requestTimer.Start()

    $dockTimer = New-Object System.Windows.Forms.Timer
    $script:DockTimer = $dockTimer
    $dockTimer.Interval = 100
    $dockTimer.Add_Tick({
        try {
            Process-AutoDock
        }
        catch {
            Write-Log $errorLog ('dockTimer: ' + ($_ | Out-String))
        }
    })
    $dockTimer.Start()

    Process-Requests
    Save-HostState

    if ($AutoDemo -ne '') {
        $demoTries = 0
        $demoTimer = New-Object System.Windows.Forms.Timer
        $demoTimer.Interval = 1200
        $demoTimer.Add_Tick({
            try {
                $demoTries++
                $open = @($script:FormCards.Keys | Where-Object { -not $_.IsDisposed -and $_.Visible })
                $need = if ($AutoDemo -eq 'merge-eject') { 3 } else { 2 }
                if ($open.Count -lt $need -and $demoTries -lt 20) {
                    return
                }
                $demoTimer.Stop()
                $demoTimer.Dispose()
                if ($open.Count -ge 2) {
                    $target = $open[0]
                    for ($i = 1; $i -lt $open.Count; $i++) {
                        $target = Merge-Windows $target $open[$i]
                    }
                    if ($AutoDemo -eq 'merge-eject') {
                        $script:DemoTarget = $target
                        $ejectTimer = New-Object System.Windows.Forms.Timer
                        $script:DemoEjectTimer = $ejectTimer
                        $ejectTimer.Interval = 1200
                        $ejectTimer.Add_Tick({
                            try {
                                $et = $script:DemoEjectTimer
                                if ($null -ne $et) {
                                    $et.Stop()
                                    $et.Dispose()
                                    $script:DemoEjectTimer = $null
                                }
                                $target = $script:DemoTarget
                                if ($target -and -not $target.IsDisposed -and @($script:FormCards[$target]).Count -gt 1) {
                                    $firstCard = @($script:FormCards[$target])[0]
                                    Remove-CardFromFused $target $firstCard $false
                                }
                                $script:DemoTarget = $null
                            }
                            catch {
                                Write-Log $errorLog ('ejectTimer: ' + ($_ | Out-String))
                            }
                        })
                        $ejectTimer.Start()
                    }
                }
            }
            catch {
                Write-Log $errorLog ('demoTimer: ' + ($_ | Out-String))
            }
        })
        $demoTimer.Start()
    }

    [void][System.Windows.Forms.Application]::Run()
    if ($null -ne $script:DockTimer) {
        $script:DockTimer.Stop()
        $script:DockTimer.Dispose()
        $script:DockTimer = $null
    }
}
catch {
    Write-Log $errorLog ($_ | Out-String)
}
