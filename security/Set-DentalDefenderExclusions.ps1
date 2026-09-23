<#
.SYNOPSIS
    Applies vendor-recommended Microsoft Defender exclusions for dental practice management and imaging software.
.DESCRIPTION
    Detect-first. For each vendor block, checks whether the software is installed by looking for its
    install path. Only then compares the vendor's recommended path and process exclusions against
    Get-MpPreference and adds what's missing. Nothing is removed. Vendors with no install path on
    the box are skipped, so the same script runs everywhere.

    Exclusions are per-vendor lists in the config block. Adjust them against the vendor's current
    KB article before rolling to a group. Real-time scanning of a live database or an image store is
    the usual cause of PMS lockups, slow chart loads, and sensor capture timeouts.
.NOTES
    Run context : SYSTEM
    Exit 0      : Nothing to add, or all exclusions added
    Exit 1      : Add-MpPreference failed (tamper protection managed by MDM, or Defender not the active AV)
    Ninja setup : Monthly, and in the new-workstation baseline. Ticket on exit 1.
    Output      : Per vendor: skipped (not installed), or each path and process added. Then totals.
#>

# ---------------- CONFIG ----------------
# Detect = any of these paths existing means the vendor is present.
# Paths and Processes = exclusions to ensure. Wildcards are fine for paths.
$Vendors = @(
    @{ Name = 'Dentrix'
       Detect    = @('C:\Dentrix', 'C:\Program Files (x86)\Dentrix', 'C:\Program Files\Dentrix')
       Paths     = @('C:\Dentrix', 'C:\Program Files (x86)\Dentrix', 'C:\Program Files\Dentrix', 'C:\Program Files (x86)\Henry Schein', 'C:\ProgramData\Dentrix', 'C:\DXOne')
       Processes = @('Dentrix.exe', 'DentrixACEServer.exe', 'DDX.exe', 'DtxCommSrv.exe', 'Ledger.exe', 'Office.exe', 'Chart.exe', 'Appt.exe') }
    @{ Name = 'Eaglesoft'
       Detect    = @('C:\EagleSoft', 'C:\Program Files (x86)\Patterson', 'C:\Program Files\Patterson')
       Paths     = @('C:\EagleSoft', 'C:\Program Files (x86)\Patterson', 'C:\Program Files\Patterson', 'C:\Program Files (x86)\Sybase', 'C:\Program Files\Sybase', 'C:\Program Files (x86)\SQL Anywhere*', 'C:\Program Files\SQL Anywhere*')
       Processes = @('Eaglesoft.exe', 'dbsrv9.exe', 'dbsrv11.exe', 'dbsrv12.exe', 'dbsrv16.exe', 'dbsrv17.exe', 'dbeng17.exe', 'PattersonServerStatus.exe') }
    @{ Name = 'Open Dental'
       Detect    = @('C:\OpenDental', 'C:\Program Files (x86)\Open Dental', 'C:\Program Files\Open Dental')
       Paths     = @('C:\OpenDental', 'C:\Program Files (x86)\Open Dental', 'C:\Program Files\Open Dental', 'C:\OpenDentImages', 'C:\mysql', 'C:\Program Files\MariaDB*', 'C:\Program Files\MySQL*', 'C:\MariaBackupFiles')
       Processes = @('OpenDental.exe', 'OpenDentalService.exe', 'OpenDentalEConnector.exe', 'mysqld.exe', 'mariadbd.exe', 'mariabackup.exe') }
    @{ Name = 'DEXIS'
       Detect    = @('C:\DEXIS', 'C:\Program Files (x86)\DEXIS', 'C:\Program Files\DEXIS')
       Paths     = @('C:\DEXIS', 'C:\Program Files (x86)\DEXIS', 'C:\Program Files\DEXIS', 'C:\DEXISData', 'C:\ProgramData\DEXIS')
       Processes = @('DEXIS.exe', 'DEXISServer.exe', 'DEXISImagingSuite.exe', 'DxImagingServer.exe') }
    @{ Name = 'Sidexis'
       Detect    = @('C:\Program Files\Sirona', 'C:\Program Files (x86)\Sirona', 'C:\PDATA')
       Paths     = @('C:\Program Files\Sirona', 'C:\Program Files (x86)\Sirona', 'C:\PDATA', 'C:\SIDEXIS', 'C:\ProgramData\Sirona')
       Processes = @('Sidexis.exe', 'SIDEXIS4.exe', 'SiXServer.exe', 'SIDEXISNGService.exe') }
    @{ Name = 'Carestream'
       Detect    = @('C:\Program Files\Carestream', 'C:\Program Files (x86)\Carestream', 'C:\CSData')
       Paths     = @('C:\Program Files\Carestream', 'C:\Program Files (x86)\Carestream', 'C:\CSData', 'C:\ProgramData\Carestream')
       Processes = @('CSImaging.exe', 'KodakDental.exe', 'CSAcquisition.exe') }
    @{ Name = 'SOTA Image'
       Detect    = @('C:\Program Files (x86)\SOTA Image', 'C:\Program Files\SOTA Image', 'C:\SOTA')
       Paths     = @('C:\Program Files (x86)\SOTA Image', 'C:\Program Files\SOTA Image', 'C:\SOTA', 'C:\ProgramData\SOTA')
       Processes = @('SOTAImage.exe', 'TwainNative.exe') }
)
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$exitCode = 0
Write-Output "=== Defender exclusions on $env:COMPUTERNAME ==="

$status = Get-MpComputerStatus -ErrorAction SilentlyContinue
if (-not $status -or -not $status.AMServiceEnabled) {
    Write-Output "Defender AM service not running. Another AV is likely active. Nothing to do."
    exit 0
}
$pref = Get-MpPreference -ErrorAction SilentlyContinue
$curPaths = @($pref.ExclusionPath)
$curProcs = @($pref.ExclusionProcess)
$addedPaths = 0
$addedProcs = 0

foreach ($v in $Vendors) {
    $present = $false
    foreach ($d in $v.Detect) { if (Test-Path $d) { $present = $true; break } }
    if (-not $present) { Write-Output "  $($v.Name): not installed, skipped"; continue }
    Write-Output "  $($v.Name): installed"

    foreach ($p in $v.Paths) {
        if ($curPaths -contains $p) { continue }
        try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop; Write-Output "    + path    $p"; $addedPaths++ }
        catch { Write-Output "    FAILED path $p : $($_.Exception.Message)"; $exitCode = 1 }
    }
    foreach ($e in $v.Processes) {
        if ($curProcs -contains $e) { continue }
        try { Add-MpPreference -ExclusionProcess $e -ErrorAction Stop; Write-Output "    + process $e"; $addedProcs++ }
        catch { Write-Output "    FAILED process $e : $($_.Exception.Message)"; $exitCode = 1 }
    }
}

Write-Output "Added $addedPaths path and $addedProcs process exclusion(s)."
if ($exitCode -eq 0) { Write-Output "RESULT: Exclusions in place." } else { Write-Output "RESULT: One or more exclusions could not be added. Check tamper protection and MDM policy." }
exit $exitCode
