@echo off
chcp 65001 >nul

net session >nul 2>&1
if errorlevel 1 (
    echo [!] Нужны права администратора.
    pause
    exit /b 1
)

set "TASK=SwitchVPNZapret"

echo [*] Останавливаю задачу, если работает...
schtasks /End /TN "%TASK%" >nul 2>&1

echo [*] Удаляю задачу "%TASK%"...
schtasks /Delete /TN "%TASK%" /F
if errorlevel 1 (
    echo [!] Не удалось удалить задачу (возможно, её и не было).
) else (
    echo [OK] Задача удалена.
)

echo [*] Добиваю PowerShell-процессы со switchVPNzapret.ps1, если висят...
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*switchVPNzapret.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1

echo.
pause
