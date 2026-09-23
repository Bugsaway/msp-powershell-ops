<#
.SYNOPSIS
    Starts Automatic services that are stopped and shouldn't be.
.DESCRIPTION
    Detect-first. Finds services with StartMode Auto and State not Running, skips the ones that
    legitimately idle (delayed start, trigger start, and a known-noise list), and starts the rest.
    A priority list of dental services is always checked first and reported by name.
.NOTES
    Run context : SYSTEM
    Exit 0      : Nothing stopped, or everything started
    Exit 1      : A service would not start -> ticket
    Ninja setup : Every 30 min on servers, hourly on workstations. Ticket on exit 1.
    Output      : Each service started with PRIORITY or auto tag and prior state. Failed
                  starts print the exception.
#>

# ---------------- CONFIG ----------------
# Dental and PM services that must be running whenever they exist on the box
$PriorityServices = @('DentrixACEServer', 'DDX', 'DtxCommSrv', 'Dentrix*', 'MySQL*', 'MariaDB*', 'SQLANYs_*',
                      'Eaglesoft*', 'Patterson*', 'DEXIS*', 'Sidexis*', 'Vatech*', 'Carestream*', 'CS Imaging*',
                      'Weave*', 'Open Dental*', 'OpenDental*')
# Auto services that stop on their own by design. Never start these.
$IgnoreServices = @('sppsvc', 'RemoteRegistry', 'MapsBroker', 'WbioSrvc', 'CDPSvc', 'BITS', 'wuauserv', 'TrustedInstaller',
                    'gupdate', 'gupdatem', 'edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService', 'GoogleUpdaterService*',
                    'GoogleUpdaterInternalService*', 'WSearch', 'TabletInputService', 'ShellHWDetection', 'SharedAccess',
                    'wscsvc', 'Themes', 'tiledatamodelsvc', 'WpnService', 'CDPUserSvc*', 'OneSyncSvc*', 'WMPNetworkSvc',
                    'NcbService', 'SgrmBroker', 'DoSvc', 'NetTcpPortSharing', 'PcaSvc', 'diagnosticshub*', 'ClickToRunSvc')
$StartTimeoutSec = 30
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$exitCode = 0

function Test-TriggerStart {
    param([string]$Name)
    Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name\TriggerInfo"
}
function Test-Match {
    param([string]$Name, [string]$Display, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Name -like $p -or $Display -like $p) { return $true } }
    return $false
}

Write-Output "=== Stopped auto services on $env:COMPUTERNAME ==="
$stopped = Get-CimInstance Win32_Service | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' }

$toStart = @()
foreach ($s in $stopped) {
    $priority = Test-Match $s.Name $s.DisplayName $PriorityServices
    if (-not $priority) {
        if (Test-Match $s.Name $s.DisplayName $IgnoreServices) { continue }
        if ($s.DelayedAutoStart) { continue }
        if (Test-TriggerStart $s.Name) { continue }
    }
    $toStart += [pscustomobject]@{ Name=$s.Name; Display=$s.DisplayName; State=$s.State; Priority=$priority }
}

if (-not $toStart) {
    Write-Output "RESULT: All auto services running."
    exit 0
}

foreach ($t in ($toStart | Sort-Object { -not $_.Priority }, Name)) {
    $tag = if ($t.Priority) { 'PRIORITY' } else { 'auto    ' }
    Write-Output "  $tag $($t.Name) ($($t.Display)) was $($t.State)"
    try {
        Start-Service -Name $t.Name -ErrorAction Stop
        (Get-Service $t.Name).WaitForStatus('Running', (New-TimeSpan -Seconds $StartTimeoutSec))
        Write-Output "           started"
    }
    catch {
        Write-Output "           FAILED: $($_.Exception.Message)"
        $exitCode = 1
    }
}

if ($exitCode -eq 0) { Write-Output "RESULT: Started $($toStart.Count) service(s)." } else { Write-Output "RESULT: One or more services would not start." }
exit $exitCode
