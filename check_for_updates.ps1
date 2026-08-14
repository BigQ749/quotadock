param(
    [switch]$ShowDialog,
    [switch]$SelfTest,
    [switch]$Force,
    [switch]$Interactive,
    [switch]$ResultOnly,
    [string]$ResultPath,
    [string]$InstallRoot = '',
    [int]$CenterPid = 0
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
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = $root
}
$installScript = Join-Path $InstallRoot 'install_quota_update.ps1'

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

function Get-LatestReleaseFromManifest {
    $headers = @{ 'User-Agent' = 'QuotaDock-Update-Checker' }
    $manifestUri = 'https://raw.githubusercontent.com/' + $repository + '/main/update-manifest.json'
    $manifest = Invoke-RestMethod -Uri $manifestUri -Headers $headers -TimeoutSec 15
    return Convert-ManifestToUpdateRelease $manifest
}

function Convert-ManifestToUpdateRelease {
    param($Manifest)
    $tag = ([string]$Manifest.version).Trim()
    if ($null -eq (Normalize-Version $tag)) {
        throw ('远端更新清单版本无效：' + $tag)
    }
    return [pscustomobject]@{
        tag_name     = $tag
        name         = 'QuotaDock ' + $tag
        html_url     = [string]$Manifest.releaseUrl
        download_url = [string]$Manifest.downloadUrl
        sha256       = ([string]$Manifest.sha256).Trim().ToLowerInvariant()
        body         = [string]$Manifest.notes
    }
}

function Get-LatestReleaseFromReleaseManifest {
    $headers = @{ 'User-Agent' = 'QuotaDock-Update-Checker' }
    $manifestUri = 'https://github.com/' + $repository + '/releases/latest/download/update-manifest.json'
    $manifest = Invoke-RestMethod -Uri $manifestUri -Headers $headers -TimeoutSec 15
    return Convert-ManifestToUpdateRelease $manifest
}

function Get-LatestReleaseFromVersionFile {
    $headers = @{ 'User-Agent' = 'QuotaDock-Update-Checker' }
    $rawUri = 'https://raw.githubusercontent.com/' + $repository + '/main/VERSION'
    $tag = ([string](Invoke-RestMethod -Uri $rawUri -Headers $headers -TimeoutSec 15)).Trim()
    if ($null -eq (Normalize-Version $tag)) {
        throw ('远端 VERSION 无效：' + $tag)
    }
    return [pscustomobject]@{
        tag_name = $tag
        name     = $tag
        html_url = 'https://github.com/' + $repository + '/releases/tag/v' + $tag.TrimStart('v')
        download_url = 'https://github.com/' + $repository + '/releases/download/v' + $tag.TrimStart('v') + '/QuotaDock-v' + $tag.TrimStart('v') + '.zip'
        sha256 = ''
        body = ''
    }
}

function Convert-GitHubReleaseToUpdateRelease {
    param($Release)
    $tag = ([string]$Release.tag_name).Trim()
    $normalized = Normalize-Version $tag
    if ($null -eq $normalized) {
        throw ('GitHub Release 版本无效：' + $tag)
    }
    $versionText = $normalized.ToString()
    $assetName = 'QuotaDock-v' + $versionText + '.zip'
    $asset = @($Release.assets) | Where-Object { [string]$_.name -eq $assetName } | Select-Object -First 1
    $digest = if ($null -ne $asset) { ([string]$asset.digest).Trim() } else { '' }
    $sha256 = if ($digest -match '^sha256:([A-Fa-f0-9]{64})$') { $Matches[1].ToLowerInvariant() } else { '' }
    [pscustomobject]@{
        tag_name     = $tag
        name         = [string]$Release.name
        html_url     = [string]$Release.html_url
        download_url = if ($null -ne $asset) { [string]$asset.browser_download_url } else { '' }
        sha256       = $sha256
        body         = [string]$Release.body
    }
}

function Get-LatestRelease {
    $manifestError = $null
    try {
        # A raw manifest is not subject to the GitHub API quota and carries the
        # exact package URL plus its SHA-256 digest.
        return Get-LatestReleaseFromManifest
    }
    catch {
        $manifestError = $_.Exception.Message
    }
    try {
        # The latest Release also carries a manifest. This keeps update checks
        # usable if the main branch raw file is temporarily stale or unavailable.
        return Get-LatestReleaseFromReleaseManifest
    }
    catch {
        $releaseManifestError = $_.Exception.Message
    }
    $headers = @{ 'User-Agent' = 'QuotaDock-Update-Checker'; Accept = 'application/vnd.github+json' }
    try {
        $release = Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $repository + '/releases/latest') -Headers $headers -TimeoutSec 15
        return Convert-GitHubReleaseToUpdateRelease $release
    }
    catch {
        $apiError = $_.Exception.Message
        try {
            # The public VERSION file is not subject to the GitHub API quota.
            # It preserves update detection when /releases/latest returns 403.
            return Get-LatestReleaseFromVersionFile
        }
        catch {
            throw ('更新清单：' + $manifestError + '；Release 清单：' + $releaseManifestError + '；GitHub API：' + $apiError + '；VERSION 兜底：' + $_.Exception.Message)
        }
    }
}

if ($SelfTest) {
    if ($null -eq (Normalize-Version $currentVersionText)) {
        throw ('VERSION 无效: ' + $currentVersionText)
    }
    Write-Output ('UPDATE_CHECK_SELFTEST_PASS current=' + $currentVersionText + ' repo=' + $repository)
    exit 0
}

if ($env:QUOTADOCK_DISABLE_UPDATE_CHECK -eq '1' -and -not $Interactive -and -not $ResultOnly) {
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
        $cachedRelease = $cached.release
        $hasDirectPackage = $null -ne $cachedRelease -and
            $null -ne $cachedRelease.PSObject.Properties['download_url'] -and
            $null -ne $cachedRelease.PSObject.Properties['sha256']
        if (([datetimeoffset]::Now - $checkedAt).TotalHours -lt 24 -and $hasDirectPackage) {
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
$hasUpdate = $null -ne $latestVersion -and $latestVersion -gt $currentVersion
$canInstall = $hasUpdate -and
    $null -ne $release -and
    -not [string]::IsNullOrWhiteSpace([string]$release.download_url) -and
    ([string]$release.sha256).Trim() -match '^[A-Fa-f0-9]{64}$'

function Write-UpdateResult {
    if ([string]::IsNullOrWhiteSpace($ResultPath)) {
        return
    }
    try {
        $releaseUrl = if ($null -ne $release) { [string]$release.html_url } else { '' }
        $payload = [ordered]@{
            checkedAt      = [datetimeoffset]::Now.ToString('o')
            currentVersion = $currentVersionText
            latestVersion  = if ($null -ne $latestVersion) { $latestVersion.ToString() } else { '' }
            hasUpdate      = [bool]$hasUpdate
            releaseUrl     = $releaseUrl
            downloadUrl    = if ($null -ne $release) { [string]$release.download_url } else { '' }
            sha256         = if ($null -ne $release) { [string]$release.sha256 } else { '' }
            releaseNotes   = if ($null -ne $release) { [string]$release.body } else { '' }
            checkError     = [string]$checkError
        }
        [System.IO.File]::WriteAllText($ResultPath, ($payload | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        # The parent process will report that no result was returned.
    }
}

if ($ResultOnly) {
    Write-UpdateResult
    exit 0
}
if ((-not $ShowDialog) -or ($null -eq $latestVersion -and -not $Interactive) -or ($null -ne $latestVersion -and $latestVersion -le $currentVersion -and -not $Interactive)) {
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Start-LocalInstaller {
    param($Release)
    $downloadUrl = [string]$Release.download_url
    $sha256 = ([string]$Release.sha256).Trim()
    if ([string]::IsNullOrWhiteSpace($downloadUrl) -or $sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            '该版本没有可验证的更新包，QuotaDock 已停止本次更新。请稍后重试。',
            '无法安全更新',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $installScript)) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            '本机缺少本地更新组件，无法替换当前版本。',
            '无法安全更新',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
    try {
        $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
        $arguments = @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            $installScript
            '-PackageUrl'
            $downloadUrl
            '-ExpectedSha256'
            $sha256
            '-TargetVersion'
            ([string]$Release.tag_name)
            '-InstallRoot'
            $InstallRoot
            '-RestartCenter'
        )
        if ($CenterPid -gt 0 -and $CenterPid -ne $PID) {
            $arguments += @('-CloseProcessId', ([string]$CenterPid))
        }
        else {
            $arguments += @('-ParentPid', ([string]$PID))
        }
        Start-Process -FilePath $pwsh -WindowStyle Hidden -WorkingDirectory $InstallRoot -ArgumentList $arguments | Out-Null
        $form.Close()
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            ('启动本地更新失败：' + $_.Exception.Message),
            '无法更新 QuotaDock',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

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
        if ($canInstall) {
            $bodyText = '当前版本 ' + $currentVersion + '，可更新到 ' + $latestVersion + '。点击“立即更新”后会直接下载、校验并替换本地程序，然后自动重启；不会上传本地额度数据。'
        }
        else {
            $bodyText = '当前版本 ' + $currentVersion + '，检测到 ' + $latestVersion + '，但远端没有可验证的更新包。为保护本地程序，QuotaDock 暂不安装。'
        }
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
if ($canInstall) {
    $downloadText = '立即更新'
}
$download.Text = $downloadText
$download.Size = New-Object System.Drawing.Size(120, 34)
$download.Location = New-Object System.Drawing.Point(258, 194)
$download.Add_Click({
    if ($null -ne $release -and $canInstall) { Start-LocalInstaller $release }
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
