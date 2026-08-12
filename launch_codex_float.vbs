Option Explicit
Dim sh, fso, dir, launcher, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
launcher = dir & "\launch_quota_small_widget.ps1"
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & launcher & """ -Provider codex"
sh.Run cmd, 0, False
