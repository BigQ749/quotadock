Option Explicit
Dim sh, fso, dir, launcher, cmd, powershell
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
launcher = dir & "\launch_quota_small_widget.ps1"
Dim found
found = False
powershell = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If fso.FileExists(powershell) Then found = True
If Not found Then
    powershell = sh.ExpandEnvironmentStrings("%ProgramFiles(x86)%") & "\PowerShell\7\pwsh.exe"
    If fso.FileExists(powershell) Then found = True
End If
If Not found Then
    ' MSIX PowerShell registers the real package path under App Paths.
    On Error Resume Next
    powershell = sh.RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe\")
    On Error GoTo 0
    If fso.FileExists(powershell) Then found = True
End If
If Not found Then
    ' where.exe prints only paths that exist; the alias may fail FileExists.
    Dim exec, line
    Set exec = sh.Exec("where.exe pwsh.exe")
    Do While Not exec.StdOut.AtEndOfStream
        line = Trim(exec.StdOut.ReadLine())
        If Len(line) > 0 Then
            powershell = line
            found = True
            Exit Do
        End If
    Loop
    Set exec = Nothing
End If
If Not found Then
    MsgBox "QuotaDock requires PowerShell 7+ (pwsh.exe). Please install PowerShell 7 first.", vbExclamation, "QuotaDock"
    WScript.Quit 1
End If
cmd = Chr(34) & powershell & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & launcher & """ -Provider codex"
sh.Run cmd, 0, False
