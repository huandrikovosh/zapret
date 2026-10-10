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

# ---------------------- НАСТРОЙКИ ----------------------
# Имена/описания VPN-адаптеров (поддерживаются wildcard-маски).
# Проверить своё можно так (при включённом VPN):
#   Get-NetAdapter | Format-Table Name, InterfaceDescription, Status
$VpnAdapterPatterns = @(
    'Happ*',           # Happ TUN
    '*Happ*',          # на всякий — если имя смешанное
    'FlClashX*',       # FlClashX TUN
    'wintun*',         # универсальный wintun (WireGuard, Mullvad и т.п.)
    'TAP-Windows*',    # OpenVPN TAP
    'OpenVPN*',
    'WireGuard*'
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
function Write-Log {
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

function Test-VpnUp {
    try {
        $up = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    } catch {
        # На случай старых систем — fallback через WMI.
        $up = Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetAdapter -ErrorAction SilentlyContinue |
              Where-Object { $_.MediaConnectState -eq 1 }
    }
    if (-not $up) { return $false }

    foreach ($p in $VpnAdapterPatterns) {
        if ($up | Where-Object { $_.Name -like $p -or $_.InterfaceDescription -like $p }) {
            return $true
        }
    }
    return $false
}

function Stop-Zapret {
    # 1) Останавливаем службу через sc.exe (быстрее и тише Stop-Service).
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        try {
            $null = & sc.exe stop $ServiceName 2>&1
            # ждём максимум 5 секунд
            for ($i = 0; $i -lt 10; $i++) {
                $svc.Refresh()
                if ($svc.Status -eq 'Stopped') { break }
                Start-Sleep -Milliseconds 500
            }
        } catch {
            Write-Log "sc stop ${ServiceName} упал: $($_.Exception.Message)" 'WARN'
        }
    }

    # 2) Добиваем winws.exe — на случай, если zapret запускался standalone-батником.
    Get-Process -Name winws -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { }
    }

    Write-Log "VPN поднят → zapret остановлен."
}

function Start-Zapret {
    # Если уже крутится — ничего не делаем.
    if (Get-Process -Name winws -ErrorAction SilentlyContinue) {
        Write-Log "winws уже работает — пропускаю старт." 'DEBUG'
        return
    }

    # 1) Пробуем поднять службу (основной путь — она должна быть установлена через service.bat).
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        try {
            $null = & sc.exe start $ServiceName 2>&1
            Start-Sleep -Milliseconds 800
            $svc.Refresh()
            if ($svc.Status -eq 'Running' -or $svc.Status -eq 'StartPending') {
                Write-Log "VPN отключён → zapret запущен (service)."
                return
            }
            Write-Log "sc start ${ServiceName} вернул статус $($svc.Status)." 'WARN'
        } catch {
            Write-Log "sc start ${ServiceName} упал: $($_.Exception.Message)" 'WARN'
        }
    } else {
        Write-Log "Служба $ServiceName не установлена. Пробую fallback через general.bat." 'WARN'
    }

    # 2) Fallback — ищем general.bat рядом со скриптом, в стандартных местах, иначе — $GeneralBatFallback.
    $candidates = @(
        (Join-Path (Split-Path -Parent $PSCommandPath) 'general.bat'),
        (Join-Path (Split-Path -Parent $PSCommandPath) 'zapret\general.bat'),
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

function Sync-State {
    # Главная «петля»: сравнить желаемое состояние с текущим.
    $vpnUp = Test-VpnUp
    $winwsRunning = [bool](Get-Process -Name winws -ErrorAction SilentlyContinue)

    if ($vpnUp -and $winwsRunning) {
        Stop-Zapret
    } elseif (-not $vpnUp -and -not $winwsRunning) {
        Start-Zapret
    }
    # Иначе — уже в нужном состоянии, ничего не делаем.
}

# ======================================================
# Режим одного прохода (для отладки)
# ======================================================
if ($TestOnce) {
    Sync-State
    Write-Log "TestOnce завершён. VPN=$(Test-VpnUp)  winws=$([bool](Get-Process -Name winws -ErrorAction SilentlyContinue))"
    exit 0
}

# ======================================================
# Основной цикл: событие WMI + страховочный таймер
# ======================================================

# Выполнить один раз сразу, чтобы прийти в консистентное состояние.
Sync-State

# Подписываемся на изменения сетевых адаптеров (событие приходит мгновенно).
$query = @"
SELECT * FROM __InstanceModificationEvent WITHIN 2
WHERE TargetInstance ISA 'MSFT_NetAdapter'
  AND TargetInstance.MediaConnectState <> PreviousInstance.MediaConnectState
"@

try {
    Register-CimIndicationEvent -Namespace 'root/StandardCimv2' -Query $query `
        -SourceIdentifier 'VpnAdapterChange' -Action {
            try {
                # дадим Windows секунду, чтобы адаптер окончательно встал в Up/Down
                Start-Sleep -Milliseconds 1500
                Sync-State
            } catch { }
        } | Out-Null
    Write-Log "Подписка на WMI MSFT_NetAdapter оформлена."
} catch {
    Write-Log "Не удалось подписаться на WMI: $($_.Exception.Message). Останется только таймер." 'WARN'
}

# Страховочный таймер — раз в 15 секунд перепроверяем состояние (на случай пропущенных событий).
try {
    $timer = New-Object System.Timers.Timer
    $timer.Interval  = 15000
    $timer.AutoReset = $true
    Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier 'VpnSafetyTick' -Action {
        try { Sync-State } catch { }
    } | Out-Null
    $timer.Start()
} catch {
    Write-Log "Не удалось запустить таймер-страховку: $($_.Exception.Message)" 'WARN'
}

# «Вечный» сон до сигнала завершения — события выполняются в фоне.
try {
    while ($true) { Start-Sleep -Seconds 3600 }
} finally {
    Unregister-Event -SourceIdentifier 'VpnAdapterChange' -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier 'VpnSafetyTick'   -ErrorAction SilentlyContinue
    if ($mutex) { $mutex.ReleaseMutex() | Out-Null; $mutex.Dispose() }
    Write-Log "=== switchVPNzapret завершён ==="
}
