param(
    [string]$WorkspaceId
)

$ErrorActionPreference = 'Stop'
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'QuotaDock'
$credentialPath = Join-Path $stateDir 'opencode_go_credentials.json'

function Read-HiddenLine {
    param([string]$Prompt)
    [Console]::Write($Prompt)
    $buffer = New-Object System.Text.StringBuilder
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) {
            [Console]::WriteLine()
            break
        }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                [void]$buffer.Remove($buffer.Length - 1, 1)
                [Console]::Write("`b `b")
            }
            continue
        }
        if (-not [char]::IsControl($key.KeyChar)) {
            [void]$buffer.Append($key.KeyChar)
            [Console]::Write('*')
        }
    }
    return $buffer.ToString()
}

function Protect-CurrentUserText {
    param([string]$PlainText)
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Convert]::ToBase64String($protected)
}

try {
    if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
        $WorkspaceId = Read-Host '请输入 OpenCode Go 工作区 ID（例如 wrk_xxx）'
    }
    $WorkspaceId = $WorkspaceId.Trim()
    if ($WorkspaceId -notmatch '^wrk_[A-Za-z0-9]+$') {
        throw 'Workspace ID 格式无效，应为 wrk_xxx'
    }

    Write-Output '请从 Chrome 的 opencode.ai Cookie 中复制 auth 的值。'
    Write-Output '只粘贴 Fe26... 值即可；输入时不会回显。误粘贴 auth= 或 Cookie: auth= 也会自动处理。'
    $plainCookie = (Read-HiddenLine 'auth Cookie: ').Trim()
    if ($plainCookie -match '(?i)(?:^|[;\s])auth\s*=\s*(Fe26\.[^;\s]+)') {
        $plainCookie = $Matches[1]
    } else {
        $normalizedCookie = $plainCookie -replace '^(?i:cookie:\s*)?auth\s*=\s*', ''
        $normalizedCookie = $normalizedCookie.Trim().Trim('"').Trim("'")
        $plainCookie = $normalizedCookie
    }
    if ($plainCookie -notmatch '^Fe26\.') {
        throw 'auth Cookie 格式无效；请复制 opencode.ai 下 auth 的 Value，内容应以 Fe26. 开头'
    }

    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $payload = [ordered]@{
        version             = 2
        workspaceId         = $WorkspaceId
        protection          = 'dpapi-current-user'
        authCookieProtected = Protect-CurrentUserText $plainCookie
        savedAt             = [DateTime]::UtcNow.ToString('o')
    }
    $json = $payload | ConvertTo-Json -Depth 5
    $tmpPath = "$credentialPath.$PID.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmpPath -Destination $credentialPath -Force

    $syncPath = Join-Path $baseDir 'opencode_go_background_sync.ps1'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-Output '凭证已按当前 Windows 用户范围加密保存。正在执行一次后台直连测试……'
    & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $syncPath -Once
    if ($LASTEXITCODE -ne 0) {
        throw '后台直连测试失败；凭证文件已保留，可查看 %TEMP%\quota-fusion-opencode-background.log'
    }
    Write-Output '配置完成：之后启动 OpenCode Go 浮窗时会每 60 秒后台同步，不要求 Chrome 保持打开。'
    Read-Host '按回车关闭此窗口' | Out-Null
}
catch {
    Write-Output ''
    Write-Output ('配置失败：' + $_.Exception.Message)
    Write-Output '凭证内容不会显示；如已保存凭证，文件会保留供下次测试。'
    Read-Host '按回车关闭此窗口' | Out-Null
    exit 1
}
