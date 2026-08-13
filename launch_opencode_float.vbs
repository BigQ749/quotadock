Option Explicit
Dim sh, fso, dir, launcher, cmd, powershell
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
launcher = dir & "\launch_quota_small_widget.ps1"
powershell = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If Not fso.FileExists(powershell) Then powershell = sh.ExpandEnvironmentStrings("%ProgramFiles(x86)%") & "\PowerShell\7\pwsh.exe"
If Not fso.FileExists(powershell) Then
    MsgBox "QuotaDock requires PowerShell 7+ (pwsh.exe). Please install PowerShell 7 first.", vbExclamation, "QuotaDock"
    WScript.Quit 1
End If
cmd = Chr(34) & powershell & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & launcher & """ -Provider opencode"
sh.Run cmd, 0, False
