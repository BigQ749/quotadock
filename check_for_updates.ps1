param(
    [switch]$ShowDialog,
    [switch]$SelfTest,
    [switch]$Force,
    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$versionPath = Join-Path $root 'VERSION'
$currentVersionText = (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
$repository = [Environment]::GetEnvironmentVariable('QUOTADOCK_UPDATE_REPO')
if ([string]::IsNullOrWhiteSpace($repository)) {
    $repository = 'BigQ749/quotadock'
}
$cacheRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'QuotaDock'
$cachePath = Join-Path $cacheRoot 'update_check.json'

function Normalize-Version {
    param([string]$Value)
    $text = ([string]$Value).Trim() -replace '^[vV]', ''
    try { return [version]$text } catch { return $null }
}

function Save-UpdateCache {
    param($Payload)
    try {
        New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
        [System.IO.File]::WriteAllText($cachePath, ($Payload | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
    }
}

function Get-LatestRelease {
    $headers = @{ 'User-Agent' = 'QuotaDock-Update-Checker'; Accept = 'application/vnd.github+json' }
    return Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $repository + '/releases/latest') -Headers $headers -TimeoutSec 15
}

if ($SelfTest) {
    if ($null -eq (Normalize-Version $currentVersionText)) {
        throw ('VERSION 无效: ' + $currentVersionText)
    }
    Write-Output ('UPDATE_CHECK_SELFTEST_PASS current=' + $currentVersionText + ' repo=' + $repository)
    exit 0
}

if ($env:QUOTADOCK_DISABLE_UPDATE_CHECK -eq '1') {
    exit 0
}

$currentVersion = Normalize-Version $currentVersionText
if ($null -eq $currentVersion) {
    exit 0
}

$release = $null
$checkError = $null
try {
    if (-not $Force -and (Test-Path -LiteralPath $cachePath)) {
        $cached = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $checkedAt = [datetimeoffset]::Parse([string]$cached.checkedAt)
        if (([datetimeoffset]::Now - $checkedAt).TotalHours -lt 24) {
            $release = $cached.release
        }
    }
}
catch {
}

if ($null -eq $release) {
    try {
        $release = Get-LatestRelease
        Save-UpdateCache ([ordered]@{ checkedAt = [datetimeoffset]::Now.ToString('o'); release = $release })
    }
    catch {
        $checkError = $_.Exception.Message
    }
}

$latestVersion = $null
if ($null -ne $release) {
    $latestVersion = Normalize-Version ([string]$release.tag_name)
}
if ((-not $ShowDialog) -or ($null -eq $latestVersion -and -not $Interactive) -or ($null -ne $latestVersion -and $latestVersion -le $currentVersion -and -not $Interactive)) {
    exit 0
}
$hasUpdate = $null -ne $latestVersion -and $latestVersion -gt $currentVersion

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'QuotaDock 更新检查'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(540, 250)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true

$title = New-Object System.Windows.Forms.Label
$titleText = '暂时无法检查更新'
if ($null -eq $checkError -and $null -ne $latestVersion) {
    if ($hasUpdate) { $titleText = '发现 QuotaDock 新版本 ' + $latestVersion }
    else { $titleText = 'QuotaDock 已是最新版本' }
}
$title.Text = $titleText
$titleFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$title.Font = $titleFont
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(28, 24)
$form.Controls.Add($title)

$body = New-Object System.Windows.Forms.Label
$bodyText = '当前版本 ' + $currentVersion + '。GitHub 暂时不可访问，稍后可重新点击“检查更新”。'
if ($null -eq $checkError -and $null -ne $latestVersion) {
    if ($hasUpdate) {
        $bodyText = '当前版本 ' + $currentVersion + '，可更新到 ' + $latestVersion + '。下载会打开 GitHub Release 页面，不会静默安装，也不会上传本地额度数据。'
    }
    else {
        $bodyText = '当前版本 ' + $currentVersion + '，已检查到最新版本 ' + $latestVersion + '。不会静默安装，也不会上传本地额度数据。'
    }
}
$body.Text = $bodyText
$bodyFont = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', 10
$body.Font = $bodyFont
$body.AutoSize = $false
$body.Size = New-Object System.Drawing.Size(484, 84)
$body.Location = New-Object System.Drawing.Point(28, 66)
$form.Controls.Add($body)

$download = New-Object System.Windows.Forms.Button
$downloadText = '知道了'
if ($hasUpdate) {
    $downloadText = '打开下载页'
}
$download.Text = $downloadText
$download.Size = New-Object System.Drawing.Size(120, 34)
$download.Location = New-Object System.Drawing.Point(258, 194)
$download.Add_Click({
    if ($null -ne $release -and $hasUpdate) { Start-Process ([string]$release.html_url) }
    $form.Close()
})
$form.Controls.Add($download)

$later = New-Object System.Windows.Forms.Button
$later.Text = '稍后提醒'
$later.Size = New-Object System.Drawing.Size(100, 34)
$later.Location = New-Object System.Drawing.Point(398, 194)
$later.Add_Click({ $form.Close() })
$form.Controls.Add($later)

$form.AcceptButton = $download
$form.CancelButton = $later
[void]$form.ShowDialog()
