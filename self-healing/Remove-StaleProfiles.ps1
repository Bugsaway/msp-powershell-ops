<#
.SYNOPSIS
    Removes local user profiles nobody has used in a long time. Dry-run by default.
.DESCRIPTION
    Dual-signal detection. A profile is stale only if BOTH agree it is older than $DaysInactive:
      Signal 1: Win32_UserProfile.LastUseTime
      Signal 2: NTUSER.DAT last write time
    LastUseTime alone lies on Win10 1809 and later (some builds bump it at boot), and NTUSER.DAT
    alone gets touched by group policy and servicing. Requiring both keeps a live profile safe.

    Never touches: loaded profiles, special profiles (SYSTEM, LocalService, NetworkService),
    the built-in Administrator, Default and Public, any account in $ExcludeUsers, or any
    account with a current session (quser).

    With $DryRun = $true it only reports what it would remove and exits 0. Set $DryRun = $false
    to actually delete. Deletion uses the Win32_UserProfile Delete method, which removes both
    the folder and the ProfileList registry entry, so no orphaned SIDs.
.NOTES
    Run context : SYSTEM
    Exit 0      : Nothing stale, dry run complete, or all stale profiles removed
    Exit 1      : One or more removals failed -> ticket
    Ninja setup : Monthly, or trigger from a "Disk free space < 15%" condition after
                  Invoke-DiskCleanup. Run dry first on a new site and read the output.
#>

# ---------------- CONFIG ----------------
$DaysInactive = 90
$DryRun       = $true
$ExcludeUsers = @('Administrator')   # local usernames never to remove, case-insensitive
$MinSizeMB    = 0        # only report or remove profiles at least this big (0 = all)
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$cutoff   = (Get-Date).AddDays(-$DaysInactive)
$exitCode = 0

# Current sessions, so a logged-in user with a stale LastUseTime is never touched
$sessionUsers = @()
$q = quser 2>$null
if ($q) {
    $sessionUsers = $q | Select-Object -Skip 1 | ForEach-Object { ($_ -replace '^>', '').Trim() -split '\s+' | Select-Object -First 1 }
}

function Get-FolderSizeMB {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($sum) { [math]::Round($sum / 1MB, 0) } else { 0 }
}

$mode = if ($DryRun) { 'DRY RUN' } else { 'LIVE' }
Write-Output "=== Stale profile check on $env:COMPUTERNAME [$mode] - inactive > $DaysInactive days ==="

$profiles = Get-CimInstance Win32_UserProfile | Where-Object {
    -not $_.Special -and
    -not $_.Loaded -and
    $_.LocalPath -and
    $_.LocalPath -notmatch '\\(Default|Public|Administrator)$'
}

$stale = @()
foreach ($p in $profiles) {
    $name = Split-Path $p.LocalPath -Leaf
    if ($ExcludeUsers -contains $name) { continue }
    if ($sessionUsers -contains $name) { continue }
    if (-not (Test-Path $p.LocalPath)) { continue }   # registry ghost, leave for manual review

    # Signal 1
    $lastUse = $p.LastUseTime
    if (-not $lastUse) { continue }

    # Signal 2
    $ntuser = Join-Path $p.LocalPath 'NTUSER.DAT'
    if (-not (Test-Path $ntuser)) { continue }
    $ntWrite = (Get-Item $ntuser -Force).LastWriteTime

    if ($lastUse -lt $cutoff -and $ntWrite -lt $cutoff) {
        $sizeMB = Get-FolderSizeMB $p.LocalPath
        if ($sizeMB -lt $MinSizeMB) { continue }
        $stale += [pscustomobject]@{
            User      = $name
            Path      = $p.LocalPath
            LastUse   = $lastUse.ToString('yyyy-MM-dd')
            NTUSER    = $ntWrite.ToString('yyyy-MM-dd')
            SizeMB    = $sizeMB
            Profile   = $p
        }
    }
}

if (-not $stale) {
    Write-Output "RESULT: No stale profiles."
    exit 0
}

$totalMB = ($stale | Measure-Object SizeMB -Sum).Sum
Write-Output "Stale profiles ($($stale.Count), $totalMB MB):"
$stale | ForEach-Object { Write-Output ("  {0,-20} last use {1}  ntuser {2}  {3,6} MB" -f $_.User, $_.LastUse, $_.NTUSER, $_.SizeMB) }

if ($DryRun) {
    Write-Output "RESULT: Dry run. Set `$DryRun = `$false to remove."
    exit 0
}

foreach ($s in $stale) {
    try {
        Invoke-CimMethod -InputObject $s.Profile -MethodName Delete -ErrorAction Stop | Out-Null
        Write-Output "  Removed $($s.User) ($($s.SizeMB) MB)"
    }
    catch {
        Write-Output "  FAILED $($s.User): $($_.Exception.Message)"
        $exitCode = 1
    }
}

if ($exitCode -eq 0) { Write-Output "RESULT: Removed $($stale.Count) profile(s), ~$totalMB MB." }
else { Write-Output "RESULT: One or more removals failed. Manual review needed." }
exit $exitCode
