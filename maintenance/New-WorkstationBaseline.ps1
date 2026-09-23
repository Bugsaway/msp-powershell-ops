<#
.SYNOPSIS
    Onboarding baseline for a fresh dental workstation.
.DESCRIPTION
    Applies the settings every new practice PC needs before it goes on a desk. Every step is
    detect-first and idempotent, so it's safe to re-run on an existing machine to bring it back
    to standard. Steps this script owns:
      1. Time zone
      2. Remote Desktop enabled with Network Level Authentication, firewall rule on.
         On by default because RMM-managed practice workstations are supported remotely and
         NLA plus the domain firewall profile keeps it off the open network. Set $EnableRdp
         to $false for sites that prohibit it or where the RMM's own remote tool is the only path.
      3. Fast Startup off (a shutdown is a real shutdown)
      4. Consumer noise off: Cortana, consumer feature installs, tips, Xbox services, OneDrive autostart
      5. Explorer shows file extensions and hidden files for the admin profile
      6. Windows Update: no auto-restart with users logged on, defer to the RMM patch policy
    Steps owned by sibling scripts are chained at the end if they're on disk next to this one.
    In NinjaOne, add them to the same automation after this script instead:
      self-healing\Set-Win10-Win11-NeverSleep.ps1
      security\Set-EventLogSizes.ps1
      security\Set-DentalDefenderExclusions.ps1
      self-healing\Sync-SystemTime.ps1
.NOTES
    Run context : SYSTEM, or elevated by hand
    Exit 0      : Baseline applied
    Exit 1      : A step failed -> review before the machine ships
    Ninja setup : New-device automation. Ticket on exit 1.
    Output      : One line per step: ok (already set), set, or FAILED with the error.
    Does not    : Rename, domain-join, or install software. Those need credentials or installers
                  and belong in their own steps.
#>

# ---------------- CONFIG ----------------
$TimeZone              = 'Eastern Standard Time'   # set per site group
$EnableRdp             = $true
$DisableFastStartup    = $true
$DisableConsumerNoise  = $true
$RemoveOneDriveAutorun = $true
$ExplorerTweaks        = $true
$WuNoAutoReboot        = $true
$ChainSiblings         = $true      # run sibling scripts if found relative to this file
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$exitCode = 0
function Step { param([string]$Name, [scriptblock]$Detect, [scriptblock]$Apply)
    try {
        if (& $Detect) { Write-Output "  ok      $Name"; return }
        & $Apply
        if (& $Detect) { Write-Output "  set     $Name" } else { Write-Output "  FAILED  $Name (did not verify)"; $script:exitCode = 1 }
    } catch { Write-Output "  FAILED  $Name : $($_.Exception.Message)"; $script:exitCode = 1 }
}
function Set-Reg { param($Path, $Name, $Value, $Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Get-Reg { param($Path, $Name) try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null } }

Write-Output "=== Workstation baseline on $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm') ==="

# 1. Time zone
Step "time zone $TimeZone" { (Get-TimeZone).Id -eq $TimeZone } { Set-TimeZone -Id $TimeZone }

# 2. RDP with NLA
if ($EnableRdp) {
    $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    Step 'RDP enabled' { (Get-Reg $ts 'fDenyTSConnections') -eq 0 } { Set-Reg $ts 'fDenyTSConnections' 0 }
    Step 'RDP requires NLA' { (Get-Reg "$ts\WinStations\RDP-Tcp" 'UserAuthentication') -eq 1 } { Set-Reg "$ts\WinStations\RDP-Tcp" 'UserAuthentication' 1 }
    Step 'RDP firewall rules' { -not (Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Where-Object Enabled -ne 'True') } { Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' }
}

# 3. Fast Startup
if ($DisableFastStartup) {
    $pw = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    Step 'Fast Startup off' { (Get-Reg $pw 'HiberbootEnabled') -eq 0 } { Set-Reg $pw 'HiberbootEnabled' 0 }
}

# 4. Consumer noise
if ($DisableConsumerNoise) {
    $cc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
    Step 'consumer features off' { (Get-Reg $cc 'DisableWindowsConsumerFeatures') -eq 1 } { Set-Reg $cc 'DisableWindowsConsumerFeatures' 1 }
    Step 'tips and suggestions off' { (Get-Reg $cc 'DisableSoftLanding') -eq 1 } { Set-Reg $cc 'DisableSoftLanding' 1 }
    $ws = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
    Step 'Cortana off' { (Get-Reg $ws 'AllowCortana') -eq 0 } { Set-Reg $ws 'AllowCortana' 0 }
    foreach ($svc in 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc') {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            Step "$svc disabled" { (Get-Service $svc).StartType -eq 'Disabled' } { Stop-Service $svc -Force -ErrorAction SilentlyContinue; Set-Service $svc -StartupType Disabled }
        }
    }
}
if ($RemoveOneDriveAutorun) {
    $od = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
    Step 'OneDrive sync disabled by policy' { (Get-Reg $od 'DisableFileSyncNGSC') -eq 1 } { Set-Reg $od 'DisableFileSyncNGSC' 1 }
}

# 5. Explorer for the admin profile (HKCU of whoever is running, plus Default user hive for new profiles)
if ($ExplorerTweaks) {
    $adv = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Step 'show file extensions' { (Get-Reg $adv 'HideFileExt') -eq 0 } { Set-Reg $adv 'HideFileExt' 0 }
    Step 'show hidden files' { (Get-Reg $adv 'Hidden') -eq 1 } { Set-Reg $adv 'Hidden' 1 }
    $def = 'C:\Users\Default\NTUSER.DAT'
    if (Test-Path $def) {
        try {
            reg load HKU\DefaultTemplate $def 2>&1 | Out-Null
            Set-Reg 'Registry::HKU\DefaultTemplate\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
            Write-Output "  set     default profile shows file extensions"
        } catch { Write-Output "  skip    default profile hive ($($_.Exception.Message))" }
        finally { [gc]::Collect(); reg unload HKU\DefaultTemplate 2>&1 | Out-Null }
    }
}

# 6. Windows Update behavior
if ($WuNoAutoReboot) {
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    Step 'WU no auto-reboot with users' { (Get-Reg $au 'NoAutoRebootWithLoggedOnUsers') -eq 1 } { Set-Reg $au 'NoAutoRebootWithLoggedOnUsers' 1 }
}

# Chain siblings when run from the repo on disk
if ($ChainSiblings -and $PSScriptRoot) {
    $repo = Split-Path $PSScriptRoot -Parent
    $chain = @('self-healing\Set-Win10-Win11-NeverSleep.ps1', 'security\Set-EventLogSizes.ps1', 'security\Set-DentalDefenderExclusions.ps1', 'self-healing\Sync-SystemTime.ps1')
    foreach ($rel in $chain) {
        $path = Join-Path $repo $rel
        if (-not (Test-Path $path)) { Write-Output "  skip    $rel (not on disk, run from Ninja)"; continue }
        Write-Output "--- $rel"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path
        if ($LASTEXITCODE -ne 0) { Write-Output "  FAILED  $rel exit $LASTEXITCODE"; $exitCode = 1 }
    }
}

if ($exitCode -eq 0) { Write-Output "RESULT: Baseline applied. Reboot before handing off." } else { Write-Output "RESULT: One or more steps failed. Review before the machine ships." }
exit $exitCode
