@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul

REM =====================================================================
REM  Установщик автозагрузки для switchVPNzapret.
REM  Создаёт задачу планировщика "SwitchVPNZapret", которая:
REM    - стартует при включении компьютера (ONSTART, до входа пользователя);
REM    - работает от SYSTEM (нужны права для sc.exe start/stop);
REM    - запускается через .vbs → PowerShell строка НЕ появляется вообще;
REM    - перезапускается автоматически при падении;
REM    - не имеет лимита по времени работы.
REM
REM  Запускать от администратора (ПКМ → Запуск от имени администратора).
REM =====================================================================

REM --- Проверка прав ---
net session >nul 2>&1
if errorlevel 1 (
    echo [!] Нужны права администратора. ПКМ -> Запуск от имени администратора.
    pause
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
set "VBS=%SCRIPT_DIR%switchVPNzapret.vbs"
set "PS1=%SCRIPT_DIR%switchVPNzapret.ps1"
set "TASK=SwitchVPNZapret"
set "XML=%TEMP%\%TASK%.xml"

if not exist "%VBS%" (
    echo [!] Не найден %VBS%
    pause
    exit /b 1
)
if not exist "%PS1%" (
    echo [!] Не найден %PS1%
    pause
    exit /b 1
)

echo [*] Удаляю старую задачу, если есть...
schtasks /Delete /TN "%TASK%" /F >nul 2>&1

echo [*] Создаю XML задачи...

REM Для триггера OnStart принципал SYSTEM. Hidden=true убирает любые всплывающие окна.
REM encoding=UTF-8: файл пишется echo под chcp 65001; раньше стояло UTF-16 при
REM UTF-8 содержимом -> schtasks мог падать/кривить парсинг.
REM Порядок элементов внутри Settings строго задан XSD-схемой Task Scheduler:
REM AllowStartOnDemand -> RestartOnFailure -> MultipleInstancesPolicy -> ... ->
REM IdleSettings -> ExecutionTimeLimit -> Enabled -> Hidden -> RunOnlyIfIdle ->
REM WakeToRun -> Priority. Нарушение порядка -> schtasks /Create /XML падает.
> "%XML%" (
    echo ^<?xml version="1.0" encoding="UTF-8"?^>
    echo ^<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"^>
    echo   ^<RegistrationInfo^>
    echo     ^<Description^>Switch zapret off when VPN is up, on when VPN is down.^</Description^>
    echo     ^<URI^>\%TASK%^</URI^>
    echo   ^</RegistrationInfo^>
    echo   ^<Triggers^>
    echo     ^<BootTrigger^>
    echo       ^<Enabled^>true^</Enabled^>
    echo       ^<Delay^>PT10S^</Delay^>
    echo     ^</BootTrigger^>
    echo   ^</Triggers^>
    echo   ^<Principals^>
    echo     ^<Principal id="Author"^>
    echo       ^<UserId^>S-1-5-18^</UserId^>
    echo       ^<RunLevel^>HighestAvailable^</RunLevel^>
    echo     ^</Principal^>
    echo   ^</Principals^>
    echo   ^<Settings^>
    echo     ^<AllowStartOnDemand^>true^</AllowStartOnDemand^>
    echo     ^<RestartOnFailure^>
    echo       ^<Interval^>PT1M^</Interval^>
    echo       ^<Count^>999^</Count^>
    echo     ^</RestartOnFailure^>
    echo     ^<MultipleInstancesPolicy^>IgnoreNew^</MultipleInstancesPolicy^>
    echo     ^<DisallowStartIfOnBatteries^>false^</DisallowStartIfOnBatteries^>
    echo     ^<StopIfGoingOnBatteries^>false^</StopIfGoingOnBatteries^>
    echo     ^<AllowHardTerminate^>true^</AllowHardTerminate^>
    echo     ^<StartWhenAvailable^>true^</StartWhenAvailable^>
    echo     ^<RunOnlyIfNetworkAvailable^>false^</RunOnlyIfNetworkAvailable^>
    echo     ^<IdleSettings^>
    echo       ^<StopOnIdleEnd^>false^</StopOnIdleEnd^>
    echo       ^<RestartOnIdle^>false^</RestartOnIdle^>
    echo     ^</IdleSettings^>
    echo     ^<ExecutionTimeLimit^>PT0S^</ExecutionTimeLimit^>
    echo     ^<Enabled^>true^</Enabled^>
    echo     ^<Hidden^>true^</Hidden^>
    echo     ^<RunOnlyIfIdle^>false^</RunOnlyIfIdle^>
    echo     ^<WakeToRun^>false^</WakeToRun^>
    echo     ^<Priority^>7^</Priority^>
    echo   ^</Settings^>
    echo   ^<Actions Context="Author"^>
    echo     ^<Exec^>
    echo       ^<Command^>wscript.exe^</Command^>
    echo       ^<Arguments^>"%VBS%"^</Arguments^>
    echo       ^<WorkingDirectory^>%SCRIPT_DIR:~0,-1%^</WorkingDirectory^>
    echo     ^</Exec^>
    echo   ^</Actions^>
    echo ^</Task^>
)

echo [*] Регистрирую задачу...
schtasks /Create /TN "%TASK%" /XML "%XML%" /F
if errorlevel 1 (
    echo [!] Не удалось создать задачу.
    del /q "%XML%" >nul 2>&1
    pause
    exit /b 1
)
del /q "%XML%" >nul 2>&1

echo [*] Запускаю задачу прямо сейчас (без перезагрузки)...
schtasks /Run /TN "%TASK%" >nul 2>&1

echo.
echo [OK] Задача "%TASK%" создана и запущена.
echo      Лог: %%ProgramData%%\zapret-vpn-switch\vpn-zapret.log
echo.
echo      Проверить:   schtasks /Query /TN "%TASK%" /V /FO LIST
echo      Удалить:     запустите uninstall_autostart.bat (или schtasks /Delete /TN "%TASK%" /F)
echo.
pause
