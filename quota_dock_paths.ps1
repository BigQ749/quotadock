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

function Resolve-QuotaDockPowerShell {
    $candidates = New-Object System.Collections.ArrayList
    $pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $pwshCommand -and -not [string]::IsNullOrWhiteSpace($pwshCommand.Source)) {
        [void]$candidates.Add($pwshCommand.Source)
    }
    $programFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        [void]$candidates.Add((Join-Path $programFiles 'PowerShell\7\pwsh.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        [void]$candidates.Add((Join-Path $programFilesX86 'PowerShell\7\pwsh.exe'))
    }
    $powershellCommand = Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $powershellCommand -and -not [string]::IsNullOrWhiteSpace($powershellCommand.Source)) {
        [void]$candidates.Add($powershellCommand.Source)
    }
    $windir = [Environment]::GetEnvironmentVariable('SystemRoot')
    if (-not [string]::IsNullOrWhiteSpace($windir)) {
        [void]$candidates.Add((Join-Path $windir 'System32\WindowsPowerShell\v1.0\powershell.exe'))
        [void]$candidates.Add((Join-Path $windir 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'))
    }
    foreach ($candidate in @($candidates)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return [string]$candidate
        }
    }
        throw 'QuotaDock 需要 PowerShell（优先 pwsh.exe / PowerShell 7+，否则 Windows PowerShell 5.1），但本机未找到。可从 https://aka.ms/powershell-release?tag=stable 安装 PowerShell 7，或确认系统自带的 powershell.exe 可用。'
}

function Get-QuotaDockPowerShellProcessName {
    param([string]$PowerShellPath)
    if ([string]::IsNullOrWhiteSpace($PowerShellPath)) { return 'powershell.exe' }
    $name = [System.IO.Path]::GetFileName($PowerShellPath)
    if ([string]::IsNullOrWhiteSpace($name)) { return 'powershell.exe' }
    return $name
}