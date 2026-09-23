<#
.SYNOPSIS
    Raises event log sizes so investigations have more than a day of history.
.DESCRIPTION
    Detect-first. Reads each log's current max size and only raises it when it's under target.
    Never shrinks. Also turns on Task Scheduler Operational history, which is off by default
    and is what Find-ServiceTaskCulprit needs.
.NOTES
    Run context : SYSTEM
    Exit 0      : All logs at or above target
    Exit 1      : wevtutil failed on a log -> ticket
    Ninja setup : Monthly, or once at onboarding. Default sizes on a busy domain controller
                  can hold under two days of Security log.
    Output      : Per log: ok, raised (old -> new MB), enabled, or FAILED. Then days of
                  history currently held in System, Application, and Security.
#>

# ---------------- CONFIG ----------------
$Targets = @{
    'System'                                        = 256MB
    'Application'                                   = 256MB
    'Security'                                      = 1GB
    'Microsoft-Windows-PowerShell/Operational'      = 256MB
    'Microsoft-Windows-TaskScheduler/Operational'   = 128MB
    'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' = 128MB
}
$SecurityOnDC = 2GB
$EnableLogs   = @('Microsoft-Windows-TaskScheduler/Operational')
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$exitCode = 0
$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -eq 2) { $Targets['Security'] = $SecurityOnDC }

Write-Output "=== Event log sizes on $env:COMPUTERNAME ==="
foreach ($log in $Targets.Keys) {
    $target = [int64]$Targets[$log]
    $cfg = Get-WinEvent -ListLog $log -ErrorAction SilentlyContinue
    if (-not $cfg) { Write-Output "  skip     $log (not present)"; continue }
    $cur = $cfg.MaximumSizeInBytes
    if ($cur -ge $target) {
        Write-Output ("  ok       {0} {1} MB" -f $log, [int]($cur/1MB))
        continue
    }
    & wevtutil.exe sl "$log" /ms:$target 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Output ("  raised   {0} {1} MB -> {2} MB" -f $log, [int]($cur/1MB), [int]($target/1MB))
    } else {
        Write-Output "  FAILED   $log (wevtutil exit $LASTEXITCODE)"
        $exitCode = 1
    }
}

foreach ($log in $EnableLogs) {
    $cfg = Get-WinEvent -ListLog $log -ErrorAction SilentlyContinue
    if ($cfg -and -not $cfg.IsEnabled) {
        & wevtutil.exe sl "$log" /e:true 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Output "  enabled  $log" } else { Write-Output "  FAILED   enable $log"; $exitCode = 1 }
    }
}

# How much history are we actually holding right now
foreach ($log in 'System','Application','Security') {
    $oldest = Get-WinEvent -LogName $log -Oldest -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($oldest) {
        $days = [math]::Round(((Get-Date) - $oldest.TimeCreated).TotalDays, 1)
        Write-Output "  history  $log holds $days days"
        if ($days -lt 7) { Write-Output "           under 7 days. Something is flooding this log, run monitoring/Find-CrashLoop.ps1" }
    }
}

if ($exitCode -eq 0) { Write-Output "RESULT: Log sizes at target." } else { Write-Output "RESULT: One or more logs could not be set." }
exit $exitCode
