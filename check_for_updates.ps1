param(
    [switch]$ShowDialog,
    [switch]$SelfTest
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
try {
    if (Test-Path -LiteralPath $cachePath) {
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
        exit 0
    }
}

$latestVersion = Normalize-Version ([string]$release.tag_name)
if ($null -eq $latestVersion -or $latestVersion -le $currentVersion -or -not $ShowDialog) {
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'QuotaDock Update'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(470, 190)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true

$title = New-Object System.Windows.Forms.Label
$title.Text = ('New QuotaDock version ' + $latestVersion + ' is available')
$titleFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$title.Font = $titleFont
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(28, 24)
$form.Controls.Add($title)

$body = New-Object System.Windows.Forms.Label
$body.Text = ('Current version ' + $currentVersion + '. GitHub Releases provides the download. No silent install and no local quota data upload.')
$bodyFont = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', 10
$body.Font = $bodyFont
$body.AutoSize = $false
$body.Size = New-Object System.Drawing.Size(414, 58)
$body.Location = New-Object System.Drawing.Point(28, 66)
$form.Controls.Add($body)

$download = New-Object System.Windows.Forms.Button
$download.Text = 'Download'
$download.Size = New-Object System.Drawing.Size(120, 34)
$download.Location = New-Object System.Drawing.Point(224, 132)
$download.Add_Click({ Start-Process ([string]$release.html_url); $form.Close() })
$form.Controls.Add($download)

$later = New-Object System.Windows.Forms.Button
$later.Text = 'Later'
$later.Size = New-Object System.Drawing.Size(100, 34)
$later.Location = New-Object System.Drawing.Point(350, 132)
$later.Add_Click({ $form.Close() })
$form.Controls.Add($later)

$form.AcceptButton = $download
$form.CancelButton = $later
[void]$form.ShowDialog()
