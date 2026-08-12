$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktop = [Environment]::GetFolderPath('Desktop')
$wscript = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'
$appIconPath = Join-Path $root 'assets\app\QuotaDock.ico'
$shell = New-Object -ComObject WScript.Shell

if (-not (Test-Path -LiteralPath $appIconPath)) {
    throw ('缺少 QuotaDock 应用图标: ' + $appIconPath)
}

function New-FloatShortcut {
    param(
        [string]$Name,
        [string]$VbsName,
        [string]$Description
    )

    $path = Join-Path $desktop ($Name + '.lnk')
    $shortcut = $shell.CreateShortcut($path)
    $shortcut.TargetPath = $wscript
    $shortcut.Arguments = '"' + (Join-Path $root $VbsName) + '"'
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = $Description
    if ($Name -eq 'QuotaDock') {
        $shortcut.IconLocation = $appIconPath + ',0'
    }
    else {
        $shortcut.IconLocation = (Join-Path ([Environment]::SystemDirectory) 'shell32.dll') + ',220'
    }
    $shortcut.Save()
    return $path
}

$created = @()
$created += New-FloatShortcut 'Codex额度' 'launch_codex_float.vbs' 'Codex 独立额度浮窗'
$created += New-FloatShortcut 'Grok额度' 'launch_grok_float.vbs' 'Grok 独立额度浮窗'
$created += New-FloatShortcut 'OpenCode Go额度' 'launch_opencode_float.vbs' 'OpenCode Go 独立额度浮窗'
$created += New-FloatShortcut 'QuotaDock' 'launch_quota_center.vbs' '统一管理 Codex、Grok、OpenCode Go 额度浮窗'

$legacyCenterShortcut = Join-Path $desktop '额度中心.lnk'
if (Test-Path -LiteralPath $legacyCenterShortcut) {
    $legacyCenter = $shell.CreateShortcut($legacyCenterShortcut)
    if ($legacyCenter.TargetPath -eq $wscript -and ([string]$legacyCenter.Arguments -like '*launch_quota_center.vbs*')) {
        Remove-Item -LiteralPath $legacyCenterShortcut -Force
    }
}

$oldShortcut = Join-Path $desktop '额度融合.lnk'
if (Test-Path -LiteralPath $oldShortcut) {
    $old = $shell.CreateShortcut($oldShortcut)
    $oldArguments = [string]$old.Arguments
    if ($old.TargetPath -eq $wscript -and $oldArguments -like '*launch_quota_fusion.vbs*') {
        Remove-Item -LiteralPath $oldShortcut -Force
    }
}

Write-Output 'INSTALLED_FLOAT_SHORTCUTS'
$created | ForEach-Object { Write-Output $_ }
