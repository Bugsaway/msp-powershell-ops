<#
.SYNOPSIS
    Installs PSWindowsUpdate if missing, then optionally installs pending Windows Updates
    and defers the reboot to a set evening time.
.DESCRIPTION
    Detect-first. If the module is present and nothing is pending, it exits 0 without touching anything.
    Run as SYSTEM through Ninja or elevated by hand.

    Modes ($Mode):
      ModuleOnly  - only ensure PSWindowsUpdate is installed
      Install     - install everything pending, never reboot inside the script (-IgnoreReboot)
                    If a reboot is required and $RebootAt is set, schedules it for that clock time.
                    If $RebootAt is empty, leaves the reboot to Ninja's reboot policy.

    Reboot scheduling uses shutdown.exe /t with the seconds until $RebootAt. If that time has
    already passed today it targets tomorrow. Cancel with shutdown /a before it fires.
.NOTES
    Exit 0 = nothing pending, or updates installed (reboot scheduled or deferred)
    Exit 1 = module install failed, gallery unreachable, or update install threw
    Ninja timeout: 120 min. Cumulative updates on old disks take a while.
#>

# ---------------- CONFIG ----------------
$Mode            = 'Install'    # 'ModuleOnly' or 'Install'
$RebootAt        = '19:30'      # 24h local time, or '' to leave reboot to Ninja policy
$IncludeDrivers  = $false       # Microsoft Update drivers lag OEM tools, off by default
$ExcludeKBs      = @()          # e.g. @('KB5034441')
# ----------------------------------------

# 1. Operating System exclusion check
$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -like "*Windows 7*" -or $os.Version -like "6.1*") {
    Write-Output "INFO: This endpoint is running Windows 7. Skipping."
    exit 0
}

# 2. Force TLS 1.2 for modern gallery connections
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    # 3. NuGet provider
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Write-Output "Installing NuGet Provider..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
    }

    # 4. PSWindowsUpdate module
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Output "PSWindowsUpdate module not found. Installing now..."
        Set-ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue
        Install-Module -Name PSWindowsUpdate -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop | Out-Null
        Write-Output "Successfully installed PSWindowsUpdate."
    } else {
        Write-Output "PSWindowsUpdate module is already installed."
    }
}
catch {
    Write-Output "ERROR: module setup failed. $($_.Exception.Message)"
    exit 1
}

if ($Mode -ne 'Install') { exit 0 }

# 5. Detect pending updates
Import-Module PSWindowsUpdate -ErrorAction Stop
$wuArgs = @{ AcceptAll = $true; IgnoreReboot = $true }
if ($IncludeDrivers) {
    Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    $wuArgs.MicrosoftUpdate = $true
}
if ($ExcludeKBs.Count -gt 0) { $wuArgs.NotKBArticleID = $ExcludeKBs }

$pending = Get-WindowsUpdate @wuArgs -ErrorAction SilentlyContinue
if (-not $pending) {
    Write-Output "RESULT: No pending updates."
    exit 0
}
Write-Output "Pending ($(@($pending).Count)):"
$pending | ForEach-Object { Write-Output "  $($_.KB) $($_.Title)" }

# 6. Install, never reboot here
try {
    Install-WindowsUpdate @wuArgs -ErrorAction Stop | Out-Null
}
catch {
    Write-Output "ERROR: update install failed. $($_.Exception.Message)"
    exit 1
}

# 7. Reboot handling
$needsReboot = (Get-WURebootStatus -Silent -ErrorAction SilentlyContinue)
if (-not $needsReboot) {
    Write-Output "RESULT: Updates installed. No reboot required."
    exit 0
}

if (-not $RebootAt) {
    Write-Output "RESULT: Updates installed. Reboot required, left to Ninja reboot policy."
    exit 0
}

$target = Get-Date $RebootAt
if ($target -le (Get-Date)) { $target = $target.AddDays(1) }
$secs = [int]($target - (Get-Date)).TotalSeconds
shutdown.exe /r /f /t $secs /c "Windows Update reboot scheduled by IT for $($target.ToString('h:mm tt')). Save your work." /d p:2:17
Write-Output "RESULT: Updates installed. Reboot scheduled for $($target.ToString('yyyy-MM-dd HH:mm')) ($secs s). Cancel with: shutdown /a"
exit 0
