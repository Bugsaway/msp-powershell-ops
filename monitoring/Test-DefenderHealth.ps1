<#
.SYNOPSIS
    Checks that Microsoft Defender is on, current, and actually scanning.
.DESCRIPTION
    Read-only. Verifies the AM service, real-time protection, tamper protection, cloud-delivered
    protection, signature age, and last quick scan age. If a third-party AV is registered with
    Security Center, Defender in passive mode is expected and the script reports that instead
    of failing.
.NOTES
    Run context : SYSTEM
    Exit 0      : All checks pass, or third-party AV present and healthy
    Exit 1      : Any check fails -> ticket
    Ninja setup : Daily. Ticket on exit 1. Writes custom field defenderStatus.
    Output      : One line per check, PASS or FAIL with the value. Then a summary.
#>

# ---------------- CONFIG ----------------
$MaxSignatureAgeDays = 3
$MaxQuickScanAgeDays = 7
$RequireTamper       = $true
$RequireCloud        = $true
$CustomField         = 'defenderStatus'
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$fails = @()
Write-Output "=== Defender health on $env:COMPUTERNAME ==="

function Check { param([string]$Name, [bool]$Ok, [string]$Value)
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Output ("  {0} {1,-28} {2}" -f $tag, $Name, $Value)
    if (-not $Ok) { $script:fails += "$Name ($Value)" }
}

# Third-party AV on workstations shows in SecurityCenter2
$thirdParty = @()
$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -eq 1) {
    $thirdParty = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
        Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' }
}

$s = Get-MpComputerStatus -ErrorAction SilentlyContinue
$p = Get-MpPreference -ErrorAction SilentlyContinue

if ($thirdParty) {
    Write-Output "  Third-party AV: $(($thirdParty.displayName) -join ', ')"
    Check 'Third-party AV enabled' ([bool]($thirdParty | Where-Object { ($_.productState -band 0x1000) -ne 0 })) "productState $($thirdParty.productState -join ',')"
    Check 'Defender passive or off' ($null -eq $s -or -not $s.RealTimeProtectionEnabled) "RTP $($s.RealTimeProtectionEnabled)"
}
else {
    if (-not $s) { Check 'Defender status readable' $false 'Get-MpComputerStatus returned nothing' }
    else {
        Check 'AM service'              ($s.AMServiceEnabled -eq $true)             "$($s.AMServiceEnabled)"
        Check 'Antivirus enabled'       ($s.AntivirusEnabled -eq $true)             "$($s.AntivirusEnabled)"
        Check 'Real-time protection'    ($s.RealTimeProtectionEnabled -eq $true)    "$($s.RealTimeProtectionEnabled)"
        Check 'Behavior monitoring'     ($s.BehaviorMonitorEnabled -eq $true)       "$($s.BehaviorMonitorEnabled)"
        if ($RequireTamper) { Check 'Tamper protection' ($s.IsTamperProtected -eq $true) "$($s.IsTamperProtected)" }
        if ($RequireCloud)  { Check 'Cloud protection (MAPS)' ($p.MAPSReporting -ge 1) "MAPSReporting $($p.MAPSReporting)" }
        Check 'Signature age'           ($s.AntivirusSignatureAge -le $MaxSignatureAgeDays) "$($s.AntivirusSignatureAge) days (v$($s.AntivirusSignatureVersion))"
        Check 'Quick scan age'          ($s.QuickScanAge -le $MaxQuickScanAgeDays)  "$($s.QuickScanAge) days"
        Check 'Not in passive mode'     (-not $s.AMRunningMode -or $s.AMRunningMode -eq 'Normal') "$($s.AMRunningMode)"
    }
}

$summary = if ($fails) { "FAIL: $($fails -join ', ')" } elseif ($thirdParty) { "OK (third-party: $($thirdParty.displayName -join ','))" } else { "OK sig $($s.AntivirusSignatureAge)d scan $($s.QuickScanAge)d" }
if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) { try { Ninja-Property-Set $CustomField $summary } catch {} }

if ($fails) { Write-Output "RESULT: $($fails.Count) check(s) failed."; exit 1 }
Write-Output "RESULT: Defender healthy."
exit 0
