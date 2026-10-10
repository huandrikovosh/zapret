<#
.SYNOPSIS
  Автоматически гасит сервис zapret, когда поднимается VPN (Happ/FlClashX/любой TUN-адаптер),
  и так же тихо запускает его обратно, когда VPN отключается.

.DESCRIPTION
  Работает событийно через WMI (MSFT_NetAdapter) + страховочный таймер.
  Запускается скрыто, окон не создаёт. Логи — в %ProgramData%\zapret-vpn-switch\vpn-zapret.log
  Запускать нужно от SYSTEM или Admin (управление сервисами). Планировщик (install_autostart.bat)
  всё это делает за вас.

.PARAMETER TestOnce
  Один проход (детект + действие + выход). Удобно для отладки из консоли.

.NOTES
  Repo: switchVPNzapret   |   zapret: Flowseal/zapret-discord-youtube
#>

[CmdletBinding()]
param(
    [switch]$TestOnce
)

$ErrorActionPreference = 'Stop'

# ---------------------- НАСТРОЙКИ ----------------------
# Имена/описания VPN-адаптеров (поддерживаются wildcard-маски).
# Проверить своё можно так (при включённом VPN):
#   Get-NetAdapter -IncludeHidden | Format-Table Name, InterfaceDescription, Status
$VpnAdapterPatterns = @(
    'Happ*',           # Happ TUN
    '*Happ*',          # на всякий — если имя смешанное
    'FlClashX*',       # FlClashX TUN
    '*FlClash*',
    'wintun*',         # универсальный wintun (WireGuard, Mullvad и т.п.)
    '*wintun*',
    'TAP-Windows*',    # OpenVPN TAP
    'OpenVPN*',
    'WireGuard*',
    '*WireGuard*'
)

$ServiceName = 'zapret'
# Fallback-путь к general.bat на случай, если сервис zapret удалён.
# Можете поправить под себя или оставить как есть — скрипт сам поищет рядом с собой.
$GeneralBatFallback = 'E:\11111111111111111111111\general.bat'

$LogDir  = Join-Path $env:ProgramData 'zapret-vpn-switch'
$LogFile = Join-Path $LogDir 'vpn-zapret.log'
$MaxLogBytes = 512KB
# ------------------------------------------------------

# --- Один экземпляр через глобальный mutex ---
$mutexName = 'Global\SwitchVpnZapret_Singleton_v2'
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

Write-Log "=== switchVPNzapret запущен (PID $PID, user=$([Environment]::UserName)) ==="

# ======================================================
# Основные функции
# ======================================================

function global:Test-VpnUp {
    # ВАЖНО: TUN-адаптеры Happ/wintun часто помечены как Hidden и БЕЗ -IncludeHidden
    # Get-NetAdapter их не показывает → VPN не детектится. Поэтому всегда -IncludeHidden.
    $up = $null
    try {
        $up = Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
    } catch {
        # На случай старых систем / отсутствия модуля — fallback через WMI.
        try {
            $up = Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetAdapter -ErrorAction Stop |
                  Where-Object { $_.MediaConnectState -eq 1 -or $_.InterfaceOperationalStatus -eq 1 }
        } catch {
            Write-Log "Не удалось получить список адаптеров: $($_.Exception.Message)" 'WARN'
            return $false
        }
    }
    if (-not $up) { return $false }

    foreach ($p in $VpnAdapterPatterns) {
        foreach ($a in $up) {
            # У MSFT_NetAdapter свойство называется Name/InterfaceDescription — оба проверяем.
            $name = $a.Name
            $desc = $a.InterfaceDescription
            if (($name -and ($name -like $p)) -or ($desc -and ($desc -like $p))) {
                Write-Log "Обнаружен VPN-адаптер: '$name' / '$desc' (по маске '$p')." 'DEBUG'
                return $true
            }
        }
    }
    return $false
}

function global:Get-WinwsProcesses {
    # Централизованно: получить все процессы winws (может быть несколько).
    return @(Get-Process -Name winws -ErrorAction SilentlyContinue)
}

function global:Kill-Winws {
    <#
      Надёжно убивает winws.exe.
      Главная причина, по которой "winws.exe продолжает висеть":
      winws.exe запущен службой zapret, но сам НЕ является корректной службой —
      он не обрабатывает SERVICE_CONTROL_STOP, поэтому `sc stop zapret` вешает
      службу в STOP_PENDING, а процесс не умирает. Добиваем принудительно,
      с деревом процессов (/T) и повторами.
    #>
    $killed = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $procs = Get-WinwsProcesses
        if ($procs.Count -eq 0) {
            return $true  # уже мёртв
        }

        foreach ($p in $procs) {
            # 1) taskkill /T /F — убивает процесс ВМЕСТЕ с деревом дочерних.
            try {
                $null = & taskkill.exe /PID $p.Id /T /F 2>&1
            } catch { }
        }

        Start-Sleep -Milliseconds 400

        # 2) Если что-то ещё живо — добиваем через .NET Kill() по PID.
        foreach ($p in (Get-WinwsProcesses)) {
            try {
                $p.Kill()
            } catch { }
        }

        Start-Sleep -Milliseconds 300

        if ((Get-WinwsProcesses).Count -eq 0) {
            $killed = $true
            break
        }
        Write-Log "winws.exe ещё жив после попытки $attempt — повторяю." 'WARN'
    }

    if (-not $killed -and (Get-WinwsProcesses).Count -gt 0) {
        Write-Log "НЕ удалось убить winws.exe после 5 попыток." 'ERROR'
    }
    return $killed
}

function global:Stop-Zapret {
    # 1) Останавливаем службу через sc.exe (неблокирующе — не ждём Stopped бесконечно,
    #    т.к. winws как служба часто виснет в STOP_PENDING).
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        try {
            $null = & sc.exe stop $ServiceName 2>&1
            # Короткое ожидание — максимум 2.5 сек. Не зацикливаемся на StopPending.
            for ($i = 0; $i -lt 5; $i++) {
                try { $svc.Refresh() } catch { }
                if ($svc.Status -eq 'Stopped') { break }
                Start-Sleep -Milliseconds 500
            }
        } catch {
            Write-Log "sc stop ${ServiceName} упал: $($_.Exception.Message)" 'WARN'
        }
    }

    # 2) ГЛАВНОЕ: принудительно добиваем winws.exe (с деревом процессов и повторами).
    #    Именно этот шаг чинит баг "winws.exe продолжает висеть".
    Kill-Winws | Out-Null

    # 3) Контрольная проверка.
    if ((Get-WinwsProcesses).Count -eq 0) {
        Write-Log "VPN поднят → zapret остановлен, winws.exe убит."
    } else {
        Write-Log "VPN поднят → sc stop выполнен, но winws.exe всё ещё в памяти!" 'ERROR'
    }
}

function global:Start-Zapret {
    # Если уже крутится — ничего не делаем.
    if ((Get-WinwsProcesses).Count -gt 0) {
        Write-Log "winws уже работает — пропускаю старт." 'DEBUG'
        return
    }

    # 1) Пробуем поднять службу (основной путь — она должна быть установлена через service.bat).
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        try {
            $null = & sc.exe start $ServiceName 2>&1
            # Ждём до ~4 сек появления winws.exe (служба стартует процесс асинхронно).
            for ($i = 0; $i -lt 8; $i++) {
                Start-Sleep -Milliseconds 500
                if ((Get-WinwsProcesses).Count -gt 0) {
                    Write-Log "VPN отключён → zapret запущен (service)."
                    return
                }
                try { $svc.Refresh() } catch { }
            }
            Write-Log "sc start ${ServiceName}: winws.exe не появился за 4 сек (статус $($svc.Status)). Пробую fallback." 'WARN'
        } catch {
            Write-Log "sc start ${ServiceName} упал: $($_.Exception.Message)" 'WARN'
        }
    } else {
        Write-Log "Служба $ServiceName не установлена. Пробую fallback через general.bat." 'WARN'
    }

    # 2) Fallback — ищем general.bat рядом со скриптом, в стандартных местах, иначе — $GeneralBatFallback.
    $scriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $PSScriptRoot }
    $candidates = @(
        (Join-Path $scriptDir 'general.bat'),
        (Join-Path $scriptDir 'zapret\general.bat'),
        $GeneralBatFallback
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($candidates.Count -eq 0) {
        Write-Log "general.bat не найден — zapret не запустится. Проверьте пути в скрипте." 'ERROR'
        return
    }

    $bat = $candidates[0]
    try {
        # cmd /c start "" /b — консоль не открывается, окно скрыто, процесс отвязан.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $env:ComSpec
        $psi.Arguments = "/c start `"zapret`" /b /min `"$bat`""
        $psi.WorkingDirectory = Split-Path -Parent $bat
        $psi.WindowStyle = 'Hidden'
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        [void][System.Diagnostics.Process]::Start($psi)
        Write-Log "VPN отключён → zapret запущен (fallback bat: $bat)."
    } catch {
        Write-Log "Fallback-запуск general.bat упал: $($_.Exception.Message)" 'ERROR'
    }
}

# --- Сериализация Sync-State: защита от гонки WMI-событие vs таймер ---
# Оба источника могут дёрнуть Sync-State одновременно → два sc stop/start подряд.
# Простой флаг + Interlocked гарантирует, что одновременно работает только один проход.
# ВАЖНО: лок обязан быть ГЛОБАЛЬНЫМ — Action-блоки событий (WMI/таймер) выполняются
# в отдельном контексте, где переменные уровня $script: НЕ видны (проверено).
# С $script: лок был бы $null и CompareExchange упал бы с ошибкой.
$global:SwitchVpnSyncLock = [ref]0

function global:Sync-State {
    # Если уже идёт проход — выходим (другой поток доделает актуальное состояние).
    if ([System.Threading.Interlocked]::CompareExchange($global:SwitchVpnSyncLock, 1, 0) -ne 0) {
        return
    }
    try {
        # Главная «петля»: сравнить желаемое состояние с текущим.
        $vpnUp = Test-VpnUp
        $winwsRunning = ((Get-WinwsProcesses).Count -gt 0)

        if ($vpnUp -and $winwsRunning) {
            Stop-Zapret
        } elseif ($vpnUp -and -not $winwsRunning) {
            # VPN поднят, winws не бежит — но служба zapret могла остаться в auto и
            # способна перезапустить процесс. На всякий случай убеждаемся, что служба стоит.
            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Stopped') {
                Write-Log "VPN поднят, winws не бежит, но служба в статусе $($svc.Status) — останавливаю." 'DEBUG'
                Stop-Zapret
            }
        } elseif (-not $vpnUp -and -not $winwsRunning) {
            Start-Zapret
        }
        # Иначе (VPN down + winws running) — корректное рабочее состояние, ничего не делаем.
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
    $vpn = Test-VpnUp
    $winws = ((Get-WinwsProcesses).Count -gt 0)
    Write-Log "TestOnce завершён. VPN=$vpn  winws=$winws"
    Write-Host "TestOnce: VPN=$vpn  winws=$winws  (подробности в $LogFile)"
    if ($mutex) { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
    exit 0
}

# ======================================================
# Основной цикл: событие WMI + страховочный таймер
# ======================================================

# Выполнить один раз сразу, чтобы прийти в консистентное состояние.
Sync-State

# Подписываемся на изменения сетевых адаптеров (событие приходит мгновенно).
# ПРИМЕЧАНИЕ: PreviousInstance в __InstanceModificationEvent для MSFT_NetAdapter
# в namespace root/StandardCimv2 поддерживается не на всех системах и ломает запрос.
# Поэтому ловим ЛЮБУЮ модификацию адаптера, а решение принимает Sync-State (идемпотентно).
$query = @"
SELECT * FROM __InstanceModificationEvent WITHIN 2
WHERE TargetInstance ISA 'MSFT_NetAdapter'
"@

$wmiRegistered = $false
try {
    Register-CimIndicationEvent -Namespace 'root/StandardCimv2' -Query $query `
        -SourceIdentifier 'VpnAdapterChange' -Action {
            try {
                # дадим Windows секунду, чтобы адаптер окончательно встал в Up/Down
                Start-Sleep -Milliseconds 1500
                Sync-State
            } catch { }
        } | Out-Null
    $wmiRegistered = $true
    Write-Log "Подписка на WMI MSFT_NetAdapter оформлена."
} catch {
    Write-Log "Не удалось подписаться на WMI (StandardCimv2): $($_.Exception.Message). Пробую root/cimv2." 'WARN'
    # Fallback на классический Win32_NetworkAdapter (есть на всех системах).
    try {
        $query2 = @"
SELECT * FROM __InstanceModificationEvent WITHIN 2
WHERE TargetInstance ISA 'Win32_NetworkAdapter'
"@
        Register-CimIndicationEvent -Namespace 'root/cimv2' -Query $query2 `
            -SourceIdentifier 'VpnAdapterChange' -Action {
                try {
                    Start-Sleep -Milliseconds 1500
                    Sync-State
                } catch { }
            } | Out-Null
        $wmiRegistered = $true
        Write-Log "Подписка на WMI Win32_NetworkAdapter (root/cimv2) оформлена."
    } catch {
        Write-Log "Не удалось подписаться и на root/cimv2: $($_.Exception.Message). Останется только таймер." 'WARN'
    }
}

# Страховочный таймер — раз в 15 секунд перепроверяем состояние (на случай пропущенных событий).
# Если WMI не поднялся — ускоряем опрос до 3 секунд, чтобы остаться отзывчивыми.
$tickMs = if ($wmiRegistered) { 15000 } else { 3000 }
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

# «Вечный» сон до сигнала завершения — события выполняются в фоне.
try {
    while ($true) { Start-Sleep -Seconds 3600 }
} finally {
    if ($timer) { try { $timer.Stop(); $timer.Dispose() } catch { } }
    Unregister-Event -SourceIdentifier 'VpnAdapterChange' -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier 'VpnSafetyTick'   -ErrorAction SilentlyContinue
    if ($mutex) { try { $mutex.ReleaseMutex() | Out-Null } catch { }; $mutex.Dispose() }
    Write-Log "=== switchVPNzapret завершён ==="
}
