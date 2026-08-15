$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$hostPath = Join-Path $root 'quota_fusion_host.ps1'
$source = Get-Content -LiteralPath $hostPath -Raw -Encoding UTF8
$mainMatch = [regex]::Match($source, '(?ms)^try \{\r?\n    if \(\$Provider')
if (-not $mainMatch.Success) {
    throw 'Could not locate the host application entry point.'
}
$librarySource = $source.Substring(0, $mainMatch.Index)
$librarySource = $librarySource -replace '\$baseDir = Split-Path -Parent \$MyInvocation\.MyCommand\.Path', '$baseDir = Split-Path -Parent $hostPath'
. ([scriptblock]::Create($librarySource))

$card = New-Card 'opencode'
$cards = New-Object System.Collections.ArrayList
[void]$cards.Add($card)
$form = New-FloatWindow $cards (New-Object System.Drawing.Point(80, 80))
$card.Window = $form
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
$menu = $form.ContextMenuStrip
try {
    $menu.Show((New-Object System.Drawing.Point(120, 120)))
    [System.Windows.Forms.Application]::DoEvents()
    if ($menu.IsDisposed -or $menu.Width -lt 420 -or $menu.Height -le 0) {
        throw ('Unexpected menu state: disposed=' + $menu.IsDisposed + ' size=' + $menu.Width + 'x' + $menu.Height)
    }
    $state = $script:DockState[$form]
    if ($null -eq $state -or -not $state.ContextMenuHold) {
        throw 'Context menu did not hold the floater open while visible.'
    }
    $menu.Close()
    [System.Windows.Forms.Application]::DoEvents()
    if ($state.ContextMenuHold) {
        throw 'Context menu hold was not released after closing the menu.'
    }
    Write-Output ('FLOATER_MENU_SMOKE_PASS size=' + $menu.Width + 'x' + $menu.Height + ' hold=released')
}
finally {
    if ($null -ne $menu -and -not $menu.IsDisposed) { $menu.Close() }
    if ($null -ne $form -and -not $form.IsDisposed) { $form.Close(); $form.Dispose() }
}
