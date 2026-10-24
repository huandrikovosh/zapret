' Невидимый launcher для switchVPNzapret.ps1.
' Запускает PowerShell с WindowStyle Hidden так, что никакое окно не мелькает
' (powershell.exe -WindowStyle Hidden сам по себе на долю секунды показывает окно,
'  WScript.Shell .Run с intWindowStyle=0 решает это полностью).
Option Explicit

Dim shell, fso, here, ps1, cmd, batPath

' ============================ НАСТРОЙКА ============================
' Путь к нужному конфигу zapret (general (ALT12).bat).
' ОСТАВЬТЕ ПУСТЫМ (""), если zapret лежит рядом со скриптом или в C:\zapret\ —
' тогда ps1 найдёт батник сам. Иначе впишите полный путь, например:
'   batPath = "C:\zapret\general (ALT12).bat"
batPath = ""
' ==================================================================

Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = here & "\switchVPNzapret.ps1"

If Not fso.FileExists(ps1) Then
    ' Молча выходим, чтобы автозагрузка не ругалась.
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
If Len(batPath) > 0 Then
    cmd = cmd & " -GeneralBat """ & batPath & """"
End If

' intWindowStyle = 0 (hidden), bWaitOnReturn = False
shell.Run cmd, 0, False
