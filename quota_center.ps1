param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# Enable native per-monitor DPI rendering before WinForms creates any controls.
# Without this, Windows can bitmap-scale the whole borderless window, which
# makes both text and rounded edges look soft on high-DPI displays.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class QuotaCenterDpiNative {
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")]
    private static extern int SetProcessDpiAwareness(int value);
    public static void Enable() {
        try {
            if (SetProcessDpiAwarenessContext(new IntPtr(-4))) {
                return;
            }
        }
        catch {
        }
        try {
            SetProcessDpiAwareness(2);
        }
        catch {
        }
    }
}
'@

[QuotaCenterDpiNative]::Enable()

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$requestFile = Join-Path $env:TEMP 'quotadock-host-requests.txt'
$stateRoot = Join-Path $env:LOCALAPPDATA 'QuotaDock'
$hostStateFile = Join-Path $stateRoot 'host_state.json'
$stateFile = Join-Path $stateRoot 'quota_center_state.json'
$customConfigPath = Join-Path $stateRoot 'custom_providers.json'
$customDataRoot = Join-Path $stateRoot 'custom-data'
$hiddenProviderPath = Join-Path $stateRoot 'quota_center_hidden.json'
$centerErrorLog = Join-Path $env:TEMP 'quota-center-error.log'

function Resolve-QuotaDockPowerShell {
    $candidates = @()
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
        $candidates += $command.Source
    }

    $programFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $candidates += (Join-Path $programFiles 'PowerShell\7\pwsh.exe')
    }
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $candidates += (Join-Path $programFilesX86 'PowerShell\7\pwsh.exe')
    }

    $resolved = @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
    if ($resolved.Count -eq 0) {
        throw 'QuotaDock 需要 PowerShell 7+（pwsh.exe），但本机未找到。请先安装 PowerShell 7。'
    }
    return [string]$resolved[0]
}

$powershell = Resolve-QuotaDockPowerShell
$appIconPath = Join-Path $root 'assets\app\QuotaDock.ico'

$providers = [ordered]@{
    codex = [pscustomobject]@{
        Title = 'Codex'
        Description = '周额度 · 独立浮窗'
    }
    opencode = [pscustomobject]@{
        Title = 'OpenCode Go'
        Description = '5 小时 / 周 / 月 · 独立浮窗'
    }
    grok = [pscustomobject]@{
        Title = 'Grok'
        Description = '周额度 · 独立浮窗'
    }
}

$builtInProviderIds = @('codex', 'opencode', 'grok')

function Import-CustomProviders {
    if (-not (Test-Path -LiteralPath $customConfigPath)) {
        return
    }
    try {
        $config = Get-Content -LiteralPath $customConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in @($config.providers)) {
            $id = ([string]$entry.id).Trim().ToLowerInvariant()
            $title = ([string]$entry.title).Trim()
            if ([string]::IsNullOrWhiteSpace($id) -or
                $id -notmatch '^[a-z0-9][a-z0-9_-]{1,31}$' -or
                [string]::IsNullOrWhiteSpace($title) -or
                $providers.Keys -contains $id) {
                continue
            }
            $description = ([string]$entry.description).Trim()
            if ([string]::IsNullOrWhiteSpace($description)) {
                $description = '自定义额度 · 本地 JSON'
            }
            $providers[$id] = [pscustomobject]@{
                Title       = $title
                Description = $description
                BrandPath   = [Environment]::ExpandEnvironmentVariables(([string]$entry.brandPath).Trim())
            }
        }
    }
    catch {
        # A malformed custom file must not prevent the three built-in cards from opening.
    }
}

function Get-JsonValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

Import-CustomProviders

if ($SelfTest) {
    $launcher = Join-Path $root 'launch_quota_small_widget.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw ('缺少额度浮窗启动器: ' + $launcher)
    }
    if (-not (Test-Path -LiteralPath $root)) {
        throw ('项目目录不存在: ' + $root)
    }
    Write-Output 'QUOTA_CENTER_SELFTEST_PASS'
    Write-Output ('ROOT=' + $root)
    Write-Output ('REQUEST_FILE=' + $requestFile)
    Write-Output ('PROVIDERS=' + (($providers.Keys -join ',')))
    exit 0
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\QuotaDockCenterMutex')
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
}
catch {
    $hasMutex = $true
}
if (-not $hasMutex) {
    $mutex.Dispose()
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$quotaDockMenuRefs = @(
    [System.Drawing.Color].Assembly.Location,
    [System.Windows.Forms.ToolStripProfessionalRenderer].Assembly.Location
)
Add-Type -ReferencedAssemblies $quotaDockMenuRefs @'
using System.Drawing;
using System.Windows.Forms;

public sealed class QuotaDockMenuColorTable : ProfessionalColorTable {
    public override Color ToolStripDropDownBackground { get { return Color.FromArgb(27, 33, 43); } }
    public override Color MenuBorder { get { return Color.FromArgb(70, 82, 100); } }
    public override Color MenuItemBorder { get { return Color.FromArgb(74, 116, 151); } }
    public override Color MenuItemSelected { get { return Color.FromArgb(46, 69, 91); } }
    public override Color MenuItemSelectedGradientBegin { get { return Color.FromArgb(46, 69, 91); } }
    public override Color MenuItemSelectedGradientEnd { get { return Color.FromArgb(40, 59, 79); } }
    public override Color MenuItemPressedGradientBegin { get { return Color.FromArgb(37, 57, 75); } }
    public override Color MenuItemPressedGradientMiddle { get { return Color.FromArgb(37, 57, 75); } }
    public override Color MenuItemPressedGradientEnd { get { return Color.FromArgb(31, 47, 63); } }
    public override Color ImageMarginGradientBegin { get { return Color.FromArgb(27, 33, 43); } }
    public override Color ImageMarginGradientMiddle { get { return Color.FromArgb(27, 33, 43); } }
    public override Color ImageMarginGradientEnd { get { return Color.FromArgb(27, 33, 43); } }
    public override Color SeparatorDark { get { return Color.FromArgb(66, 78, 95); } }
    public override Color SeparatorLight { get { return Color.FromArgb(35, 43, 55); } }
}

public sealed class QuotaDockMenuRenderer : ToolStripProfessionalRenderer {
    public QuotaDockMenuRenderer() : base(new QuotaDockMenuColorTable()) {
        RoundedEdges = true;
    }
}
'@
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class QuotaCenterNativeWindow {
    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    private const UInt32 SWP_NOSIZE = 0x0001;
    private const UInt32 SWP_NOMOVE = 0x0002;
    private const UInt32 SWP_SHOWWINDOW = 0x0040;
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int x,
        int y,
        int cx,
        int cy,
        UInt32 flags);
    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();
    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, IntPtr lParam);
    public static void BringToTop(IntPtr hWnd) {
        SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        SetForegroundWindow(hWnd);
    }
    public static void BeginDrag(IntPtr hWnd) {
        ReleaseCapture();
        SendMessage(hWnd, 0xA1, new IntPtr(2), IntPtr.Zero);
    }
}
'@

$script:CenterReady = $false
$script:CenterExiting = $false
$script:SelectedProviders = @()
$script:ProviderChecks = @{}
$script:TrayItems = @{}
$script:StatusLabel = $null
$script:OpenTimer = $null
$script:CenterHidden = $false
$script:BrandImages = @{}
$script:CardToggles = @{}
$script:ProviderStatusLabels = @{}
$script:ProviderToggles = @{}
$script:RestartCenter = $false
$script:ActualProviderState = @{}
$script:HostStateAvailable = $false
$script:HostStateUpdatedAt = $null
$script:StateTimer = $null
$script:PendingProviderActions = @{}
$script:PendingProviderSince = @{}
$script:UpdateCheckStarted = $false
$script:UpdateCheckProcess = $null
$script:UpdateCheckInProgress = $false
$script:UpdateResultConsumed = $false
$script:UpdateResultPath = Join-Path $env:TEMP ('quotadock-update-result-' + $PID + '.json')

function Save-State {
    try {
        if (-not (Test-Path -LiteralPath $stateRoot)) {
            New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
        }
        $payload = [pscustomobject]@{
            selected  = @($script:SelectedProviders)
            updatedAt = (Get-Date).ToString('o')
        }
        $json = $payload | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText(
            $stateFile,
            $json,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    catch {
        if ($null -ne $script:StatusLabel) {
            $script:StatusLabel.Text = '设置保存失败：' + $_.Exception.Message
        }
    }
}

function Load-State {
    $default = @('codex', 'opencode', 'grok')
    if (-not (Test-Path -LiteralPath $stateFile)) {
        return $default
    }
    try {
        $data = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $items = @($data.selected | ForEach-Object { [string]$_ })
        $valid = @($items | Where-Object { $providers.Keys -contains $_ })
        if ($valid.Count -gt 0) {
            return $valid
        }
    }
    catch {
    }
    return $default
}

function Write-HostRequest {
    param(
        [ValidateSet('add', 'close', 'remove')]
        [string]$Action,
        [string]$Provider
    )
    $line = $Action + '|' + $Provider + [Environment]::NewLine
    $encoding = New-Object System.Text.UTF8Encoding($false)
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($requestFile, $line, $encoding)
            return
        }
        catch {
            if ($attempt -eq 2) {
                throw
            }
            Start-Sleep -Milliseconds 40
        }
    }
}

function Start-Provider {
    param([string]$Provider)
    $launcher = Join-Path $root 'launch_quota_small_widget.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw ('找不到启动器: ' + $launcher)
    }
    Ensure-HostProcess
    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $launcher
        '-Provider'
        $Provider
        '-SkipHost'
    )
    Start-Process `
        -FilePath $powershell `
        -WindowStyle Hidden `
        -WorkingDirectory $root `
        -ArgumentList $arguments | Out-Null
    Write-HostRequest 'add' $Provider
}

function Set-Status {
    param([string]$Message)
    if ($null -ne $script:StatusLabel) {
        $script:StatusLabel.Text = $Message
    }
}

function Test-ProviderRegistered {
    param([string]$Provider)
    return $providers.Keys -contains $Provider
}

function Ensure-HostProcess {
    $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('pwsh.exe', 'powershell.exe') -and $_.CommandLine -like '*quota_fusion_host.ps1*'
    })
    if ($running.Count -gt 0) {
        return
    }
    $hostPath = Join-Path $root 'quota_fusion_host.ps1'
    if (-not (Test-Path -LiteralPath $hostPath)) {
        throw ('找不到宿主脚本: ' + $hostPath)
    }
    Start-Process -FilePath $powershell -WindowStyle Hidden -WorkingDirectory $root -ArgumentList @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $hostPath
    ) | Out-Null
    Start-Sleep -Milliseconds 260
}

function Start-QuotaDockUpdateCheck {
    if ($script:UpdateCheckStarted) {
        return
    }
    $script:UpdateCheckStarted = $true
    $updateScript = Join-Path $root 'check_for_updates.ps1'
    if (-not (Test-Path -LiteralPath $updateScript)) {
        return
    }
    try {
        Start-Process -FilePath $powershell -WindowStyle Hidden -WorkingDirectory $root -ArgumentList @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            $updateScript
            '-ShowDialog'
        ) | Out-Null
    }
    catch {
        Write-CenterError 'update-check' $_
    }
}

function Invoke-QuotaDockUpdateCheck {
    $updateScript = Join-Path $root 'check_for_updates.ps1'
    if (-not (Test-Path -LiteralPath $updateScript)) {
        Set-Status '更新模块不存在'
        return
    }
    if ($script:UpdateCheckInProgress) {
        Set-Status '更新检查仍在进行…'
        return
    }
    try {
        if (Test-Path -LiteralPath $script:UpdateResultPath) {
            Remove-Item -LiteralPath $script:UpdateResultPath -Force -ErrorAction SilentlyContinue
        }
        $script:UpdateResultConsumed = $false
        $script:UpdateCheckProcess = Start-Process -FilePath $powershell -WindowStyle Hidden -WorkingDirectory $root -PassThru -ArgumentList @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            $updateScript
            '-Force'
            '-Interactive'
            '-ResultPath'
            $script:UpdateResultPath
            '-ResultOnly'
        )
        $script:UpdateCheckInProgress = $true
        Set-Status '正在检查 QuotaDock 更新…'
    }
    catch {
        Write-CenterError 'manual-update-check' $_
        Set-Status ('更新检查失败：' + $_.Exception.Message)
    }
}

function Write-CenterError {
    param([string]$Context, $ErrorRecord)
    try {
        Add-Content -LiteralPath $centerErrorLog -Value ((Get-Date).ToString('o') + ' ' + $Context + "`r`n" + ($ErrorRecord | Out-String)) -Encoding UTF8
    }
    catch {
    }
}

function Read-HostRuntimeState {
    if (-not (Test-Path -LiteralPath $hostStateFile)) {
        return $null
    }
    try {
        $state = Get-Content -LiteralPath $hostStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $hostPid = [int](Get-JsonValue $state 'hostPid')
        if ($hostPid -le 0) {
            return $null
        }
        # This runs on the WinForms UI timer. WMI command-line inspection here
        # made dragging the center and its menus visibly stutter. The state
        # file is written by the host and already carries its PID; a cheap
        # process existence/type check is sufficient for this local handshake.
        $process = Get-Process -Id $hostPid -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.ProcessName -notin @('pwsh', 'powershell')) {
            return $null
        }
        $updatedAt = [string](Get-JsonValue $state 'updatedAt')
        if ([string]::IsNullOrWhiteSpace($updatedAt)) {
            return $null
        }
        $age = [datetimeoffset]::Now - [datetimeoffset]::Parse($updatedAt)
        if ($age.TotalSeconds -gt 20) {
            return $null
        }
        return $state
    }
    catch {
        return $null
    }
}

function Test-ProviderActuallyOpen {
    param([string]$Provider)
    if (-not $script:ActualProviderState.ContainsKey($Provider)) {
        return $false
    }
    $state = $script:ActualProviderState[$Provider]
    $open = [bool](Get-JsonValue $state 'open')
    $visibleProperty = Get-JsonValue $state 'visible'
    return $open -and ($null -eq $visibleProperty -or [bool]$visibleProperty)
}

function Get-ProviderRuntimeCaption {
    param([string]$Provider)
    if ($script:PendingProviderActions.ContainsKey($Provider)) {
        switch ([string]$script:PendingProviderActions[$Provider]) {
            'opening' { return '启动中…' }
            'closing' { return '关闭中…' }
        }
    }
    if (Test-ProviderActuallyOpen $Provider) {
        $state = $script:ActualProviderState[$Provider]
        if ([bool](Get-JsonValue $state 'docked')) {
            return '已打开 · 已吸附'
        }
        if ([bool](Get-JsonValue $state 'minimized')) {
            return '已打开 · 已最小化'
        }
        return '已打开'
    }
    if (-not $script:HostStateAvailable) {
        return '宿主未连接'
    }
    return '未打开'
}

function Sync-HostRuntimeState {
    $state = Read-HostRuntimeState
    $script:ActualProviderState = @{}
    $script:HostStateAvailable = $null -ne $state
    $script:HostStateUpdatedAt = if ($null -ne $state) { [string](Get-JsonValue $state 'updatedAt') } else { $null }
    if ($null -ne $state) {
        foreach ($entry in @(Get-JsonValue $state 'providers')) {
            $id = ([string](Get-JsonValue $entry 'id')).Trim().ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $script:ActualProviderState[$id] = $entry
            }
        }
    }
    $now = [datetime]::UtcNow
    foreach ($provider in $providers.Keys) {
        $isOpen = Test-ProviderActuallyOpen $provider
        $pending = if ($script:PendingProviderActions.ContainsKey($provider)) { [string]$script:PendingProviderActions[$provider] } else { '' }
        $pendingSince = if ($script:PendingProviderSince.ContainsKey($provider)) { $script:PendingProviderSince[$provider] } else { $null }
        $pendingAge = if ($pendingSince -is [datetime]) { ($now - $pendingSince.ToUniversalTime()).TotalSeconds } else { 0 }
        $completionMessage = $null
        if ($isOpen -and $pending -eq 'opening') {
            $script:PendingProviderActions.Remove($provider)
            $script:PendingProviderSince.Remove($provider)
            $pending = ''
            $completionMessage = $providers[$provider].Title + ' 已打开'
        }
        elseif (-not $isOpen -and $pending -eq 'closing') {
            $script:PendingProviderActions.Remove($provider)
            $script:PendingProviderSince.Remove($provider)
            $pending = ''
            $completionMessage = $providers[$provider].Title + ' 已关闭'
        }
        elseif ($pending -ne '' -and $pendingAge -ge 8) {
            $script:PendingProviderActions.Remove($provider)
            $script:PendingProviderSince.Remove($provider)
            $pending = ''
            $completionMessage = $providers[$provider].Title + ' 操作已结束，当前为' + (Get-ProviderRuntimeCaption $provider)
        }
        $displayOpen = if ($pending -eq 'opening') { $true } elseif ($pending -eq 'closing') { $false } else { $isOpen }
        if ($script:ProviderChecks.ContainsKey($provider)) {
            $check = $script:ProviderChecks[$provider]
            if ($check.Checked -ne $displayOpen) {
                $check.Checked = $displayOpen
            }
        }
        if ($script:ProviderToggles.ContainsKey($provider)) {
            $visualToggle = $script:ProviderToggles[$provider]
            if ($visualToggle.Checked -ne $displayOpen) {
                $visualToggle.Checked = $displayOpen
                $visualToggle.Invalidate()
            }
        }
        Update-ProviderVisual $provider
        if (-not [string]::IsNullOrWhiteSpace($completionMessage)) {
            Set-Status $completionMessage
        }
    }
    Sync-TrayItems
}

function Show-UpdateResult {
    if (-not (Test-Path -LiteralPath $script:UpdateResultPath)) {
        return $false
    }
    try {
        $raw = Get-Content -LiteralPath $script:UpdateResultPath -Raw -Encoding UTF8
        $result = $raw | ConvertFrom-Json
        # Consume the result before showing a modal dialog. If the dialog or
        # cleanup throws, the state timer must not show the same failure again.
        Remove-Item -LiteralPath $script:UpdateResultPath -Force -ErrorAction Stop
        $current = [string](Get-JsonValue $result 'currentVersion')
        $latest = [string](Get-JsonValue $result 'latestVersion')
        $hasUpdate = [bool](Get-JsonValue $result 'hasUpdate')
        $releaseUrl = [string](Get-JsonValue $result 'releaseUrl')
        $checkError = [string](Get-JsonValue $result 'checkError')
        if ([string]::IsNullOrWhiteSpace($current)) { $current = '未知' }
        if (-not [string]::IsNullOrWhiteSpace($checkError)) {
            $title = 'QuotaDock 更新检查失败'
            $body = '当前版本：' + $current + [Environment]::NewLine + [Environment]::NewLine + '原因：' + $checkError
            $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
        }
        elseif ($hasUpdate) {
            $title = '发现 QuotaDock 新版本'
            $body = '当前版本：' + $current + [Environment]::NewLine + '最新版本：' + $latest + [Environment]::NewLine + [Environment]::NewLine + '点击“是”打开 GitHub Release 下载页；不会静默安装。'
            $icon = [System.Windows.Forms.MessageBoxIcon]::Information
        }
        else {
            $title = 'QuotaDock 已是最新版'
            $body = '当前版本：' + $current + [Environment]::NewLine + '已检查版本：' + $latest + [Environment]::NewLine + [Environment]::NewLine + '目前不需要更新。'
            $icon = [System.Windows.Forms.MessageBoxIcon]::Information
        }
        $buttons = if ($hasUpdate -and -not [string]::IsNullOrWhiteSpace($releaseUrl)) { [System.Windows.Forms.MessageBoxButtons]::YesNo } else { [System.Windows.Forms.MessageBoxButtons]::OK }
        $choice = [System.Windows.Forms.MessageBox]::Show($form, $body, $title, $buttons, $icon)
        if ($hasUpdate -and -not [string]::IsNullOrWhiteSpace($releaseUrl) -and $choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process $releaseUrl
        }
        Set-Status '更新检查已完成'
        return $true
    }
    catch {
        Write-CenterError 'read-update-result' $_
        Set-Status ('更新结果读取失败：' + $_.Exception.Message)
        return $false
    }
}

function Sync-UpdateCheckState {
    if (-not $script:UpdateCheckInProgress) { return }
    if ($script:UpdateResultConsumed) { return }
    if (Test-Path -LiteralPath $script:UpdateResultPath) {
        # Mark this result as consumed before entering the modal UI. This is a
        # one-shot handoff even if parsing, deletion, or MessageBox.Show fails.
        $script:UpdateResultConsumed = $true
        $script:UpdateCheckInProgress = $false
        $finishedProcess = $script:UpdateCheckProcess
        $script:UpdateCheckProcess = $null
        if ($null -ne $finishedProcess) {
            try { $finishedProcess.Dispose() } catch {}
        }
        [void](Show-UpdateResult)
        return
    }
    if ($null -ne $script:UpdateCheckProcess) {
        try {
            if ($script:UpdateCheckProcess.HasExited) {
                $script:UpdateCheckInProgress = $false
                $script:UpdateCheckProcess = $null
                Set-Status '更新检查未返回结果'
            }
        }
        catch {
            $script:UpdateCheckInProgress = $false
            $script:UpdateCheckProcess = $null
            Set-Status ('更新检查状态异常：' + $_.Exception.Message)
        }
    }
}

function Sync-TrayItems {
    foreach ($provider in $script:TrayItems.Keys) {
        if ($script:ProviderChecks.ContainsKey($provider)) {
            $item = $script:TrayItems[$provider]
            $item.Checked = Test-ProviderActuallyOpen $provider
            $item.Text = $providers[$provider].Title + '  ·  ' + (Get-ProviderRuntimeCaption $provider)
        }
    }
}

function Apply-ProviderSelection {
    param(
        [string]$Provider,
        [bool]$Enabled
    )
    if (-not $script:CenterReady) {
        return
    }
    try {
        if ($Enabled) {
            if (-not ($script:SelectedProviders -contains $Provider)) {
                $script:SelectedProviders = @($script:SelectedProviders + $Provider)
            }
            $script:PendingProviderActions[$Provider] = 'opening'
            $script:PendingProviderSince[$Provider] = [datetime]::UtcNow
            Start-Provider $Provider
            Set-Status (($providers[$Provider].Title) + ' 正在打开浮窗')
        }
        else {
            $script:SelectedProviders = @($script:SelectedProviders | Where-Object { $_ -ne $Provider })
            $script:PendingProviderActions[$Provider] = 'closing'
            $script:PendingProviderSince[$Provider] = [datetime]::UtcNow
            Write-HostRequest 'close' $Provider
            Set-Status (($providers[$Provider].Title) + ' 正在关闭浮窗')
        }
        Update-ProviderVisual $Provider
        Save-State
        Sync-TrayItems
    }
    catch {
        Set-Status (($providers[$Provider].Title) + ' 操作失败：' + $_.Exception.Message)
    }
}

function Show-Center {
    $script:CenterHidden = $false
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    $form.Show()
    $form.TopMost = $true
    $form.BringToFront()
    $form.Activate()
    [QuotaCenterNativeWindow]::BringToTop($form.Handle)
}

function Hide-Center {
    if ($null -ne $form -and -not $form.IsDisposed) {
        $script:CenterHidden = $true
        if ($null -ne $script:OpenTimer) {
            $script:OpenTimer.Stop()
        }
        $form.Hide()
    }
}

function Exit-Center {
    $script:CenterExiting = $true
    $script:CenterHidden = $true
    if ($null -ne $script:OpenTimer) {
        $script:OpenTimer.Stop()
    }
    if ($null -ne $notify) {
        $notify.Visible = $false
    }
    if ($null -ne $form -and -not $form.IsDisposed) {
        $form.Close()
    }
}

function Open-SelectedProviders {
    foreach ($provider in $script:SelectedProviders) {
        try {
            Start-Provider $provider
            Start-Sleep -Milliseconds 140
        }
        catch {
            Set-Status (($providers[$provider].Title) + ' 启动失败：' + $_.Exception.Message)
        }
    }
}

function Protect-CenterWindow {
    if ($null -eq $form -or $form.IsDisposed -or -not $form.IsHandleCreated) {
        return
    }
    if (-not $form.Visible) {
        return
    }
    $form.TopMost = $true
    [QuotaCenterNativeWindow]::BringToTop($form.Handle)
}

function New-RoundedPath {
    param(
        [int]$Width,
        [int]$Height,
        [int]$Radius
    )
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = [Math]::Min($Radius * 2, [Math]::Min($Width, $Height))
    [void]$path.AddArc(0, 0, $diameter, $diameter, 180, 90)
    [void]$path.AddArc($Width - $diameter, 0, $diameter, $diameter, 270, 90)
    [void]$path.AddArc($Width - $diameter, $Height - $diameter, $diameter, $diameter, 0, 90)
    [void]$path.AddArc(0, $Height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-RoundedRegion {
    param(
        [System.Windows.Forms.Control]$Control,
        [int]$Radius = 18
    )
    $path = New-RoundedPath $Control.Width $Control.Height $Radius
    try {
        $oldRegion = $Control.Region
        $Control.Region = New-Object System.Drawing.Region($path)
        if ($null -ne $oldRegion) {
            $oldRegion.Dispose()
        }
    }
    finally {
        $path.Dispose()
    }
}

function Set-ToolStripRoundedRegion {
    param(
        $Menu,
        [int]$Radius = 14
    )
    if ($null -eq $Menu -or $Menu.IsDisposed -or $Menu.Width -le 0 -or $Menu.Height -le 0) {
        return
    }
    $path = New-RoundedPath $Menu.Width $Menu.Height $Radius
    try {
        $oldRegion = $Menu.Region
        $Menu.Region = New-Object System.Drawing.Region($path)
        if ($null -ne $oldRegion) {
            $oldRegion.Dispose()
        }
    }
    finally {
        $path.Dispose()
    }
}

function Add-DragHandler {
    param([System.Windows.Forms.Control]$Control)
    $Control.Add_MouseDown({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            [QuotaCenterNativeWindow]::BeginDrag($form.Handle)
        }
    })
}

function Load-BrandImage {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }
    if ($script:BrandImages.ContainsKey($Name)) {
        return $script:BrandImages[$Name]
    }
    $path = if ([System.IO.Path]::IsPathRooted($Name)) { $Name } else { Join-Path $root ('assets\brand\' + $Name + '.png') }
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    $image = [System.Drawing.Image]::FromFile($path)
    $script:BrandImages[$Name] = $image
    return $image
}

function Save-CustomProviderConfig {
    param([object[]]$Entries)
    if (-not (Test-Path -LiteralPath $stateRoot)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }
    $payload = [pscustomobject]@{
        version   = 1
        providers = @($Entries)
    }
    $json = $payload | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($customConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-CustomProviderEntries {
    if (-not (Test-Path -LiteralPath $customConfigPath)) {
        return @()
    }
    try {
        $data = Get-Content -LiteralPath $customConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($data.providers)
    }
    catch {
        return @()
    }
}

function Write-CustomProviderTemplate {
    param([string]$Path, [string]$Title)
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Path) {
        return
    }
    $template = [ordered]@{
        title     = $Title
        badge     = '自定义'
        status    = '等待同步'
        updatedAt = $null
        windows   = @(
            [ordered]@{
                label            = '周额度'
                remainingPercent = $null
                resetText        = '重置时间未知'
            }
        )
    }
    $json = $template | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Open-AddProviderDialog {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '添加其他平台'
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.ClientSize = New-Object System.Drawing.Size(660, 510)
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.BackColor = $background
    $dialog.ForeColor = $foreground
    $dialog.Font = New-UiFont 'Microsoft YaHei UI' 14

    $heading = Add-TextLabel '添加自定义额度平台' (New-Object System.Drawing.Point(32, 24)) (New-Object System.Drawing.Size(560, 36)) (New-UiFont 'Microsoft YaHei UI' 24 ([System.Drawing.FontStyle]::Bold)) $foreground $dialog
    $hint = Add-TextLabel '先注册显示卡片，再由同步脚本或你自己的程序更新 JSON。' (New-Object System.Drawing.Point(34, 66)) (New-Object System.Drawing.Size(590, 28)) (New-UiFont 'Microsoft YaHei UI' 15) $muted $dialog

    $nameLabel = Add-TextLabel '平台名称' (New-Object System.Drawing.Point(34, 112)) (New-Object System.Drawing.Size(150, 28)) (New-UiFont 'Microsoft YaHei UI' 15) $subtle $dialog
    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.Location = New-Object System.Drawing.Point(188, 108)
    $nameBox.Size = New-Object System.Drawing.Size(430, 32)
    $nameBox.Text = 'Claude Code'
    $dialog.Controls.Add($nameBox)

    $idLabel = Add-TextLabel '英文标识' (New-Object System.Drawing.Point(34, 156)) (New-Object System.Drawing.Size(150, 28)) (New-UiFont 'Microsoft YaHei UI' 15) $subtle $dialog
    $idBox = New-Object System.Windows.Forms.TextBox
    $idBox.Location = New-Object System.Drawing.Point(188, 152)
    $idBox.Size = New-Object System.Drawing.Size(430, 32)
    $idBox.Text = 'claude'
    $dialog.Controls.Add($idBox)

    $descriptionLabel = Add-TextLabel '卡片说明' (New-Object System.Drawing.Point(34, 200)) (New-Object System.Drawing.Size(150, 28)) (New-UiFont 'Microsoft YaHei UI' 15) $subtle $dialog
    $descriptionBox = New-Object System.Windows.Forms.TextBox
    $descriptionBox.Location = New-Object System.Drawing.Point(188, 196)
    $descriptionBox.Size = New-Object System.Drawing.Size(430, 32)
    $descriptionBox.Text = '周额度 · 自定义同步'
    $dialog.Controls.Add($descriptionBox)

    $dataLabel = Add-TextLabel '额度 JSON' (New-Object System.Drawing.Point(34, 244)) (New-Object System.Drawing.Size(150, 28)) (New-UiFont 'Microsoft YaHei UI' 15) $subtle $dialog
    $dataBox = New-Object System.Windows.Forms.TextBox
    $dataBox.Location = New-Object System.Drawing.Point(188, 240)
    $dataBox.Size = New-Object System.Drawing.Size(330, 32)
    $dataBox.Text = (Join-Path $customDataRoot 'claude.json')
    $dialog.Controls.Add($dataBox)
    $browseData = New-Object System.Windows.Forms.Button
    $browseData.Text = '选择…'
    $browseData.Location = New-Object System.Drawing.Point(532, 239)
    $browseData.Size = New-Object System.Drawing.Size(86, 34)
    $browseData.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $browseData.ForeColor = $foreground
    $browseData.BackColor = $surfaceRaised
    $browseData.Add_Click({
        $save = New-Object System.Windows.Forms.SaveFileDialog
        $save.Filter = 'JSON 文件 (*.json)|*.json|所有文件 (*.*)|*.*'
        $save.FileName = [System.IO.Path]::GetFileName($dataBox.Text)
        if ($save.ShowDialog($dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
            $dataBox.Text = $save.FileName
        }
        $save.Dispose()
    }.GetNewClosure())
    $dialog.Controls.Add($browseData)

    $brandLabel = Add-TextLabel '品牌图标（可选）' (New-Object System.Drawing.Point(34, 288)) (New-Object System.Drawing.Size(150, 28)) (New-UiFont 'Microsoft YaHei UI' 15) $subtle $dialog
    $brandBox = New-Object System.Windows.Forms.TextBox
    $brandBox.Location = New-Object System.Drawing.Point(188, 284)
    $brandBox.Size = New-Object System.Drawing.Size(330, 32)
    $dialog.Controls.Add($brandBox)
    $browseBrand = New-Object System.Windows.Forms.Button
    $browseBrand.Text = '选择…'
    $browseBrand.Location = New-Object System.Drawing.Point(532, 283)
    $browseBrand.Size = New-Object System.Drawing.Size(86, 34)
    $browseBrand.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $browseBrand.ForeColor = $foreground
    $browseBrand.BackColor = $surfaceRaised
    $browseBrand.Add_Click({
        $open = New-Object System.Windows.Forms.OpenFileDialog
        $open.Filter = 'PNG 图标 (*.png)|*.png|图像文件 (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg|所有文件 (*.*)|*.*'
        if ($open.ShowDialog($dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
            $brandBox.Text = $open.FileName
        }
        $open.Dispose()
    }.GetNewClosure())
    $dialog.Controls.Add($browseBrand)

    $schema = Add-TextLabel "JSON 格式：{ windows: [{ label: '周额度', remainingPercent: 75, resetText: '示例：周六 12:00' }], updatedAt: '2026-01-01T00:00:00Z' }`r`n保存后会自动生成模板；QuotaDock 只读取本地文件，不会代替第三方平台完成登录或抓取。" (New-Object System.Drawing.Point(34, 334)) (New-Object System.Drawing.Size(590, 70)) (New-UiFont 'Microsoft YaHei UI' 13) $muted $dialog

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Location = New-Object System.Drawing.Point(388, 444)
    $cancel.Size = New-Object System.Drawing.Size(106, 40)
    $cancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cancel.ForeColor = $muted
    $cancel.BackColor = $surfaceRaised
    $cancel.Add_Click({ $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dialog.Close() }.GetNewClosure())
    $dialog.Controls.Add($cancel)

    $create = New-Object System.Windows.Forms.Button
    $create.Text = '创建并显示'
    $create.Location = New-Object System.Drawing.Point(506, 444)
    $create.Size = New-Object System.Drawing.Size(112, 40)
    $create.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $create.ForeColor = $foreground
    $create.BackColor = $accentSoft
    $create.Add_Click({
        $id = $idBox.Text.Trim().ToLowerInvariant()
        $title = $nameBox.Text.Trim()
        $dataPath = [Environment]::ExpandEnvironmentVariables($dataBox.Text.Trim())
        if ([string]::IsNullOrWhiteSpace($title)) {
            [System.Windows.Forms.MessageBox]::Show($dialog, '请填写平台名称。', '无法创建', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if ($id -notmatch '^[a-z0-9][a-z0-9_-]{1,31}$') {
            [System.Windows.Forms.MessageBox]::Show($dialog, '英文标识只能使用小写字母、数字、下划线或短横线，长度 2–32。', '无法创建', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if ($providers.Keys -contains $id) {
            [System.Windows.Forms.MessageBox]::Show($dialog, '这个英文标识已经存在，请换一个。', '无法创建', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if ([string]::IsNullOrWhiteSpace($dataPath)) {
            $dataPath = Join-Path $customDataRoot ($id + '.json')
        }
        elseif ([string]::Equals($dataPath, (Join-Path $customDataRoot 'claude.json'), [System.StringComparison]::OrdinalIgnoreCase)) {
            # The dialog starts with a Claude example; use the new ID for other platforms.
            $dataPath = Join-Path $customDataRoot ($id + '.json')
        }
        if (-not [System.IO.Path]::IsPathRooted($dataPath)) {
            $dataPath = [System.IO.Path]::GetFullPath((Join-Path $root $dataPath))
        }
        if ([System.IO.Path]::GetExtension($dataPath) -ne '.json') {
            $dataPath += '.json'
        }
        try {
            $entries = @(Get-CustomProviderEntries)
            $entries += [pscustomobject]@{
                id          = $id
                title       = $title
                description = $descriptionBox.Text.Trim()
                dataPath    = $dataPath
                brandPath   = [Environment]::ExpandEnvironmentVariables($brandBox.Text.Trim())
            }
            Save-CustomProviderConfig $entries
            Write-CustomProviderTemplate $dataPath $title
            $dialog.Tag = $id
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
        catch {
            Write-CenterError 'add-provider-submit' $_
            [System.Windows.Forms.MessageBox]::Show($dialog, ('保存失败：' + $_.Exception.Message), '无法创建', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }.GetNewClosure())
    $dialog.Controls.Add($create)
    $dialog.AcceptButton = $create
    $dialog.CancelButton = $cancel
    $dialogResult = $dialog.ShowDialog($form)
    $createdId = [string]$dialog.Tag
    $dialog.Dispose()
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK -and -not [string]::IsNullOrWhiteSpace($createdId)) {
        $script:SelectedProviders = @($script:SelectedProviders + $createdId | Select-Object -Unique)
        Save-State
        $script:RestartCenter = $true
        Exit-Center
    }
}

function New-UiFont {
    param(
        [string]$Family,
        [single]$Pixels,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    return New-Object System.Drawing.Font(
        $Family,
        $Pixels,
        $Style,
        [System.Drawing.GraphicsUnit]::Pixel
    )
}

function Add-TextLabel {
    param(
        [string]$Text,
        [System.Drawing.Point]$Location,
        [System.Drawing.Size]$Size,
        [System.Drawing.Font]$Font,
        $Color,
        [System.Windows.Forms.Control]$Parent,
        [bool]$AutoSize = $false
    )
    # Keep a missing or string-valued palette entry from aborting the whole
    # dialog during PowerShell parameter binding.  The normal path passes a
    # System.Drawing.Color; the fallback is only defensive.
    if ($null -eq $Color) {
        $Color = [System.Drawing.Color]::White
    }
    elseif ($Color -isnot [System.Drawing.Color]) {
        $Color = [System.Drawing.Color]::FromName([string]$Color)
        if ($Color.IsEmpty) {
            $Color = [System.Drawing.Color]::White
        }
    }
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = $Location
    $label.Size = $Size
    $label.Font = $Font
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.AutoSize = $AutoSize
    $label.UseCompatibleTextRendering = $false
    $Parent.Controls.Add($label)
    return $label
}

function Get-ProviderCardColor {
    param(
        [string]$Provider,
        [bool]$Hover = $false
    )
    if (Test-ProviderActuallyOpen $Provider) {
        if ($Hover) { return [System.Drawing.Color]::FromArgb(36, 61, 80) }
        return [System.Drawing.Color]::FromArgb(30, 49, 65)
    }
    if ($script:PendingProviderActions.ContainsKey($Provider)) {
        if ($Hover) { return [System.Drawing.Color]::FromArgb(52, 55, 72) }
        return [System.Drawing.Color]::FromArgb(44, 46, 62)
    }
    if ($Hover) { return $surfaceHover }
    return $surfaceRaised
}

function Update-ProviderVisual {
    param([string]$Provider)
    if ($script:CardToggles.ContainsKey($Provider)) {
        $card = $script:CardToggles[$Provider]
        $card.BackColor = Get-ProviderCardColor $Provider
        $card.Invalidate()
    }
    if ($script:ProviderChecks.ContainsKey($Provider)) {
        $script:ProviderChecks[$Provider].Invalidate()
    }
    if ($script:ProviderStatusLabels.ContainsKey($Provider)) {
        $label = $script:ProviderStatusLabels[$Provider]
        $label.Text = Get-ProviderRuntimeCaption $Provider
        if (Test-ProviderActuallyOpen $Provider) {
            $label.ForeColor = $accent
        }
        elseif ($script:PendingProviderActions.ContainsKey($Provider)) {
            $label.ForeColor = [System.Drawing.Color]::FromArgb(244, 193, 102)
        }
        else {
            $label.ForeColor = $subtle
        }
    }
}

function Toggle-Provider {
    param([string]$Provider)
    if (-not $script:ProviderChecks.ContainsKey($Provider)) {
        return
    }
    $toggle = $script:ProviderChecks[$Provider]
    Set-ProviderEnabled $Provider (-not [bool]$toggle.Checked)
}

function Set-ProviderEnabled {
    param(
        [string]$Provider,
        [bool]$Enabled
    )
    if (-not $script:ProviderChecks.ContainsKey($Provider)) {
        return
    }
    $toggle = $script:ProviderChecks[$Provider]
    $toggle.Checked = $Enabled
    if ($script:ProviderToggles.ContainsKey($Provider)) {
        $visualToggle = $script:ProviderToggles[$Provider]
        $visualToggle.Checked = $Enabled
        $visualToggle.Invalidate()
    }
    Apply-ProviderSelection $Provider $Enabled
    Update-ProviderVisual $Provider
}

function Remove-ProviderCard {
    param([string]$Provider)
    if (-not (Test-ProviderRegistered $Provider)) {
        return
    }
    $isBuiltIn = $builtInProviderIds -contains $Provider
    $title = ([string]$providers[$Provider].Title).Trim()
    $message = if ($isBuiltIn) {
        '确定要从当前 QuotaDock 显示列表移除“' + $title + '”额度框吗？' + [Environment]::NewLine + [Environment]::NewLine + '平台配置会保留，之后仍可从 QuotaDock 重新打开。'
    }
    else {
        '确定要从 QuotaDock 删除“' + $title + '”额度框吗？' + [Environment]::NewLine + [Environment]::NewLine + '只会移除平台卡片和显示配置，保留本地 JSON 数据文件。'
    }
    $choice = [System.Windows.Forms.MessageBox]::Show(
        $form,
        $message,
        $(if ($isBuiltIn) { '确认移除额度框' } else { '确认删除额度框' }),
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }
    try {
        if ($isBuiltIn) {
            $script:PendingProviderActions[$Provider] = 'closing'
            Write-HostRequest 'close' $Provider
            $script:SelectedProviders = @($script:SelectedProviders | Where-Object { $_ -ne $Provider })
            Save-State
            Set-Status (($title) + ' 已从当前显示列表移除')
            Update-ProviderVisual $Provider
            Sync-TrayItems
            return
        }

        Write-HostRequest 'remove' $Provider
        $remaining = @(Get-CustomProviderEntries | Where-Object { ([string]$_.id).Trim().ToLowerInvariant() -ne $Provider })
        Save-CustomProviderConfig $remaining
        $script:SelectedProviders = @($script:SelectedProviders | Where-Object { $_ -ne $Provider })
        Save-State
        Set-Status (($title) + ' 已删除，正在刷新 QuotaDock')
        $script:RestartCenter = $true
        Exit-Center
    }
    catch {
        Write-CenterError 'remove-provider' $_
        $failurePrefix = if ($isBuiltIn) { '移除失败：' } else { '删除失败：' }
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            ($failurePrefix + $_.Exception.Message),
            $(if ($isBuiltIn) { '无法移除' } else { '无法删除' }),
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function New-ProviderContextMenu {
    param([string]$Provider)
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Renderer = New-Object QuotaDockMenuRenderer
    $menu.ShowImageMargin = $false
    $menu.ShowCheckMargin = $false
    $menu.AutoSize = $true
    $menu.Padding = New-Object System.Windows.Forms.Padding(16, 14, 16, 14)
    $menu.MinimumSize = New-Object System.Drawing.Size(340, 0)
    $menu.Font = New-UiFont 'Microsoft YaHei UI' 16

    $titleItem = New-Object System.Windows.Forms.ToolStripMenuItem($providers[$Provider].Title)
    $titleItem.Enabled = $false
    $titleItem.Font = New-UiFont 'Microsoft YaHei UI' 16 ([System.Drawing.FontStyle]::Bold)
    [void]$menu.Items.Add($titleItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $toggleItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $toggleItem.Text = if (Test-ProviderActuallyOpen $Provider) { '关闭额度浮窗' } else { '打开额度浮窗' }
    $toggleItem.Add_Click({
        Set-ProviderEnabled $Provider (-not (Test-ProviderActuallyOpen $Provider))
    }.GetNewClosure())
    [void]$menu.Items.Add($toggleItem)

    $removeText = if ($builtInProviderIds -contains $Provider) { '移除当前额度框' } else { '删除此额度框' }
    $removeItem = New-Object System.Windows.Forms.ToolStripMenuItem($removeText)
    $removeItem.Add_Click({ Remove-ProviderCard $Provider }.GetNewClosure())
    [void]$menu.Items.Add($removeItem)
    foreach ($item in @($menu.Items)) {
        if ($item -is [System.Windows.Forms.ToolStripMenuItem]) {
            $item.Font = $menu.Font
            $item.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
        }
    }
    $menu.Add_Opened({
        Set-ToolStripRoundedRegion $menu 14
    }.GetNewClosure())
    # Do not dispose this transient menu from Closed. ContextMenuStrip can
    # raise Closed while Show is still completing, which disposes the object
    # before WinForms finishes the Show call and breaks every right-click.
    return ,$menu
}

function Show-ProviderMenu {
    param(
        [string]$Provider,
        [System.Windows.Forms.Control]$Source
    )
    if (-not (Test-ProviderRegistered $Provider) -or $null -eq $Source) {
        return
    }
    if ($Source.IsDisposed) {
        return
    }
    try {
        $menu = New-ProviderContextMenu $Provider
        $menu.Show([System.Windows.Forms.Cursor]::Position)
    }
    catch {
        Write-CenterError 'provider-context-menu' $_
        Set-Status (($providers[$Provider].Title) + ' 菜单打开失败：' + $_.Exception.Message)
    }
}

function Add-ProviderContextHandler {
    param(
        [System.Windows.Forms.Control]$Control,
        [string]$Provider
    )
    if ($null -eq $Control) {
        return
    }
    $Control.Add_MouseDown({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            Show-ProviderMenu $Provider $sender
        }
    }.GetNewClosure())
}

function New-ProviderToggle {
    param(
        [string]$Provider,
        [System.Windows.Forms.Control]$Parent,
        [System.Drawing.Point]$Location,
        [bool]$Checked
    )
    $toggle = New-Object System.Windows.Forms.Panel
    $toggle.Tag = $Provider
    $toggle.Location = $Location
    $toggle.Size = New-Object System.Drawing.Size(68, 36)
    # Keep the pointer stable across the glass panel. The Windows hand cursor
    # is visibly smaller on this high-DPI desktop and causes an abrupt jump.
    $toggle.Cursor = [System.Windows.Forms.Cursors]::Arrow
    Add-Member -InputObject $toggle -MemberType NoteProperty -Name Checked -Value $Checked -Force
    $toggle.Add_Paint({
        param($sender, $eventArgs)
        $graphics = $eventArgs.Graphics
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $trackColor = if ($sender.Checked) { $accent } else { [System.Drawing.Color]::FromArgb(72, 82, 97) }
        $trackPath = New-RoundedPath $sender.Width $sender.Height 18
        try {
            $trackBrush = New-Object System.Drawing.SolidBrush($trackColor)
            try { $graphics.FillPath($trackBrush, $trackPath) } finally { $trackBrush.Dispose() }
        }
        finally { $trackPath.Dispose() }
        $knobSize = 28
        $knobX = if ($sender.Checked) { $sender.Width - $knobSize - 4 } else { 4 }
        $knobRect = New-Object System.Drawing.Rectangle($knobX, 4, $knobSize, $knobSize)
        $knobBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(248, 250, 253))
        try { $graphics.FillEllipse($knobBrush, $knobRect) } finally { $knobBrush.Dispose() }
    })
    $toggle.Add_Click({
        param($sender, $eventArgs)
        $id = [string]$sender.Tag
        Toggle-Provider $id
    })
    $Parent.Controls.Add($toggle)
    return $toggle
}

$selected = Load-State
$script:SelectedProviders = @($selected)

$background = [System.Drawing.Color]::FromArgb(20, 23, 29)
$surface = [System.Drawing.Color]::FromArgb(30, 35, 43)
$surfaceRaised = [System.Drawing.Color]::FromArgb(38, 44, 54)
$surfaceHover = [System.Drawing.Color]::FromArgb(48, 56, 68)
$foreground = [System.Drawing.Color]::FromArgb(246, 248, 252)
$muted = [System.Drawing.Color]::FromArgb(171, 181, 196)
$subtle = [System.Drawing.Color]::FromArgb(126, 137, 153)
$accent = [System.Drawing.Color]::FromArgb(112, 191, 255)
$accentSoft = [System.Drawing.Color]::FromArgb(35, 79, 111)
$border = [System.Drawing.Color]::FromArgb(63, 73, 88)
$success = [System.Drawing.Color]::FromArgb(115, 218, 164)

# Keep native DPI rendering, but give the typography and provider cards a
# clearly readable desktop scale instead of treating the panel like a chip.
$uiWidth = 860
$uiMargin = 48
$cardWidth = $uiWidth - ($uiMargin * 2)
$cardHeight = 132
$cardGap = 24
$bottomButtonWidth = 184
$futureY = 176 + ($providers.Count * ($cardHeight + $cardGap))
$uiHeight = [Math]::Max(800, $futureY + 64 + 86)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'QuotaDock'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
# This window uses an explicit pixel layout. DPI awareness keeps the pixels
# native; automatic WinForms scaling would scale the hand-positioned controls
# a second time and can clip labels.
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.ClientSize = New-Object System.Drawing.Size($uiWidth, $uiHeight)
$form.MinimumSize = $form.Size
$form.MaximumSize = $form.Size
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(
    ($workArea.Left + 24),
    ($workArea.Bottom - $form.Height - 24)
)
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = $background
$form.ForeColor = $foreground
$form.Font = New-UiFont 'Microsoft YaHei UI' 13
$form.Cursor = [System.Windows.Forms.Cursors]::Arrow
$form.Padding = New-Object System.Windows.Forms.Padding(1)
$form.Add_Shown({ Set-RoundedRegion $form 30 })
$form.Add_Resize({
    if ($form.IsHandleCreated) {
        Set-RoundedRegion $form 30
    }
})

$chrome = New-Object System.Windows.Forms.Panel
$chrome.Dock = [System.Windows.Forms.DockStyle]::Fill
$chrome.BackColor = $background
$form.Controls.Add($chrome)
$chrome.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [QuotaCenterNativeWindow]::BeginDrag($form.Handle)
    }
})

$title = New-Object System.Windows.Forms.Label
$title.Text = 'QuotaDock'
$title.Location = New-Object System.Drawing.Point(120, 30)
$title.AutoSize = $true
$title.Font = New-UiFont 'Microsoft YaHei UI' 40 ([System.Drawing.FontStyle]::Bold)
$title.ForeColor = $foreground
$title.BackColor = [System.Drawing.Color]::Transparent
$chrome.Controls.Add($title)
Add-DragHandler $title

$appLogoPath = Join-Path $root 'assets\app\QuotaDock-v2.png'
if (Test-Path -LiteralPath $appLogoPath) {
    $appLogo = New-Object System.Windows.Forms.PictureBox
    $appLogo.Location = New-Object System.Drawing.Point(48, 26)
    $appLogo.Size = New-Object System.Drawing.Size(56, 56)
    $appLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $appLogo.BackColor = [System.Drawing.Color]::Transparent
    $appLogo.Image = [System.Drawing.Image]::FromFile($appLogoPath)
    $chrome.Controls.Add($appLogo)
    Add-DragHandler $appLogo
}

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = '选择平台，桌面浮窗会按你的选择显示。'
$subtitle.Location = New-Object System.Drawing.Point(52, 100)
$subtitle.Size = New-Object System.Drawing.Size(680, 34)
$subtitle.Font = New-UiFont 'Microsoft YaHei UI' 19
$subtitle.ForeColor = $muted
$subtitle.BackColor = [System.Drawing.Color]::Transparent
$subtitle.UseCompatibleTextRendering = $false
$chrome.Controls.Add($subtitle)
Add-DragHandler $subtitle

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = '×'
$closeButton.Location = New-Object System.Drawing.Point(($uiWidth - 86), 30)
$closeButton.Size = New-Object System.Drawing.Size(48, 48)
$closeButton.Font = New-UiFont 'Segoe UI Symbol' 30
$closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$closeButton.FlatAppearance.BorderSize = 0
$closeButton.BackColor = $background
$closeButton.ForeColor = $muted
$closeButton.UseCompatibleTextRendering = $false
$closeButton.Cursor = [System.Windows.Forms.Cursors]::Arrow
$closeButton.Add_Click({ Hide-Center })
$chrome.Controls.Add($closeButton)

$updateButton = New-Object System.Windows.Forms.Button
$updateButton.Text = '↑  检查更新'
$updateButton.Location = New-Object System.Drawing.Point(($uiWidth - 254), 34)
$updateButton.Size = New-Object System.Drawing.Size(150, 42)
$updateButton.Font = New-UiFont 'Microsoft YaHei UI' 14 ([System.Drawing.FontStyle]::Bold)
$updateButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$updateButton.FlatAppearance.BorderSize = 1
$updateButton.FlatAppearance.BorderColor = $border
$updateButton.FlatAppearance.MouseOverBackColor = $surfaceHover
$updateButton.BackColor = $surface
$updateButton.ForeColor = $foreground
$updateButton.UseCompatibleTextRendering = $false
$updateButton.Cursor = [System.Windows.Forms.Cursors]::Arrow
$updateButton.Add_Click({ Invoke-QuotaDockUpdateCheck })
$chrome.Controls.Add($updateButton)
Set-RoundedRegion $updateButton 12
$updateTip = New-Object System.Windows.Forms.ToolTip
$updateTip.SetToolTip($updateButton, '检查 QuotaDock 更新')

$divider = New-Object System.Windows.Forms.Panel
$divider.Location = New-Object System.Drawing.Point($uiMargin, 150)
$divider.Size = New-Object System.Drawing.Size($cardWidth, 1)
$divider.BackColor = $border
$chrome.Controls.Add($divider)

$index = 0
foreach ($provider in $providers.Keys) {
    $profile = $providers[$provider]
    $y = 176 + ($index * ($cardHeight + $cardGap))

    $card = New-Object System.Windows.Forms.Panel
    $card.Tag = $provider
    $card.Location = New-Object System.Drawing.Point($uiMargin, $y)
    $card.Size = New-Object System.Drawing.Size($cardWidth, $cardHeight)
    $card.BackColor = $surface
    $card.Cursor = [System.Windows.Forms.Cursors]::Arrow
    $chrome.Controls.Add($card)
    Set-RoundedRegion $card 20

    $brandName = switch ($provider) {
        'codex' { 'chatgpt-mark' }
        'opencode' { 'opencode-mark' }
        'grok' { 'grok-mark' }
        default { $profile.BrandPath }
    }
    $brandBox = $null
    $brand = Load-BrandImage $brandName
    if ($null -ne $brand) {
        $brandBox = New-Object System.Windows.Forms.PictureBox
        $brandBox.Location = New-Object System.Drawing.Point(22, 32)
        $brandBox.Size = New-Object System.Drawing.Size(68, 68)
        $brandBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $brandBox.BackColor = [System.Drawing.Color]::Transparent
        $brandBox.Image = $brand
        $card.Controls.Add($brandBox)
    }

    $check = New-Object System.Windows.Forms.CheckBox
    $check.Tag = $provider
    $check.Text = ''
    $check.Location = New-Object System.Drawing.Point(0, 0)
    $check.Size = New-Object System.Drawing.Size(1, 1)
    $check.Visible = $false
    $check.Checked = ($script:SelectedProviders -contains $provider)
    $check.Add_CheckedChanged({
        param($sender, $eventArgs)
        $id = [string]$sender.Tag
        Update-ProviderVisual $id
    }.GetNewClosure())
    $script:ProviderChecks[$provider] = $check
    $card.Controls.Add($check)

    $nameLabel = Add-TextLabel $profile.Title (New-Object System.Drawing.Point(116, 22)) (New-Object System.Drawing.Size(380, 38)) (New-UiFont 'Microsoft YaHei UI' 28 ([System.Drawing.FontStyle]::Bold)) $foreground $card
    $descriptionLabel = Add-TextLabel $profile.Description (New-Object System.Drawing.Point(116, 70)) (New-Object System.Drawing.Size(390, 30)) (New-UiFont 'Microsoft YaHei UI' 18) $muted $card
    $statusText = Get-ProviderRuntimeCaption $provider
    $statusColor = if (Test-ProviderActuallyOpen $provider) { $accent } else { $subtle }
    $statusLabel = Add-TextLabel $statusText (New-Object System.Drawing.Point(514, 76)) (New-Object System.Drawing.Size(154, 26)) (New-UiFont 'Microsoft YaHei UI' 15) $statusColor $card
    $script:ProviderStatusLabels[$provider] = $statusLabel

    $toggle = New-ProviderToggle $provider $card (New-Object System.Drawing.Point(($cardWidth - 86), 48)) ([bool]$check.Checked)
    $script:ProviderToggles[$provider] = $toggle
    $card.BackColor = Get-ProviderCardColor $provider $false
    Add-ProviderContextHandler $card $provider
    Add-ProviderContextHandler $nameLabel $provider
    Add-ProviderContextHandler $descriptionLabel $provider
    Add-ProviderContextHandler $brandBox $provider
    Add-ProviderContextHandler $toggle $provider

    $card.Add_MouseEnter({
        param($sender, $eventArgs)
        $id = [string]$sender.Tag
        $sender.BackColor = Get-ProviderCardColor $id $true
    }.GetNewClosure())
    $card.Add_MouseLeave({
        param($sender, $eventArgs)
        $id = [string]$sender.Tag
        $sender.BackColor = Get-ProviderCardColor $id $false
    }.GetNewClosure())
    $card.Add_MouseDown({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            Toggle-Provider ([string]$sender.Tag)
        }
    }.GetNewClosure())
    $nameLabel.Add_Click({
        param($sender, $eventArgs)
        $id = [string]$sender.Parent.Tag
        Toggle-Provider $id
    }.GetNewClosure())
    $descriptionLabel.Add_Click({
        param($sender, $eventArgs)
        $id = [string]$sender.Parent.Tag
        Toggle-Provider $id
    }.GetNewClosure())
    $index++
}

$future = New-Object System.Windows.Forms.Button
$future.Text = '+  添加其他平台'
$future.Location = New-Object System.Drawing.Point($uiMargin, $futureY)
$future.Size = New-Object System.Drawing.Size($cardWidth, 64)
$future.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$future.FlatAppearance.BorderColor = $border
$future.FlatAppearance.MouseOverBackColor = $surfaceHover
$future.BackColor = $surface
$future.ForeColor = $foreground
$future.Font = New-UiFont 'Microsoft YaHei UI' 20 ([System.Drawing.FontStyle]::Bold)
$future.UseCompatibleTextRendering = $false
$future.Cursor = [System.Windows.Forms.Cursors]::Arrow
$future.Enabled = $true
$future.Add_Click({
    try {
        Open-AddProviderDialog
    }
    catch {
        Write-CenterError 'add-provider-click' $_
        Set-Status ('添加平台失败：' + $_.Exception.Message)
    }
})
$chrome.Controls.Add($future)
Set-RoundedRegion $future 16

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Text = '选择已自动保存'
$script:StatusLabel.Location = New-Object System.Drawing.Point(52, ($uiHeight - 56))
$script:StatusLabel.Size = New-Object System.Drawing.Size(420, 34)
$script:StatusLabel.Font = New-UiFont 'Microsoft YaHei UI' 18
$script:StatusLabel.ForeColor = $success
$script:StatusLabel.BackColor = [System.Drawing.Color]::Transparent
$script:StatusLabel.UseCompatibleTextRendering = $false
$chrome.Controls.Add($script:StatusLabel)

$trayButton = New-Object System.Windows.Forms.Button
$trayButton.Text = '隐藏到托盘'
$trayButton.Location = New-Object System.Drawing.Point(($uiWidth - $uiMargin - $bottomButtonWidth), ($uiHeight - 62))
$trayButton.Size = New-Object System.Drawing.Size($bottomButtonWidth, 54)
$trayButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$trayButton.FlatAppearance.BorderColor = $border
$trayButton.FlatAppearance.MouseOverBackColor = $surfaceHover
$trayButton.BackColor = $surface
$trayButton.ForeColor = $foreground
$trayButton.Font = New-UiFont 'Microsoft YaHei UI' 17
$trayButton.UseCompatibleTextRendering = $false
$trayButton.Cursor = [System.Windows.Forms.Cursors]::Arrow
$trayButton.Add_Click({ Hide-Center })
$chrome.Controls.Add($trayButton)
Set-RoundedRegion $trayButton 14

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Renderer = New-Object QuotaDockMenuRenderer
$menu.BackColor = [System.Drawing.Color]::FromArgb(27, 33, 43)
$menu.ForeColor = $foreground
$menu.ShowImageMargin = $false
$menu.ShowCheckMargin = $true
$menu.AutoSize = $true
$menu.Padding = New-Object System.Windows.Forms.Padding(16, 14, 16, 14)
$menu.MinimumSize = New-Object System.Drawing.Size(340, 0)
$menu.Font = New-UiFont 'Microsoft YaHei UI' 16

$menuTitle = New-Object System.Windows.Forms.ToolStripMenuItem('QuotaDock  ·  浮窗控制')
$menuTitle.Enabled = $false
$menuTitle.Font = New-UiFont 'Microsoft YaHei UI' 14 ([System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add($menuTitle)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

foreach ($provider in $providers.Keys) {
    $providerTitle = $providers[$provider].Title
    $item = New-Object System.Windows.Forms.ToolStripMenuItem
    $item.Tag = $provider
    $item.CheckOnClick = $false
    $item.Text = $providerTitle + '  ·  ' + (Get-ProviderRuntimeCaption $provider)
    $item.Add_Click({
        param($sender, $eventArgs)
        $id = [string]$sender.Tag
        Set-ProviderEnabled $id (-not (Test-ProviderActuallyOpen $id))
    }.GetNewClosure())
    $script:TrayItems[$provider] = $item
    [void]$menu.Items.Add($item)
}

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$openItem = New-Object System.Windows.Forms.ToolStripMenuItem('打开 QuotaDock')
$openItem.Add_Click({ Show-Center })
[void]$menu.Items.Add($openItem)

$allOnItem = New-Object System.Windows.Forms.ToolStripMenuItem('全部显示')
$allOnItem.Add_Click({
    foreach ($provider in $providers.Keys) {
        Set-ProviderEnabled $provider $true
    }
})
[void]$menu.Items.Add($allOnItem)

$allOffItem = New-Object System.Windows.Forms.ToolStripMenuItem('全部关闭')
$allOffItem.Add_Click({
    foreach ($provider in $providers.Keys) {
        Set-ProviderEnabled $provider $false
    }
})
[void]$menu.Items.Add($allOffItem)

$refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem('刷新运行状态')
$refreshItem.Add_Click({ Sync-HostRuntimeState; Set-Status '运行状态已刷新' })
[void]$menu.Items.Add($refreshItem)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('退出 QuotaDock')
[void]$menu.Items.Add($exitItem)

foreach ($item in @($menu.Items)) {
    if ($item -is [System.Windows.Forms.ToolStripMenuItem]) {
        $item.Font = $menu.Font
        $item.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
    }
}

$notify = New-Object System.Windows.Forms.NotifyIcon
if (Test-Path -LiteralPath $appIconPath) {
    $form.Icon = New-Object System.Drawing.Icon($appIconPath)
    $notify.Icon = New-Object System.Drawing.Icon($appIconPath)
}
else {
    $notify.Icon = [System.Drawing.SystemIcons]::Application
}
$notify.Text = 'QuotaDock'
$notify.ContextMenuStrip = $menu
$notify.Visible = $true
$notify.Add_DoubleClick({ Show-Center })
$menu.Add_Opening({ Sync-HostRuntimeState; Sync-TrayItems })
$menu.Add_Opened({ Set-ToolStripRoundedRegion $menu 16 }.GetNewClosure())

$exitItem.Add_Click({ Exit-Center })

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $script:CenterExiting) {
        $eventArgs.Cancel = $true
        Hide-Center
    }
})

$script:CenterReady = $true
Sync-HostRuntimeState
Save-State
Show-Center
Start-QuotaDockUpdateCheck

$openTimer = New-Object System.Windows.Forms.Timer
$script:OpenTimer = $openTimer
$openTimer.Interval = 350
$openTimer.Add_Tick({
    $openTimer.Stop()
    Open-SelectedProviders
})
$openTimer.Start()

$stateTimer = New-Object System.Windows.Forms.Timer
$stateTimer.Interval = 350
$script:StateTimer = $stateTimer
$stateTimer.Add_Tick({
    try {
        Sync-HostRuntimeState
        Sync-UpdateCheckState
    }
    catch {
        Write-CenterError 'runtime-state-timer' $_
    }
})
$stateTimer.Start()

try {
    [System.Windows.Forms.Application]::Run($form)
}
finally {
    $openTimer.Stop()
    $script:OpenTimer = $null
    if ($null -ne $script:StateTimer) {
        $script:StateTimer.Stop()
        $script:StateTimer.Dispose()
        $script:StateTimer = $null
    }
    $notify.Visible = $false
    $notify.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

if ($script:RestartCenter) {
    Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path)
}

