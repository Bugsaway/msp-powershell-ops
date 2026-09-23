<#
.SYNOPSIS
    Ensures the Windows Time service is healthy and the clock is synced within tolerance.
.DESCRIPTION
    Verifies W32Time is running/Automatic, forces a resync, then measures the offset.
    Domain-joined machines sync via the domain hierarchy; workgroup machines use
    public NTP. Domain Controllers are skipped to avoid breaking the time hierarchy.
.NOTES
    Run context : SYSTEM
    Exit 0      : Clock within tolerance (or successfully resynced)
    Exit 1      : Still out of tolerance / service unhealthy / source unreachable -> ticket
    Ninja setup : Schedule daily. Ticket on exit 1 (usually blocked UDP 123 or a sick
                  time source).
#>

# ---------------- CONFIG ----------------
$ToleranceSeconds = 120
$WorkgroupPeers   = 'time.windows.com,0x9 pool.ntp.org,0x9'
# ----------------------------------------

$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -eq 2) {
    Write-Output "Domain Controller detected. Skipping (DC is the time authority)."
    exit 0
}

# Ensure W32Time running + Automatic
try {
    Set-Service w32time -StartupType Automatic -ErrorAction SilentlyContinue
    $w = Get-Service w32time -ErrorAction Stop
    if ($w.Status -ne 'Running') { Start-Service w32time -ErrorAction Stop; Start-Sleep 2 }
}
catch {
    Write-Output "Could not start W32Time: $($_.Exception.Message)"
    exit 1
}

$domainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain

# Configure source appropriately
if ($domainJoined) {
    & w32tm /config /syncfromflags:domhier /update | Out-Null
}
else {
    & w32tm /config /manualpeerlist:"$WorkgroupPeers" /syncfromflags:manual /reliable:no /update | Out-Null
}
Restart-Service w32time -ErrorAction SilentlyContinue
Start-Sleep 2

# Force resync
& w32tm /resync /rediscover /force | Out-Null
Start-Sleep 3

function Get-ClockOffset {
    $source = if ($domainJoined) { ((& w32tm /query /source) | Select-Object -First 1) } else { 'time.windows.com' }
    if (-not $source -or $source -match 'Local CMOS|Free-running') { $source = 'time.windows.com' }
    $out = & w32tm /stripchart /computer:$source /dataonly /samples:1 2>$null
    foreach ($line in $out) {
        if ($line -match '([+-]?\d+\.\d+)s') { return [double]$matches[1] }
    }
    return $null
}

$offset = Get-ClockOffset
if ($null -eq $offset) {
    Write-Output "Could not measure time offset (source unreachable / UDP 123 blocked?)."
    Write-Output "RESULT: Resync forced but offset unverifiable."
    exit 1
}

$absOffset = [math]::Abs($offset)
Write-Output "Clock offset from source: $([math]::Round($offset,3))s (tolerance ${ToleranceSeconds}s)."

if ($absOffset -gt $ToleranceSeconds) {
    Write-Output "RESULT: Still out of tolerance after resync."
    exit 1
}
Write-Output "RESULT: Clock within tolerance."
exit 0
