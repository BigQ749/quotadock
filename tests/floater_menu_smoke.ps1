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

function Test-WindowIsAbove {
    param([IntPtr]$Window, [IntPtr]$Candidate)
    $current = [QuotaFusionDpiNative]::GetWindow($Window, [uint32]3)
    $visited = 0
    while ($current -ne [IntPtr]::Zero -and $visited -lt 128) {
        if ($current -eq $Candidate) {
            return $true
        }
        $current = [QuotaFusionDpiNative]::GetWindow($current, [uint32]3)
        $visited++
    }
    return $false
}

$card = New-Card 'opencode'
$cards = New-Object System.Collections.ArrayList
[void]$cards.Add($card)
$form = New-FloatWindow $cards (New-Object System.Drawing.Point(80, 80))
$card.Window = $form
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
$competingForm = $null
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

    if (-not (Dock-AtEdge $form 'Top')) {
        throw 'Could not dock the floater for the topmost smoke test.'
    }
    [System.Windows.Forms.Application]::DoEvents()

    $competingForm = New-Object System.Windows.Forms.Form
    $competingForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $competingForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $competingForm.Location = $form.Location
    $competingForm.ClientSize = $form.ClientSize
    $competingForm.TopMost = $true
    $competingForm.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $topmostFlags = [uint32](0x0001 -bor 0x0002 -bor 0x0010 -bor 0x0200)
    $competitorRaised = [QuotaFusionDpiNative]::SetWindowPos(
        $competingForm.Handle,
        [IntPtr](-1),
        0,
        0,
        0,
        0,
        $topmostFlags
    )
    if (-not $competitorRaised -or -not (Test-WindowIsAbove $form.Handle $competingForm.Handle)) {
        throw 'Could not place a competing topmost window above the docked floater.'
    }

    $script:LastTopmostEnforcementAt = [datetime]::MinValue
    Process-DockedWindowTopmost
    [System.Windows.Forms.Application]::DoEvents()
    if (-not $form.TopMost -or (Test-WindowIsAbove $form.Handle $competingForm.Handle)) {
        throw 'Docked floater did not reclaim topmost z-order above a competing topmost window.'
    }
    Write-Output ('FLOATER_MENU_SMOKE_PASS size=' + $menu.Width + 'x' + $menu.Height + ' hold=released docked-topmost=reasserted')
}
finally {
    if ($null -ne $competingForm -and -not $competingForm.IsDisposed) { $competingForm.Close(); $competingForm.Dispose() }
    if ($null -ne $menu -and -not $menu.IsDisposed) { $menu.Close() }
    if ($null -ne $form -and -not $form.IsDisposed) { $form.Close(); $form.Dispose() }
}
