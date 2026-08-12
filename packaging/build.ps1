param(
    [string]$CompilerPath = '',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw -Encoding UTF8).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw ('VERSION 必须是三段式版本号: ' + $version)
}

if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    $candidates = @(
        (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source,
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe'
    )
    $CompilerPath = $candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    throw '找不到 Inno Setup ISCC.exe。Windows 本地构建请安装 Inno Setup 6；GitHub Actions 会自动准备构建环境。'
}

$dist = Join-Path $root 'dist'
if ($Clean -and (Test-Path -LiteralPath $dist)) {
    Remove-Item -LiteralPath $dist -Recurse -Force
}
New-Item -ItemType Directory -Path $dist -Force | Out-Null

$iss = Join-Path $PSScriptRoot 'QuotaDock.iss'
& $CompilerPath $iss
if ($LASTEXITCODE -ne 0) {
    throw ('ISCC 构建失败，退出码: ' + $LASTEXITCODE)
}

$installer = Join-Path $dist ('QuotaDock-Setup-' + $version + '.exe')
if (-not (Test-Path -LiteralPath $installer)) {
    throw ('未找到安装器输出: ' + $installer)
}
Get-FileHash -LiteralPath $installer -Algorithm SHA256 | Format-List
Write-Output ('QUOTADOCK_INSTALLER=' + $installer)
