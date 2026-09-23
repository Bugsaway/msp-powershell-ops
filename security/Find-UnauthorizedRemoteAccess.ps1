<#
.SYNOPSIS
    Finds remote access tools that aren't on the allowlist.
.DESCRIPTION
    Inventories remote access software four ways: services, uninstall registry entries, install
    folders (machine and per-user), and running processes. For ScreenConnect it pulls the
    instance ID and relay host out of the service ImagePath so you can tell yours from theirs.
    Anything not matched by the allowlist is reported with its live TCP connections.
.NOTES
    Run context : SYSTEM
    Exit 0      : Only allowlisted tools present
    Exit 1      : Unrecognized remote access tool found -> ticket. Do not uninstall from here,
                  collect evidence first (incident-response/Collect-IncidentEvidence.ps1).
    Ninja setup : Daily on every endpoint. Ticket on exit 1.
#>

# ---------------- CONFIG ----------------
# ScreenConnect instance IDs you own (the 16 hex chars in "ScreenConnect Client (xxxxxxxxxxxxxxxx)").
# Take these from a known-good managed machine. Empty list means every ScreenConnect is flagged.
$AllowedScreenConnectInstances = @()
# Tool names you deploy on purpose. Matched against service, product, folder, and process names.
$AllowedToolPatterns = @('NinjaRMM', 'NinjaOne', 'Ninja Remote', 'ncstreamer', 'NinjaRMMAgent')
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$toolRegex = '(?i)ScreenConnect|ConnectWise Control|AnyDesk|TeamViewer|Splashtop|LogMeIn|RustDesk|Atera|SimpleHelp|Supremo|RemotePC|GoToAssist|GoTo Resolve|UltraViewer|Zoho Assist|MeshAgent|Syncro|Level\.io|Chrome Remote Desktop|remoting_host|DWAgent|NoMachine|Radmin|AeroAdmin|Ammyy|Action1|Pulseway|Tactical|Datto RMM|CentraStage|VNC|Bomgar|BeyondTrust|Remote Utilities|rutserv|Getscreen|HopToDesk|Zoom.*Remote'

function Test-Allowed {
    param([string]$Text)
    foreach ($p in $AllowedToolPatterns) { if ($Text -like "*$p*") { return $true } }
    return $false
}

$findings = @()

# --- 1. Services ---
foreach ($s in Get-CimInstance Win32_Service) {
    $blob = "$($s.Name) $($s.DisplayName) $($s.PathName)"
    if ($blob -notmatch $toolRegex) { continue }
    if (Test-Allowed $blob) { continue }
    $detail = "service $($s.Name) [$($s.State)] $($s.PathName)"
    if ($blob -match 'ScreenConnect') {
        $inst = if ($s.Name -match '\(([0-9a-f]{16})\)') { $matches[1] } else { 'unknown' }
        $relay = if ($s.PathName -match '[?&]h=([^&"\s]+)') { $matches[1] } else { 'unknown' }
        if ($AllowedScreenConnectInstances -contains $inst) { continue }
        $detail = "ScreenConnect instance $inst relay $relay [$($s.State)] $($s.PathName)"
    }
    $findings += $detail
}

# --- 2. Uninstall registry ---
$uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
if (-not (Get-PSDrive HKU -ErrorAction SilentlyContinue)) { New-PSDrive HKU Registry HKEY_USERS -ErrorAction SilentlyContinue | Out-Null }
$uninstallKeys += 'HKU:\*\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
foreach ($k in Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue) {
    $blob = "$($k.DisplayName) $($k.Publisher) $($k.InstallLocation)"
    if ($blob -notmatch $toolRegex) { continue }
    if (Test-Allowed $blob) { continue }
    if ($blob -match 'ScreenConnect' -and $k.DisplayName -match '\(([0-9a-f]{16})\)' -and $AllowedScreenConnectInstances -contains $matches[1]) { continue }
    $findings += "installed $($k.DisplayName) $($k.DisplayVersion) installed $($k.InstallDate)"
}

# --- 3. Folders ---
$roots = @("$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramData")
$roots += Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)\AppData\Local"; "$($_.FullName)\AppData\Roaming" }
foreach ($r in $roots) {
    if (-not (Test-Path $r)) { continue }
    foreach ($d in Get-ChildItem $r -Directory -ErrorAction SilentlyContinue) {
        if ($d.Name -notmatch $toolRegex) { continue }
        if (Test-Allowed $d.Name) { continue }
        if ($d.Name -match 'ScreenConnect' -and $d.Name -match '\(([0-9a-f]{16})\)' -and $AllowedScreenConnectInstances -contains $matches[1]) { continue }
        $findings += "folder $($d.FullName) created $($d.CreationTime.ToString('yyyy-MM-dd HH:mm'))"
    }
}

# --- 4. Processes with live connections ---
$conns = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue
foreach ($p in Get-CimInstance Win32_Process) {
    $blob = "$($p.Name) $($p.ExecutablePath) $($p.CommandLine)"
    if ($blob -notmatch $toolRegex) { continue }
    if (Test-Allowed $blob) { continue }
    if ($blob -match 'ScreenConnect') {
        $scAllowed = $false
        foreach ($id in $AllowedScreenConnectInstances) { if ($blob -match $id) { $scAllowed = $true } }
        if ($scAllowed) { continue }
    }
    $remote = ($conns | Where-Object OwningProcess -eq $p.ProcessId | ForEach-Object { "$($_.RemoteAddress):$($_.RemotePort)" }) -join ', '
    $findings += "process $($p.Name) PID $($p.ProcessId) $($p.ExecutablePath) connected to [$remote]"
}

$findings = $findings | Select-Object -Unique
Write-Output "=== Remote access audit on $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm') ==="
if (-not $findings) {
    Write-Output "RESULT: No unrecognized remote access tools."
    exit 0
}
Write-Output "Unrecognized remote access ($(@($findings).Count)):"
$findings | ForEach-Object { Write-Output "  $_" }
Write-Output "RESULT: Review required. Collect evidence before removing anything."
exit 1
