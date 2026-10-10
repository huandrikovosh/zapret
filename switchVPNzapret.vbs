' Невидимый launcher для switchVPNzapret.ps1.
' Запускает PowerShell с WindowStyle Hidden так, что никакое окно не мелькает
' (powershell.exe -WindowStyle Hidden сам по себе на долю секунды показывает окно,
'  WScript.Shell .Run с intWindowStyle=0 решает это полностью).
Option Explicit

Dim shell, fso, here, ps1
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = here & "\switchVPNzapret.ps1"

If Not fso.FileExists(ps1) Then
    ' Молча выходим, чтобы автозагрузка не ругалась.
    WScript.Quit 1
End If

' intWindowStyle = 0 (hidden), bWaitOnReturn = False
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
