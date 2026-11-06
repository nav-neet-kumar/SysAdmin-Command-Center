' Starts the Command Center helper with no window. Takes no arguments on purpose
' (the occstart: link passes none to it), so nothing from a web page can influence what runs.
Dim fso, sh, dir
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -WindowStyle Hidden -File """ & dir & "\helper.ps1""", 0, False
