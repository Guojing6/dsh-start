' Double-click to start DSH Web in the system tray (no console window).
' Keeps dsh-tray.ps1 (same folder) running hidden in the background.
Option Explicit
Dim shell, fso, folder, ps1, cmd
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = folder & "\dsh-tray.ps1"
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File " & Chr(34) & ps1 & Chr(34)
shell.Run cmd, 0, False
