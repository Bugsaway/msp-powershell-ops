<#
.SYNOPSIS
    Enforces no-sleep power settings and disables Fast Startup on workstations.
.DESCRIPTION
    Keeps machines awake and reachable for overnight maintenance/patching, allows
    the monitor to sleep, and disables Fast Startup so a "Shut Down" performs a
    true cold boot (so "turn it off and on again" actually clears the problem).
.NOTES
    Run context : SYSTEM
    Exit 0      : Settings applied (or correctly limited on a server/DC)
    Exit 1      : Failed to apply settings
    Ninja setup : Schedule daily. No ticket needed unless exit 1.
#>

# ---------------- CONFIG ----------------
$MonitorOffMinutesAC = 15    # Turn monitor off after N min on AC (0 = never)
$StandbyMinutesDC    = 30    # Sleep after N min on battery (laptops). 0 = never
$DisableFastStartup  = $true
# ----------------------------------------

$os = Get-CimInstance Win32_OperatingSystem

# Servers / DCs (ProductType 2 or 3): only ensure no standby on AC, then exit.
if ($os.ProductType -ne 1) {
    Write-Output "Server/DC detected (ProductType $($os.ProductType)). Ensuring no AC standby only."
    powercfg /change standby-timeout-ac 0   | Out-Null
    powercfg /change hibernate-timeout-ac 0 | Out-Null
    Write-Output "RESULT: Server power settings ensured."
    exit 0
}

try {
    # AC: never sleep / hibernate, disks stay on, monitor off after N min
    powercfg /change standby-timeout-ac 0                    | Out-Null
    powercfg /change hibernate-timeout-ac 0                  | Out-Null
    powercfg /change disk-timeout-ac 0                       | Out-Null
    powercfg /change monitor-timeout-ac $MonitorOffMinutesAC | Out-Null

    # DC (battery): allow sleep to preserve laptop battery
    powercfg /change standby-timeout-dc $StandbyMinutesDC    | Out-Null
    powercfg /change monitor-timeout-dc 10                   | Out-Null

    # Disable Fast Startup (HiberbootEnabled = 0)
    if ($DisableFastStartup) {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
        Set-ItemProperty -Path $key -Name HiberbootEnabled -Value 0 -Type DWord -Force
        Write-Output "Fast Startup disabled."
    }

    Write-Output "RESULT: Power policy enforced (AC = no sleep, monitor off ${MonitorOffMinutesAC}m)."
    exit 0
}
catch {
    Write-Output "Failed to apply power policy: $($_.Exception.Message)"
    exit 1
}
