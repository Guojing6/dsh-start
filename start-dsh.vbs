' Double-click to start DSH Web in the system tray.
Option Explicit
Dim shell, fso, folder, exe
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
exe = folder & "\dsh-start.exe"
shell.Run Chr(34) & exe & Chr(34), 0, False
