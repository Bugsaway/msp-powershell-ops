<#
.SYNOPSIS
    Confirms a recent, non-trivial backup file exists and the last job reported success.
.DESCRIPTION
    For each configured check: newest matching file must be younger than MaxAgeHours and at
    least MinSizeMB, and if a status log is given its last line must contain the OK marker.
    A check whose path doesn't exist is skipped, so the same script runs on every server and
    only bites where a backup job is actually configured.
.NOTES
    Run context : SYSTEM
    Exit 0      : All configured backups fresh, or nothing configured on this box
    Exit 1      : Stale, undersized, or last run failed -> ticket
    Ninja setup : Daily, an hour or two after the backup window. Ticket on exit 1.
                  This is the Ninja hook for backup/Setup-ODMariaBackupTask.ps1.
#>

# ---------------- CONFIG ----------------
$Checks = @(
    @{ Name='Open Dental MariaBackup'; Path='C:\MariaBackupFiles\FullBackups'; Filter='opendental_bak_*.xb.7z'; MaxAgeHours=26; MinSizeMB=5;
       StatusLog='C:\MariaBackupFiles\Logs\status.log'; OkMarker=' OK ' }
    # Add more. Path missing = skipped.
    # @{ Name='Eaglesoft backup'; Path='D:\EaglesoftBackups'; Filter='*.bak'; MaxAgeHours=26; MinSizeMB=50 }
)
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$exitCode = 0
$ran = 0
Write-Output "=== Backup freshness on $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm') ==="

foreach ($c in $Checks) {
    if (-not (Test-Path $c.Path)) { continue }
    $ran++
    $problems = @()
    $newest = Get-ChildItem $c.Path -Filter $c.Filter -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) {
        $problems += "no files matching $($c.Filter)"
    } else {
        $ageH = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalHours, 1)
        $sizeMB = [math]::Round($newest.Length / 1MB, 1)
        Write-Output "  $($c.Name): $($newest.Name) age $ageH h size $sizeMB MB"
        if ($ageH -gt $c.MaxAgeHours) { $problems += "stale ($ageH h > $($c.MaxAgeHours) h)" }
        if ($sizeMB -lt $c.MinSizeMB) { $problems += "undersized ($sizeMB MB < $($c.MinSizeMB) MB)" }
    }
    if ($c.StatusLog -and (Test-Path $c.StatusLog)) {
        $last = Get-Content $c.StatusLog -Tail 1 -ErrorAction SilentlyContinue
        Write-Output "    last status: $last"
        if ($last -notmatch [regex]::Escape($c.OkMarker)) { $problems += "last run not OK" }
    }
    if ($problems) {
        Write-Output "    FLAG: $($problems -join ', ')"
        $exitCode = 1
    }
}

if ($ran -eq 0) { Write-Output "RESULT: No configured backup paths on this box." ; exit 0 }
if ($exitCode -eq 0) { Write-Output "RESULT: Backups fresh." } else { Write-Output "RESULT: Backup problem. Check the job before the next window." }
exit $exitCode
