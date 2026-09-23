<#
.SYNOPSIS
    Checks physical disk health and SMART-style reliability counters.
.DESCRIPTION
    Get-PhysicalDisk HealthStatus and OperationalStatus, then Get-StorageReliabilityCounter for
    uncorrected errors, wear, and temperature. Also reports HDD vs SSD so you know which boxes
    a cleanup script won't help. Read-only.
.NOTES
    Run context : SYSTEM
    Exit 0      : All disks healthy
    Exit 1      : A disk is Warning or Unhealthy, or a counter is over threshold -> ticket
    Ninja setup : Daily. Ticket on exit 1. Writes custom field diskSummary if present.
                  Reliability counters need a driver that exposes them. NVMe and most SATA do,
                  some RAID controllers hide the physical disks entirely.
#>

# ---------------- CONFIG ----------------
$MaxUncorrectedErrors = 0
$MaxWearPercent       = 90
$MaxTempC             = 60
$CustomField          = 'diskSummary'
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$exitCode = 0
$summary = @()
Write-Output "=== Disk health on $env:COMPUTERNAME ==="

$disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
if (-not $disks) {
    Write-Output "No physical disks visible (RAID controller?). Check the controller tool instead."
    exit 0
}

foreach ($d in $disks) {
    $sizeGB = [math]::Round($d.Size / 1GB)
    $line = "$($d.FriendlyName) $($d.MediaType) $sizeGB GB $($d.HealthStatus)"
    Write-Output "  $line ($($d.OperationalStatus -join ','))"
    $bad = @()
    if ($d.HealthStatus -ne 'Healthy') { $bad += "health $($d.HealthStatus)" }

    $r = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    if ($r) {
        Write-Output ("    wear {0}%  temp {1}C  power-on {2}h  read-uncorr {3}  write-uncorr {4}  read-err {5}" -f `
            $r.Wear, $r.Temperature, $r.PowerOnHours, $r.ReadErrorsUncorrected, $r.WriteErrorsUncorrected, $r.ReadErrorsTotal)
        if ($r.ReadErrorsUncorrected -gt $MaxUncorrectedErrors)  { $bad += "read errors uncorrected $($r.ReadErrorsUncorrected)" }
        if ($r.WriteErrorsUncorrected -gt $MaxUncorrectedErrors) { $bad += "write errors uncorrected $($r.WriteErrorsUncorrected)" }
        if ($r.Wear -gt $MaxWearPercent)                         { $bad += "wear $($r.Wear)%" }
        if ($r.Temperature -gt $MaxTempC)                        { $bad += "temp $($r.Temperature)C" }
    } else {
        Write-Output "    reliability counters not exposed"
    }

    if ($bad) {
        Write-Output "    FLAG: $($bad -join ', ')"
        $exitCode = 1
        $summary += "$line FLAG $($bad -join '/')"
    } else {
        $summary += $line
    }
}

if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) { try { Ninja-Property-Set $CustomField ($summary -join ' | ') } catch {} }

if ($exitCode -eq 0) { Write-Output "RESULT: All disks healthy." } else { Write-Output "RESULT: Disk problem. Quote a replacement and confirm backups." }
exit $exitCode
