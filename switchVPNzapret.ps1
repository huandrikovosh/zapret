<#
.SYNOPSIS
  Пока запущен Happ (VPN) — гасит zapret (winws.exe), чтобы Happ не ругался
  на «Conflicting Software». Как только Happ закрыт — снова поднимает zapret
  через нужный конфиг general (ALT12).bat, НЕВИДИМО (без висящего окна cmd).

.DESCRIPTION
  Триггер — ПРОЦЕСС happ.exe (именно его видит Happ и из-за него показывает табличку),
  а не сетевые адаптеры. Работает событийно через WMI (Win32_Process start/stop)
  + страховочный таймер. Запускается скрыто, окон не создаёт.

  Запуск zapret идёт ТОЛЬКО через general (ALT12).bat (в нём правильный конфиг winws.exe),
  но батник вызывается невидимо — окно командной строки не появляется, а сам процесс
  winws.exe остаётся виден в диспетчере.

  Логи — в %ProgramData%\zapret-vpn-switch\vpn-zapret.log
  Запускать нужно от Admin/SYSTEM (управление процессами). Планировщик
  (install_autostart.bat) всё это делает за вас.

.PARAMETER TestOnce
  Один проход (детект + действие + выход). Удобно для отладки из консоли.

.PARAMETER GeneralBat
  Явный путь к нужному general*.bat (по умолчанию ищется "general (ALT12).bat"
  рядом со скриптом и в стандартных местах).

.NOTES
  Repo: switchVPNzapret   |   zapret: Flowseal/zapret-discord-youtube
#>

[CmdletBinding()]
param(
    [switch]$TestOnce,
    [string]$GeneralBat
)

$ErrorActionPreference = 'Stop'

# ---------------------- НАСТРОЙКИ ----------------------
# Имена процессов VPN, при которых zapret нужно гасить (без .exe, как видит Get-Process).
# Happ — основной. Можно дописать свои, если пользуетесь ещё чем-то.
$VpnProcessNames = @(
    'happ',            # Happ
    'Happ'
)

# Имя файла нужного конфига zapret. ИМЕННО через него должен стартовать winws.exe.
$GeneralBatName = 'general (ALT12).bat'

# Fallback-пути поиска general (ALT12).bat (если не найдём рядом со скриптом).
# Поправьте под себя при необходимости.
$GeneralBatFallbacks = @(
    'C:\zapret\general (ALT12).bat',
    'C:\Tools\zapret\general (ALT12).bat'
)

# Имя службы zapret (на случай, если zapret всё же установлен как служба —
# тогда её тоже останавливаем, чтобы она не перезапускала winws.exe).
$ServiceName = 'zapret'

$LogDir  = Join-Path $env:ProgramData 'zapret-vpn-switch'
$LogFile = Join-Path $LogDir 'vpn-zapret.log'
$MaxLogBytes = 512KB
# ------------------------------------------------------

# --- Один экземпляр через глобальный mutex ---
$mutexName = 'Global\SwitchVpnZapret_Singleton_v3'
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    # Уже запущено — молча выходим.
    exit 0
}

# --- Логи ---
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
function global:Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt $MaxLogBytes)) {
            $old = "$LogFile.1"
            if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
            Rename-Item $LogFile $old -Force -ErrorAction SilentlyContinue
        }
        "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) [$Level] $Message" |
            Out-File -FilePath $LogFile -Append -Encoding UTF8
    } catch { }
}

# --- Admin ---
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Нет прав администратора. Задача планировщика должна запускать скрипт от SYSTEM." 'ERROR'
    exit 1
}

# --- Определяем путь к general (ALT12).bat один раз ---
$scriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$global:ZapretBatPath = $null
$batCandidates = @()
if ($GeneralBat) { $batCandidates += $GeneralBat }
$batCandidates += (Join-Path $scriptDir $GeneralBatName)
$batCandidates += (Join-Path $scriptDir ("zapret\" + $GeneralBatName))
$batCandidates += $GeneralBatFallbacks
foreach ($c in $batCandidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { $global:ZapretBatPath = (Resolve-Path -LiteralPath $c).Path; break }
}

Write-Log "=== switchVPNzapret запущен (PID $PID, user=$([Environment]::UserName)) ==="
if ($global:ZapretBatPath) {
    Write-Log "Конфиг zapret: $($global:ZapretBatPath)"
} else {
    Write-Log "НЕ найден '$GeneralBatName'. Задайте путь через -GeneralBat или поправьте \$GeneralBatFallbacks." 'ERROR'
}

# ======================================================
# Основные функции
# ======================================================

function global:Test-HappRunning {
    # Главный триггер: запущен ли процесс Happ.
    foreach ($n in $VpnProcessNames) {
        if (@(Get-Process -Name $n -ErrorAction SilentlyContinue).Count -gt 0) {
            return $true
        }
    }
    return $false
}

function global:Get-WinwsProcesses {
    return @(Get-Process -Name winws -ErrorAction SilentlyContinue)
}

function global:Kill-Winws {
    <#
      Надёжно убивает winws.exe.
      winws.exe, запущенный через start /min из батника, — обычный процесс.
      Добиваем деревом (/T) + .NET Kill(), с повторами и контрольной проверкой.
    #>
    $killed = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $procs = Get-WinwsProcesses
        if ($procs.Count -eq 0) { return $true }

        foreach ($p in $procs) {
            try { $null = & taskkill.exe /PID $p.Id /T /F 2>&1 } catch { }
        }
        Start-Sleep -Milliseconds 400

        foreach ($p in (Get-WinwsProcesses)) {
            try { $p.Kill() } catch { }
        }
        Start-Sleep -Milliseconds 300

        if ((Get-WinwsProcesses).Count -eq 0) { $killed = $true; break }
        Write-Log "winws.exe ещё жив после попытки $attempt — повторяю." 'WARN'
    }

    if (-not $killed -and (Get-WinwsProcesses).Count -gt 0) {
        Write-Log "НЕ удалось убить winws.exe после 5 попыток." 'ERROR'
    }
    return $killed
}

function global:Stop-Zapret {
    # 1) Если zapret установлен службой — останавливаем её, иначе она перезапустит winws.
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        try {
            $null = & sc.exe stop $ServiceName 2>&1
            for ($i = 0; $i -lt 5; $i++) {
                try { $svc.Refresh() } catch { }
                if ($svc.Status -eq 'Stopped') { break }
                Start-Sleep -Milliseconds 500
            }
        } catch {
            Write-Log "sc stop ${ServiceName} упал: $($_.Exception.Message)" 'WARN'
        }
    }

    # 2) Главное — принудительно добить winws.exe (из-за него Happ ругается).
    Kill-Winws | Out-Null

    if ((Get-WinwsProcesses).Count -eq 0) {
        Write-Log "Happ запущен → zapret остановлен, winws.exe убит."
    } else {
        Write-Log "Happ запущен → winws.exe всё ещё в памяти!" 'ERROR'
    }
}

function global:Start-Zapret {
    # Если уже крутится — ничего не делаем.
    if ((Get-WinwsProcesses).Count -gt 0) {
        Write-Log "winws уже работает — пропускаю старт." 'DEBUG'
        return
    }

    if (-not $global:ZapretBatPath) {
        Write-Log "Путь к '$GeneralBatName' не задан — zapret не запустить. Укажите -GeneralBat." 'ERROR'
        return
    }
    if (-not (Test-Path -LiteralPath $global:ZapretBatPath)) {
        Write-Log "Файл '$($global:ZapretBatPath)' исчез — zapret не запустить." 'ERROR'
        return
    }

    # Запуск ТОЛЬКО через general (ALT12).bat, НЕВИДИМО:
    #   cmd /c "<bat>"  с WindowStyle=Hidden + CreateNoWindow — окно cmd не появляется,
    #   батник отрабатывает (start /min winws.exe) и завершается, а winws.exe остаётся виден.
    #   NO_UPDATE_CHECK=1 — чтобы при автозапуске батник не лез в сеть за апдейтами.
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $env:ComSpec                                  # cmd.exe
        $psi.Arguments = "/c `"`"$($global:ZapretBatPath)`"`""        # /c "C:\...\general (ALT12).bat"
        $psi.WorkingDirectory = Split-Path -Parent $global:ZapretBatPath
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $psi.EnvironmentVariables['NO_UPDATE_CHECK'] = '1'
        [void][System.Diagnostics.Process]::Start($psi)

        # Ждём до ~6 сек реального появления winws.exe (батник подгружает списки и т.п.).
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Milliseconds 500
            if ((Get-WinwsProcesses).Count -gt 0) {
                Write-Log "Happ закрыт → zapret запущен через '$(Split-Path -Leaf $global:ZapretBatPath)' (winws.exe виден)."
                return
            }
        }
        Write-Log "Батник отработал, но winws.exe не появился за 6 сек. Проверьте конфиг/пути zapret." 'WARN'
    } catch {
        Write-Log "Запуск '$($global:ZapretBatPath)' упал: $($_.Exception.Message)" 'ERROR'
    }
}

# --- Сериализация Sync-State: защита от гонки WMI-событие vs таймер ---
# Лок обязан быть ГЛОБАЛЬНЫМ — Action-блоки событий выполняются в отдельном scope,
# где переменные уровня $script: не видны.
$global:SwitchVpnSyncLock = [ref]0

function global:Sync-State {
    if ([System.Threading.Interlocked]::CompareExchange($global:SwitchVpnSyncLock, 1, 0) -ne 0) {
        return
    }
    try {
        $happUp       = Test-HappRunning
        $winwsRunning = ((Get-WinwsProcesses).Count -gt 0)

        if ($happUp -and $winwsRunning) {
            # Happ работает, zapret мешает → гасим zapret.
            Stop-Zapret
        } elseif ($happUp -and -not $winwsRunning) {
            # Happ работает, winws нет — но служба могла остаться и перезапустит winws.
            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Stopped') {
                Write-Log "Happ запущен, winws нет, но служба в статусе $($svc.Status) — останавливаю." 'DEBUG'
                Stop-Zapret
            }
        } elseif (-not $happUp -and -not $winwsRunning) {
            # Happ закрыт, zapret не работает → поднимаем zapret.
            Start-Zapret
        }
        # Иначе (Happ закрыт + winws работает) — корректное состояние, ничего не делаем.
    }
    finally {
        [System.Threading.Interlocked]::Exchange($global:SwitchVpnSyncLock, 0) | Out-Null
    }
}

# ======================================================
# Режим одного прохода (для отладки)
# ======================================================
if ($TestOnce) {
    Sync-State
    $happ  = Test-HappRunning
    $winws = ((Get-WinwsProcesses).Count -gt 0)
    Write-Log "TestOnce завершён. Happ=$happ  winws=$winws"
    Write-Host "TestOnce: Happ=$happ  winws=$winws  (подробности в $LogFile)"
    if ($mutex) { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
    exit 0
}

# ======================================================
# Основной цикл: события запуска/останова процесса happ.exe + таймер
# ======================================================

# Прийти в консистентное состояние сразу.
Sync-State

$wmiRegistered = $false

# Событие СТАРТА процесса Happ → погасить zapret.
try {
    $startQuery = @"
SELECT * FROM __InstanceCreationEvent WITHIN 2
WHERE TargetInstance ISA 'Win32_Process'
  AND (TargetInstance.Name = 'happ.exe' OR TargetInstance.Name = 'Happ.exe')
"@
    Register-CimIndicationEvent -Namespace 'root/cimv2' -Query $startQuery `
        -SourceIdentifier 'HappStart' -Action {
            try { Start-Sleep -Milliseconds 500; Sync-State } catch { }
        } | Out-Null

    # Событие ОСТАНОВА процесса Happ → поднять zapret.
    $stopQuery = @"
SELECT * FROM __InstanceDeletionEvent WITHIN 2
WHERE TargetInstance ISA 'Win32_Process'
  AND (TargetInstance.Name = 'happ.exe' OR TargetInstance.Name = 'Happ.exe')
"@
    Register-CimIndicationEvent -Namespace 'root/cimv2' -Query $stopQuery `
        -SourceIdentifier 'HappStop' -Action {
            try { Start-Sleep -Milliseconds 800; Sync-State } catch { }
        } | Out-Null

    $wmiRegistered = $true
    Write-Log "Подписка на старт/останов процесса happ.exe оформлена."
} catch {
    Write-Log "Не удалось подписаться на события процессов: $($_.Exception.Message). Останется только таймер." 'WARN'
}

# Страховочный таймер. Если WMI не поднялся — опрашиваем чаще.
$tickMs = if ($wmiRegistered) { 10000 } else { 3000 }
try {
    $timer = New-Object System.Timers.Timer
    $timer.Interval  = $tickMs
    $timer.AutoReset = $true
    Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier 'VpnSafetyTick' -Action {
        try { Sync-State } catch { }
    } | Out-Null
    $timer.Start()
    Write-Log "Страховочный таймер запущен (интервал $tickMs мс)."
} catch {
    Write-Log "Не удалось запустить таймер-страховку: $($_.Exception.Message)" 'WARN'
}

# «Вечный» сон — события выполняются в фоне.
try {
    while ($true) { Start-Sleep -Seconds 3600 }
} finally {
    if ($timer) { try { $timer.Stop(); $timer.Dispose() } catch { } }
    Unregister-Event -SourceIdentifier 'HappStart'    -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier 'HappStop'     -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier 'VpnSafetyTick' -ErrorAction SilentlyContinue
    if ($mutex) { try { $mutex.ReleaseMutex() | Out-Null } catch { }; $mutex.Dispose() }
    Write-Log "=== switchVPNzapret завершён ==="
}
