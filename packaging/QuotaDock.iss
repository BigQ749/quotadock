#define AppVersion "0.1.0"

[Setup]
AppId={{D6F2C99B-1D5E-4F3C-9C7A-000000000001}
AppName=QuotaDock
AppVersion={#AppVersion}
AppPublisher=BigQ749
AppPublisherURL=https://github.com/BigQ749/quotadock
AppSupportURL=https://github.com/BigQ749/quotadock/issues
AppComments=QuotaDock Windows desktop quota dashboard
DefaultDirName={localappdata}\Programs\QuotaDock
DefaultGroupName=QuotaDock
DisableProgramGroupPage=yes
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

[Run]
Filename: "wscript.exe"; Parameters: """{app}\launch_quota_center.vbs"""; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
