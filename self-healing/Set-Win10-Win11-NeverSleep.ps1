#Requires -Version 2.0
<#
.SYNOPSIS
    Forces a chosen power plan with "Never sleep / hibernate / display-off" on
    Windows 10 and 11 workstations, disables Fast Startup, and stops USB power
    saving (selective suspend + per-device power-off) to keep USB devices such
    as intraoral sensors from dropping.

.DESCRIPTION
    Safe across a mixed fleet. Applies changes ONLY on Windows 10/11 CLIENT
    machines (build >= 10240 AND ProductType = WinNT) and cleanly skips
    everything else (Windows 8.1 and older, and every Server SKU).

    NOTE: because the build floor (10240) also covers Windows Server 2016
    (14393), 2019 (17763), 2022 (20348) and 2025 (26100), the ProductType =
    WinNT check is what keeps all of those servers out -- do not remove it.

    On a matching machine it:
      1. Sets the active power plan to $TargetPlan (only if that plan exists).
      2. Sets these on the NOW-active plan, AC and DC:
           - Sleep after            (STANDBYIDLE)     -> Never
           - Hibernate after        (HIBERNATEIDLE)   -> Never
           - Unattended sleep after (hidden setting)  -> Never
           - Display off            (VIDEOIDLE)       -> Never  ($KeepMonitorOn)
           - USB selective suspend                    -> Disabled ($DisableUsbPowerSaving)
      3. Stops USB power saving when $DisableUsbPowerSaving = $true:
           - Global master switch  HKLM\...\Services\USB\DisableSelectiveSuspend = 1
           - Per-device: unchecks "Allow the computer to turn off this device
             to save power" on every USB root hub / hub / device.
      4. Disables Fast Startup    when $DisableFastStartup = $true
           (registry HiberbootEnabled = 0; keeps normal hibernate available).
      5. Fully disables hibernation when $DisableHibernationFeature = $true
           (also removes hiberfil.sys).

    Runs as SYSTEM (e.g., NinjaOne). Exit 0 = success or clean skip; exit 1 =
    a load-bearing command failed, so a ticket only fires on a real error.
    (Individual per-device USB writes are best-effort and do NOT fail the run.)

    Idempotent -- every value is set to a fixed target; nothing accumulates or
    duplicates a plan. Safe to run repeatedly / on a recurring schedule.

.NOTES
    Build gate: 10240 = Win10 1507 ... 19045 = Win10 22H2 | 22000+ = Win11.
    Fast Startup change applies at the next FULL shutdown + boot.
    A reboot lets the USB stack re-read the global switch and re-enumerate hubs.
    The per-device USB step uses Get-WmiObject (Windows PowerShell / NinjaOne
    default, present on both Win10 and Win11). Under PowerShell 7 it is skipped
    with a NOTE; the plan + global switch above still disable selective suspend.
#>

# ------------------------------ Options -----------------------------------
# Which power plan to force. One of: 'HighPerformance', 'Balanced',
# 'PowerSaver', or '' (empty = don't change the plan, just fix its timeouts).
# A plan that isn't present (e.g. hidden on Modern Standby / InstantGo devices)
# is skipped safely -- the timeouts below are still enforced on the active plan.
$TargetPlan = 'HighPerformance'

# Keep the display from turning off on its own ("monitors going dark").
#   $true  = display timeout = Never (default).
#   $false = leave the display timeout untouched.
# Want the screen to still turn off after a while? Keep $true and change the
# two 'Display' values below from '0' to the minutes you want.
$KeepMonitorOn = $true

# Stop USB power saving (prevents sensors / USB devices dropping). Covers the
# power-plan selective-suspend setting, the global registry master switch, and
# the per-device "turn off to save power" checkbox on USB hubs.
#   $true  = disable all USB power saving (default).
$DisableUsbPowerSaving = $true

# Disable Fast Startup / Fast Boot (hybrid shutdown that skips a clean
# shutdown and causes update/driver/"restart-fixes-it-but-shutdown-doesn't"
# gremlins).
#   $true  = disable it (default). Leaves normal hibernate available.
$DisableFastStartup = $true

# Fully disable the hibernation FEATURE (removes hiberfil.sys; this also forces
# Fast Startup off as a side effect).
#   $false = leave hibernate available (default).
$DisableHibernationFeature = $false
# --------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
# Windows 10 RTM. Includes Win 10 (10240+) and Win 11 (22000+); excludes 8.1/8/7.
$MinClientBuild = 10240

# --- Guard 1: client vs server (registry read - works on every PS version) --
try {
    $productType = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions' -Name ProductType).ProductType
}
catch {
    Write-Output "ERROR: Unable to read ProductType. $($_.Exception.Message)"
    exit 1
}
if ($productType -ne 'WinNT') {
    Write-Output "SKIP: ProductType is '$productType' (server SKU, not a client). No changes made."
    exit 0
}

# --- Guard 2: must be Windows 10 or 11 (build >= 10240) ---------------------
try {
    $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber).CurrentBuildNumber
}
catch {
    Write-Output "ERROR: Unable to read CurrentBuildNumber. $($_.Exception.Message)"
    exit 1
}
if ($build -lt $MinClientBuild) {
    Write-Output "SKIP: Build $build is older than Windows 10 (needs >= $MinClientBuild). No changes made."
    exit 0
}

$osName = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
Write-Output "$osName client detected (build $build). Enforcing power settings..."
$exitCode = 0

# --- Step 1: force the target power plan (only if present) ------------------
$planGuids = @{
    'HighPerformance' = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    'Balanced'        = '381b4222-f694-41f0-9685-ff5bb260df2e'
    'PowerSaver'      = 'a1841308-3541-4fab-bc81-f71556f20b4a'
}
if ($TargetPlan -and $planGuids.ContainsKey($TargetPlan)) {
    $targetGuid = $planGuids[$TargetPlan]
    $planList = (& powercfg.exe /list) -join "`n"
    if ($planList -match [regex]::Escape($targetGuid)) {
        & powercfg.exe /setactive $targetGuid | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Output "  OK:   Active plan set to $TargetPlan"
        }
        else {
            Write-Output "  WARN: could not activate $TargetPlan (powercfg exit $LASTEXITCODE)"
            $exitCode = 1
        }
    }
    else {
        Write-Output "  NOTE: '$TargetPlan' plan not present (likely Modern Standby / InstantGo). Keeping current plan; timeouts still enforced."
    }
}
elseif ($TargetPlan) {
    Write-Output "  NOTE: '$TargetPlan' is not a recognized plan name. Keeping current plan."
}

# --- Step 2: timeouts + USB selective suspend on the ACTIVE plan ------------
$UnattendedSleepGuid = '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0'
$UsbSubGuid          = '2a737441-1930-4402-8d77-b2bebba308a3'
$UsbSelSuspendGuid   = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'

$settings = @(
    @{ Desc = 'Sleep (AC)';            Cmd = @('/setacvalueindex','SCHEME_CURRENT','SUB_SLEEP','STANDBYIDLE','0') }
    @{ Desc = 'Sleep (DC)';            Cmd = @('/setdcvalueindex','SCHEME_CURRENT','SUB_SLEEP','STANDBYIDLE','0') }
    @{ Desc = 'Hibernate (AC)';        Cmd = @('/setacvalueindex','SCHEME_CURRENT','SUB_SLEEP','HIBERNATEIDLE','0') }
    @{ Desc = 'Hibernate (DC)';        Cmd = @('/setdcvalueindex','SCHEME_CURRENT','SUB_SLEEP','HIBERNATEIDLE','0') }
    @{ Desc = 'Unattended sleep (AC)'; Cmd = @('/setacvalueindex','SCHEME_CURRENT','SUB_SLEEP',$UnattendedSleepGuid,'0') }
    @{ Desc = 'Unattended sleep (DC)'; Cmd = @('/setdcvalueindex','SCHEME_CURRENT','SUB_SLEEP',$UnattendedSleepGuid,'0') }
)
if ($KeepMonitorOn) {
    $settings += @{ Desc = 'Display (AC)'; Cmd = @('/setacvalueindex','SCHEME_CURRENT','SUB_VIDEO','VIDEOIDLE','0') }
    $settings += @{ Desc = 'Display (DC)'; Cmd = @('/setdcvalueindex','SCHEME_CURRENT','SUB_VIDEO','VIDEOIDLE','0') }
}
if ($DisableUsbPowerSaving) {
    $settings += @{ Desc = 'USB selective suspend (AC)'; State = 'Disabled'; Cmd = @('/setacvalueindex','SCHEME_CURRENT',$UsbSubGuid,$UsbSelSuspendGuid,'0') }
    $settings += @{ Desc = 'USB selective suspend (DC)'; State = 'Disabled'; Cmd = @('/setdcvalueindex','SCHEME_CURRENT',$UsbSubGuid,$UsbSelSuspendGuid,'0') }
}

foreach ($s in $settings) {
    $c = $s.Cmd
    $state = if ($s.ContainsKey('State')) { $s.State } else { 'Never' }
    & powercfg.exe @c | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "  WARN: failed to set $($s.Desc) (powercfg exit $LASTEXITCODE)"
        $exitCode = 1
    }
    else {
        Write-Output "  OK:   $($s.Desc) = $state"
    }
}

# Commit the plan changes
& powercfg.exe /setactive SCHEME_CURRENT | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Output "  WARN: /setactive SCHEME_CURRENT failed (powercfg exit $LASTEXITCODE)"
    $exitCode = 1
}

# --- Step 3: stop USB power saving (global switch + per-device) -------------
if ($DisableUsbPowerSaving) {
    # (a) Global master switch: overrides selective suspend system-wide.
    try {
        $usbKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\USB'
        if (-not (Test-Path $usbKey)) { New-Item -Path $usbKey -Force | Out-Null }
        New-ItemProperty -Path $usbKey -Name 'DisableSelectiveSuspend' -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Output "  OK:   Global USB selective suspend disabled (DisableSelectiveSuspend = 1)"
    }
    catch {
        Write-Output "  WARN: could not set global USB switch. $($_.Exception.Message)"
        $exitCode = 1
    }

    # (b) Per-device: uncheck "Allow the computer to turn off this device to
    #     save power" on USB root hubs / hubs / devices. Best-effort.
    try {
        $usbDevices = @(Get-WmiObject -Namespace 'root\wmi' -Class 'MSPower_DeviceEnable' -ErrorAction Stop |
                        Where-Object { $_.InstanceName -like 'USB*' })
        if ($usbDevices.Count -eq 0) {
            Write-Output "  NOTE: no USB power-management instances found to adjust."
        }
        else {
            $done = 0
            foreach ($dev in $usbDevices) {
                try {
                    if ($dev.Enable -ne $false) {
                        $dev.Enable = $false
                        $null = $dev.Put()
                    }
                    $done++
                }
                catch {
                    Write-Output "  WARN: could not update USB power mgmt on '$($dev.InstanceName)'."
                }
            }
            Write-Output "  OK:   'Turn off to save power' cleared on $done USB device(s)."
        }
    }
    catch {
        Write-Output "  NOTE: per-device USB power management not adjustable in this PowerShell host (skipped). $($_.Exception.Message)"
    }
}

# --- Step 4: disable Fast Startup (surgical; keeps hibernate) ---------------
if ($DisableFastStartup) {
    try {
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -PropertyType DWord -Force | Out-Null
        Write-Output "  OK:   Fast Startup disabled (applies at next full shutdown)"
    }
    catch {
        Write-Output "  WARN: could not disable Fast Startup. $($_.Exception.Message)"
        $exitCode = 1
    }
}

# --- Step 5: optionally disable the hibernation feature entirely ------------
if ($DisableHibernationFeature) {
    & powercfg.exe /hibernate off | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "  WARN: /hibernate off failed (powercfg exit $LASTEXITCODE)"
        $exitCode = 1
    }
    else {
        Write-Output "  OK:   Hibernation feature disabled (hiberfil.sys removed)"
    }
}

if ($exitCode -eq 0) {
    Write-Output "SUCCESS: Power configuration enforced."
}
else {
    Write-Output "COMPLETED WITH ERRORS: one or more steps failed (see above)."
}
exit $exitCode
