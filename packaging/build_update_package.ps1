param(
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw -Encoding UTF8).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw ('VERSION 必须是三段式版本号: ' + $version)
}

$dist = Join-Path $root 'dist'
$packagePath = Join-Path $dist ('QuotaDock-v' + $version + '.zip')
$manifestPath = Join-Path $root 'update-manifest.json'
$stage = Join-Path $env:TEMP ('QuotaDock-package-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    if ($Clean -and (Test-Path -LiteralPath $packagePath)) {
        Remove-Item -LiteralPath $packagePath -Force
    }

    $topLevelFiles = @(Get-ChildItem -LiteralPath $root -File | Where-Object {
        $_.Extension -in @('.ps1', '.vbs') -or $_.Name -in @('VERSION', 'LICENSE', 'README.md', 'SECURITY.md', 'TRADEMARKS.md', 'custom-provider.example.json')
    })
    foreach ($file in $topLevelFiles) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $stage $file.Name) -Force
    }
    foreach ($directoryName in @('assets', 'examples', 'opencode-go-quota-bridge')) {
        $source = Join-Path $root $directoryName
        if (Test-Path -LiteralPath $source -PathType Container) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $stage $directoryName) -Recurse -Force
        }
    }
    # These files are generated from the user's local account/session and must
    # never enter an update package.
    foreach ($privateName in @('opencode_go_live.json', 'update-manifest.json')) {
        $privatePath = Join-Path $stage $privateName
        if (Test-Path -LiteralPath $privatePath) {
            Remove-Item -LiteralPath $privatePath -Force
        }
    }

    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $packagePath -CompressionLevel Optimal -Force
    $sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $existingNotes = ''
    if (Test-Path -LiteralPath $manifestPath) {
        try { $existingNotes = [string]((Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).notes) } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($existingNotes) -or $version -eq '0.1.9') {
        $existingNotes = '新增标准 Windows 安装器：支持选择安装目录、快捷方式、可选开机启动，并将 ZIP 标记为便携版/更新包。'
    }
    $manifest = [ordered]@{
        version      = $version
        channel      = 'stable'
        packageType  = 'zip'
        downloadUrl  = 'https://raw.githubusercontent.com/BigQ749/quotadock/main/dist/QuotaDock-v' + $version + '.zip'
        sha256       = $sha256
        releaseUrl   = 'https://github.com/BigQ749/quotadock/releases/tag/v' + $version
        notes        = $existingNotes
    }
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output ('QUOTADOCK_UPDATE_PACKAGE=' + $packagePath)
    Write-Output ('QUOTADOCK_UPDATE_SHA256=' + $sha256)
    Write-Output ('QUOTADOCK_UPDATE_FILE_COUNT=' + (@(Get-ChildItem -LiteralPath $stage -Recurse -File).Count))
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
