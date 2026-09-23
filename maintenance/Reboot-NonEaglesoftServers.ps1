<#
.SYNOPSIS
    Reboots the server ONLY if no Eaglesoft server components are running.
.DESCRIPTION
    Intended for NinjaOne scheduled deployment (run as SYSTEM).
    Detection layers:
      1. Running services matching Eaglesoft / Patterson / SQL Anywhere (SQLANYs_*) patterns
      2. Running processes: Eaglesoft.exe, or dbsrv*.exe (Sybase engine) whose command line
         references Patterson/Eaglesoft
    If any layer hits, the script logs the finding and exits WITHOUT rebooting.
.NOTES
    Exit 0 = reboot initiated OR safely skipped (both are expected outcomes)
    Exit 1 = script error
#>

$ErrorActionPreference = 'Stop'
$RebootDelaySeconds = 60

function Test-EaglesoftRunning {
    $hits = @()

    # --- Layer 1: Running services ---
    $svcPatterns = @('*Eaglesoft*', '*Patterson*', 'SQLANYs_*')
    foreach ($pattern in $svcPatterns) {
        $svcs = Get-Service | Where-Object {
            $_.Status -eq 'Running' -and
            ($_.Name -like $pattern -or $_.DisplayName -like $pattern)
        }
        foreach ($s in $svcs) {
            $hits += "Service running: $($s.Name) ($($s.DisplayName))"
        }
    }

    # --- Layer 2: Running processes ---
    $esProc = Get-Process -Name 'Eaglesoft' -ErrorAction SilentlyContinue
    if ($esProc) { $hits += "Process running: Eaglesoft.exe (PID $($esProc.Id -join ','))" }

    # Sybase SQL Anywhere engine (dbsrv9/11/12/16/17) - confirm it's the Patterson DB
    $dbProcs = Get-CimInstance Win32_Process -Filter "Name LIKE 'dbsrv%'" -ErrorAction SilentlyContinue
    foreach ($p in $dbProcs) {
        if ($p.CommandLine -match '(?i)patterson|eaglesoft|pattersonpms') {
            $hits += "Process running: $($p.Name) (PID $($p.ProcessId)) - Patterson/Eaglesoft DB engine"
        }
        else {
            # Unidentified Sybase engine on a dental server - treat as a hit out of caution
            $hits += "Process running: $($p.Name) (PID $($p.ProcessId)) - unidentified SQL Anywhere engine (excluded out of caution)"
        }
    }

    return $hits
}

try {
    $hostname = $env:COMPUTERNAME
    Write-Output "=== Eaglesoft-aware reboot check on $hostname - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

    $eaglesoftHits = Test-EaglesoftRunning

    if ($eaglesoftHits.Count -gt 0) {
        Write-Output "RESULT: SKIPPED - Eaglesoft components detected running:"
        $eaglesoftHits | ForEach-Object { Write-Output "  - $_" }
        Write-Output "No reboot performed."
        exit 0
    }

    Write-Output "RESULT: No Eaglesoft components running. Initiating reboot in $RebootDelaySeconds seconds."
    shutdown.exe /r /t $RebootDelaySeconds /c "Scheduled maintenance reboot via NinjaOne (no Eaglesoft detected)" /d p:4:1
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}
