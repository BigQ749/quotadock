# Shared provider-path discovery for QuotaDock's center, host and launchers.
#
# The portable app may be nested below the provider integrations. Walk the app
# directory and its
# ancestors so the packaged app does not depend on a developer-specific path.

function Get-QuotaDockAncestorRoots {
    param([string]$AppRoot)

    $roots = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($AppRoot)) {
        return @()
    }

    try {
        $current = [System.IO.Path]::GetFullPath($AppRoot)
    }
    catch {
        return @()
    }

    for ($index = 0; $index -lt 12; $index++) {
        if ([string]::IsNullOrWhiteSpace($current)) {
            break
        }
        if (-not $roots.Contains($current)) {
            [void]$roots.Add($current)
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }
    return @($roots.ToArray())
}

function Get-QuotaDockIntegrationCandidates {
    param(
        [string]$AppRoot,
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return @()
    }

    $candidates = New-Object System.Collections.ArrayList
    foreach ($root in @(Get-QuotaDockAncestorRoots $AppRoot)) {
        try {
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $RelativePath))
            if (-not $candidates.Contains($candidate)) {
                [void]$candidates.Add($candidate)
            }
        }
        catch {
        }
    }
    return @($candidates.ToArray())
}

function Resolve-QuotaDockIntegrationPath {
    param(
        [string]$AppRoot,
        [string]$RelativePath
    )

    foreach ($candidate in @(Get-QuotaDockIntegrationCandidates -AppRoot $AppRoot -RelativePath $RelativePath)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return ''
}
