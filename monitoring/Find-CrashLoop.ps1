<#
.SYNOPSIS
    Detects services and applications crash-looping and flooding the event logs.
.DESCRIPTION
    Counts service crash events (System 7031, 7034, 7024) and application crashes
    (Application 1000, 1026) over the last window, grouped by offender. Anything over the
    threshold is reported. Also checks how many days of history System and Application
    are holding, since a crash loop rolls the logs and destroys the evidence you'd want later.
.NOTES
    Run context : SYSTEM
    Exit 0      : Nothing over threshold
    Exit 1      : Crash loop found, or logs rolling under the retention floor -> ticket
    Ninja setup : Hourly. Ticket on exit 1.
    Output      : Offender type, name, count, event IDs, and service ImagePath. Days of history
                  held per log with percent full.
#>

# ---------------- CONFIG ----------------
$WindowMinutes     = 60
$MaxPerWindow      = 5      # crashes of one offender in the window before it's a loop
$MinRetentionDays  = 7      # ticket if System or Application holds less than this
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$since = (Get-Date).AddMinutes(-$WindowMinutes)
$exitCode = 0
Write-Output "=== Crash loop check on $env:COMPUTERNAME, last $WindowMinutes min ==="

$offenders = @()

# Service crashes: 7031 terminated unexpectedly, 7034 terminated unexpectedly (no recovery), 7024 terminated with error
$svcEvents = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager'; Id=7031,7034,7024; StartTime=$since } -ErrorAction SilentlyContinue
if ($svcEvents) {
    $svcEvents | Group-Object { [string]$_.Properties[0].Value } | Where-Object Count -ge $MaxPerWindow | ForEach-Object {
        $offenders += [pscustomobject]@{ Type='service'; Name=$_.Name; Count=$_.Count; Ids=(($_.Group.Id | Sort-Object -Unique) -join ',') }
    }
}

# Application crashes: 1000 app error, 1026 .NET unhandled exception
$appEvents = Get-WinEvent -FilterHashtable @{ LogName='Application'; Id=1000,1026; StartTime=$since } -ErrorAction SilentlyContinue
if ($appEvents) {
    $appEvents | Group-Object {
        if ($_.Id -eq 1000) { [string]$_.Properties[0].Value }
        else { if ($_.Message -match 'Application: (\S+)') { $matches[1] } else { 'unknown .NET app' } }
    } | Where-Object Count -ge $MaxPerWindow | ForEach-Object {
        $offenders += [pscustomobject]@{ Type='application'; Name=$_.Name; Count=$_.Count; Ids=(($_.Group.Id | Sort-Object -Unique) -join ',') }
    }
}

if ($offenders) {
    Write-Output "Crash loops:"
    foreach ($o in $offenders) {
        Write-Output ("  {0,-12} {1,-40} {2,4} in {3} min (event {4})" -f $o.Type, $o.Name, $o.Count, $WindowMinutes, $o.Ids)
        # Who manages it. nssm or a wrapper means the restart is coming from outside SCM recovery.
        $svc = Get-CimInstance Win32_Service -Filter "Name='$($o.Name)' OR DisplayName='$($o.Name)'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($svc) { Write-Output "               path: $($svc.PathName)" }
    }
    $exitCode = 1
} else {
    Write-Output "  No crash loops."
}

# Log retention check
foreach ($log in 'System','Application') {
    $oldest = Get-WinEvent -LogName $log -Oldest -MaxEvents 1 -ErrorAction SilentlyContinue
    $cfg = Get-WinEvent -ListLog $log -ErrorAction SilentlyContinue
    if ($oldest -and $cfg) {
        $days = [math]::Round(((Get-Date) - $oldest.TimeCreated).TotalDays, 1)
        $full = [math]::Round(($cfg.FileSize / $cfg.MaximumSizeInBytes) * 100)
        Write-Output "  $log holds $days days ($full% of $([int]($cfg.MaximumSizeInBytes/1MB)) MB)"
        if ($days -lt $MinRetentionDays -and $full -ge 90) {
            Write-Output "    Rolling under $MinRetentionDays days. Something is flooding it."
            $exitCode = 1
        }
    }
}

if ($exitCode -eq 0) { Write-Output "RESULT: Healthy." } else { Write-Output "RESULT: Review required." }
exit $exitCode
