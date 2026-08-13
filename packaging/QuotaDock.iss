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
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
english.AutoStartTask=Start QuotaDock when I sign in to Windows
english.StartupOptions=Startup options:
english.LaunchAfterInstall=Launch QuotaDock after installation
english.PowerShellMissing=PowerShell 7 or newer was not found. QuotaDock needs PowerShell 7+ to run. You can install it from https://aka.ms/powershell-release?tag=stable, then launch QuotaDock again.

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

function InitializeSetup(): Boolean;
begin
  Result := True;
  if GetPowerShell7Path() = '' then begin
    MsgBox(CustomMessage('PowerShellMissing'), mbInformation, MB_OK);
  end;
end;
