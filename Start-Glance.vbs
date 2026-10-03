' Launches Glance.ps1 with no console window. Used by the "Start with Windows" shortcut.
Dim sh, fso, dir, ps1
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(dir, "Glance.ps1")
sh.Run "powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & ps1 & """", 0, False
