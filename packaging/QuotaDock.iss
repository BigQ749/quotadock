#include "QuotaDock.version.iss"

[Setup]
AppId={{D6F2C99B-1D5E-4F3C-9C7A-000000000001}
AppName=QuotaDock
AppVersion={#AppVersion}
AppVerName=QuotaDock {#AppVersion}
AppPublisher=BigQ749
AppPublisherURL=https://github.com/BigQ749/quotadock
AppSupportURL=https://github.com/BigQ749/quotadock/issues
AppComments=QuotaDock Windows desktop quota dashboard
VersionInfoDescription=QuotaDock Windows desktop quota dashboard
VersionInfoProductName=QuotaDock
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\QuotaDock
DefaultGroupName=QuotaDock
DisableProgramGroupPage=yes
DisableDirPage=no
LicenseFile=..\LICENSE
PrivilegesRequired=lowest
ArchitecturesAllowed=x86compatible x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=QuotaDock-Setup-{#AppVersion}
SetupIconFile=..\assets\app\QuotaDock.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=QuotaDock
Uninstallable=yes
CloseApplications=yes
RestartApplications=no

[Languages]
; ChineseSimplified.isl is vendored in packaging/ (Unofficial translation from jrsoftware/issrc).
; Keeps CI/choco builds working when compiler:Languages lacks the file.
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
chinesesimplified.AutoStartTask=登录 Windows 时启动 QuotaDock
chinesesimplified.StartupOptions=启动选项：
chinesesimplified.LaunchAfterInstall=安装完成后启动 QuotaDock
chinesesimplified.PowerShellMissing=未检测到 PowerShell 7（可选）。QuotaDock 已兼容 Windows 自带的 PowerShell 5.1；若仍想安装 PowerShell 7，可打开 https://aka.ms/powershell-release?tag=stable 。
english.AutoStartTask=Start QuotaDock when I sign in to Windows
english.StartupOptions=Startup options:
english.LaunchAfterInstall=Launch QuotaDock after installation
english.PowerShellMissing=PowerShell 7 was not detected (optional). QuotaDock works with Windows PowerShell 5.1; you may still install PowerShell 7 from https://aka.ms/powershell-release?tag=stable .

[Tasks]
Name: "autostart"; Description: "{cm:AutoStartTask}"; GroupDescription: "{cm:StartupOptions}"; Flags: unchecked

[Files]
Source: "..\*.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\*.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\VERSION"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\SECURITY.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\TRADEMARKS.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\examples\*"; DestDir: "{app}\examples"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\opencode-go-quota-bridge\*"; DestDir: "{app}\opencode-go-quota-bridge"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\adapters\*"; DestDir: "{app}\adapters"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\custom-provider.example.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\docs\download.md"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "..\docs\deployment-guide.md"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "..\docs\providers-grokbot-muse-claude.md"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "..\docs\privacy.md"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "..\docs\provider-adapter.md"; DestDir: "{app}\docs"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\QuotaDock"; Filename: "{app}\launch_quota_center.vbs"; WorkingDir: "{app}"; IconFilename: "{app}\assets\app\QuotaDock.ico"; Comment: "管理多个 AI 平台额度浮窗"
Name: "{autodesktop}\QuotaDock"; Filename: "{app}\launch_quota_center.vbs"; WorkingDir: "{app}"; IconFilename: "{app}\assets\app\QuotaDock.ico"; Comment: "管理多个 AI 平台额度浮窗"
Name: "{userstartup}\QuotaDock"; Filename: "{app}\launch_quota_center.vbs"; WorkingDir: "{app}"; IconFilename: "{app}\assets\app\QuotaDock.ico"; Comment: "登录 Windows 时启动 QuotaDock"; Tasks: autostart

[Run]
Filename: "wscript.exe"; Parameters: """{app}\launch_quota_center.vbs"""; WorkingDir: "{app}"; Description: "{cm:LaunchAfterInstall}"; Flags: nowait postinstall skipifsilent

[Code]
function GetPowerShell7Path(): String;
var
  Candidate: String;
begin
  Result := '';
  Candidate := ExpandConstant('{autopf}\PowerShell\7\pwsh.exe');
  if FileExists(Candidate) then begin
    Result := Candidate;
    exit;
  end;
  Candidate := ExpandConstant('{autopf32}\PowerShell\7\pwsh.exe');
  if FileExists(Candidate) then begin
    Result := Candidate;
  end;
end;

function GetWindowsPowerShellPath(): String;
var
  Candidate: String;
begin
  Result := '';
  Candidate := ExpandConstant('{win}\System32\WindowsPowerShell\v1.0\powershell.exe');
  if FileExists(Candidate) then begin
    Result := Candidate;
    exit;
  end;
  Candidate := ExpandConstant('{win}\SysWOW64\WindowsPowerShell\v1.0\powershell.exe');
  if FileExists(Candidate) then begin
    Result := Candidate;
  end;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if (GetPowerShell7Path() = '') and (GetWindowsPowerShellPath() = '') then begin
    MsgBox(CustomMessage('PowerShellMissing'), mbInformation, MB_OK);
  end;
end;
