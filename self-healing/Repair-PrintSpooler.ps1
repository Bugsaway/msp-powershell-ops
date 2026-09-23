<#
.SYNOPSIS
    Ensures the Print Spooler is running and (optionally) clears stuck jobs.
.DESCRIPTION
    Verifies the spooler is set to Automatic and running; starts it if stopped and
    hard-recovers (purge queue + restart) if it won't start. Optionally clears jobs
    stuck in an Error/Blocked state beyond a time limit.
.NOTES
    Run context : SYSTEM
    Exit 0      : Spooler healthy (already running, or successfully restarted)
    Exit 1      : Spooler could not be started -> create ticket
    Ninja setup : Pair with a native "Service: Print Spooler not running" condition,
                  or schedule every 15-30 min. Ticket on exit 1.
#>

# ---------------- CONFIG ----------------
$ClearStuckJobs    = $true   # Remove jobs stuck in Error/Blocked state
$StuckMinutes      = 15      # A job is "stuck" if older than this AND errored
$ClearAllOnRestart = $false  # If spooler had to be force-restarted, purge the queue folder
# ----------------------------------------

$queuePath = "$env:windir\System32\spool\PRINTERS\*"

$svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
if (-not $svc) { Write-Output "Spooler service not found."; exit 1 }

# Ensure Automatic startup
try { Set-Service -Name Spooler -StartupType Automatic -ErrorAction SilentlyContinue } catch {}

$restarted = $false
if ($svc.Status -ne 'Running') {
    Write-Output "Spooler is $($svc.Status). Starting..."
    try {
        Start-Service -Name Spooler -ErrorAction Stop
        Start-Sleep -Seconds 3
        $restarted = $true
    }
    catch {
        Write-Output "Failed to start spooler: $($_.Exception.Message). Attempting hard recovery..."
        try {
            Stop-Service Spooler -Force -ErrorAction SilentlyContinue
            Get-ChildItem $queuePath -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Start-Service Spooler -ErrorAction Stop
            $restarted = $true
        }
        catch {
            Write-Output "RESULT: Spooler could not be started."
            exit 1
        }
    }
}

# Re-check
if ((Get-Service Spooler).Status -ne 'Running') {
    Write-Output "RESULT: Spooler still not running."
    exit 1
}

# Optional: purge the queue folder if we had to restart it
if ($restarted -and $ClearAllOnRestart) {
    Stop-Service Spooler -Force -ErrorAction SilentlyContinue
    Get-ChildItem $queuePath -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Start-Service Spooler -ErrorAction SilentlyContinue
    Write-Output "Queue folder purged after restart."
}

# Optional: clear individual stuck jobs (requires PrintManagement module)
if ($ClearStuckJobs -and (Get-Module -ListAvailable -Name PrintManagement)) {
    try {
        $cutoff  = (Get-Date).AddMinutes(-$StuckMinutes)
        $cleared = 0
        foreach ($printer in (Get-Printer -ErrorAction SilentlyContinue)) {
            $jobs = Get-PrintJob -PrinterName $printer.Name -ErrorAction SilentlyContinue
            foreach ($j in $jobs) {
                $bad = $j.JobStatus -match 'Error|Blocked'
                $old = ($null -ne $j.SubmittedTime -and $j.SubmittedTime -lt $cutoff)
                if ($bad -and $old) {
                    Remove-PrintJob -InputObject $j -ErrorAction SilentlyContinue
                    Write-Output "Cleared stuck job '$($j.DocumentName)' on $($printer.Name)"
                    $cleared++
                }
            }
        }
        if ($cleared -gt 0) { Write-Output "Cleared $cleared stuck job(s)." }
    }
    catch { Write-Output "Stuck-job cleanup error: $($_.Exception.Message)" }
}

Write-Output "RESULT: Spooler healthy."
exit 0
