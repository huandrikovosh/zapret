# Stops zapret while a VPN (FlClashX / Happ) is connected, starts it again when VPN is off.
# Works in TUN mode only (the script watches for the VPN network adapter).
 
# ---------- settings ----------
# Adapter names or descriptions of your VPN clients (wildcards allowed).
# Find them with: Get-NetAdapter | ft Name, InterfaceDescription, Status   (while VPN is ON)
$adapters = @("FlClashX", "*Happ*")
 
$service = "zapret"
$bat     = "E:\11111111111111111111111\general.bat"
$log     = "$env:TEMP\vpn-zapret.log"
# ------------------------------
 
# Re-launch as administrator if needed
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
 
function Write-Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Add-Content -Path $log
}
 
function Test-Vpn {
    $up = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    foreach ($a in $adapters) {
        if ($up | Where-Object { $_.Name -like $a -or $_.InterfaceDescription -like $a }) { return $true }
    }
    return $false
}
 
function Stop-Zapret {
    try { Stop-Service $service -Force -ErrorAction Stop } catch { Write-Log "Stop-Service: $($_.Exception.Message)" }
    Stop-Process -Name winws -Force -ErrorAction SilentlyContinue
    Write-Log "VPN up -> zapret stopped"
}
 
function Start-Zapret {
    if (Get-Process winws -ErrorAction SilentlyContinue) { return }
    $started = $false
    if (Get-Service $service -ErrorAction SilentlyContinue) {
        try { Start-Service $service -ErrorAction Stop; $started = $true } catch { Write-Log "Start-Service: $($_.Exception.Message)" }
    }
    if (-not $started) {
        Start-Process $bat -WindowStyle Hidden -WorkingDirectory (Split-Path $bat)
    }
    Write-Log "VPN down -> zapret started"
}
 
$state = $null
while ($true) {
    $up = Test-Vpn
    if ($up -ne $state) {
        $state = $up
        if ($up) { Stop-Zapret } else { Start-Zapret }
    }
    Start-Sleep -Seconds 3
}
