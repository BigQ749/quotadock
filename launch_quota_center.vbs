Option Explicit

Dim shell, fso, root, scriptPath, powershell
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(root, "quota_center.ps1")
powershell = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If Not fso.FileExists(powershell) Then
    powershell = shell.ExpandEnvironmentStrings("%ProgramFiles(x86)%") & "\PowerShell\7\pwsh.exe"
End If
If Not fso.FileExists(powershell) Then
    MsgBox "QuotaDock requires PowerShell 7+ (pwsh.exe). Please install PowerShell 7 first.", vbExclamation, "QuotaDock"
    WScript.Quit 1
End If

shell.CurrentDirectory = root
shell.Run Chr(34) & powershell & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & scriptPath & Chr(34), 0, False
