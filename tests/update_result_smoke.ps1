$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$resultPath = Join-Path $env:TEMP ('quotadock-update-result-smoke-' + $PID + '.json')
try {
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    & (Get-Command pwsh.exe).Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'check_for_updates.ps1') -ResultOnly -ResultPath $resultPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $resultPath)) {
        throw '更新结果文件未生成'
    }
    $payload = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$payload.currentVersion)) {
        throw '更新结果缺少当前版本'
    }
    Write-Output ('UPDATE_RESULT_SMOKE_PASS current=' + $payload.currentVersion)
}
finally {
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
}
