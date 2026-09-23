<#
.SYNOPSIS
    Records the machine's network configuration and flags DNS servers that aren't expected.
.DESCRIPTION
    Read-only. Captures the active adapter's IP, gateway, DNS servers, MAC, link speed, DHCP or
    static, plus public IP and ISP. Compares DNS servers against an expected list. Unexpected DNS
    on a managed machine is either a misconfiguration or a tamper indicator, and it's the first
    thing an ISP or vendor call asks for.
.NOTES
    Run context : SYSTEM
    Exit 0      : Recorded. Exit 1 only if $TicketOnUnexpectedDns and DNS doesn't match.
    Ninja setup : Weekly, or on a network-change condition. Writes custom field netBaseline.
    Output      : Adapter block, public IP and ISP, DNS verdict.
    Network     : Public IP lookup uses api.ipify.org and ip-api.com over HTTPS. Set $LookupPublic
                  to $false on sites that block outbound to unknown hosts.
#>

# ---------------- CONFIG ----------------
# DNS servers that are acceptable. Leave empty to skip the check. Wildcards allowed.
# Typical: the site's gateway, the DC, a Pi-hole, or the UniFi gateway.
$ExpectedDnsServers    = @()          # e.g. @('192.168.1.1', '192.168.1.10', '10.*')
$TicketOnUnexpectedDns = $false
$LookupPublic          = $true
$CustomField           = 'netBaseline'
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$exitCode = 0
Write-Output "=== Network baseline on $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm') ==="

$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
if (-not $route) { Write-Output "RESULT: No default route. Machine is offline."; exit 0 }
$ifIndex = $route.InterfaceIndex
$adapter = Get-NetAdapter -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue
$ip      = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object PrefixOrigin -ne 'WellKnown' | Select-Object -First 1
$ipcfg   = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
$dns     = (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
$domain  = (Get-CimInstance Win32_ComputerSystem).Domain

Write-Output "  Adapter   : $($adapter.Name) ($($adapter.InterfaceDescription))"
Write-Output "  MAC       : $($adapter.MacAddress)"
Write-Output "  Link      : $($adapter.LinkSpeed) $($adapter.Status)"
Write-Output "  IPv4      : $($ip.IPAddress)/$($ip.PrefixLength) ($($ipcfg.Dhcp))"
Write-Output "  Gateway   : $($route.NextHop)"
Write-Output "  DNS       : $($dns -join ', ')"
Write-Output "  Domain    : $domain"

$publicIp = ''; $isp = ''
if ($LookupPublic) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $publicIp = (Invoke-RestMethod 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
        $geo = Invoke-RestMethod "http://ip-api.com/json/$publicIp?fields=isp,org,city,regionName" -TimeoutSec 10
        $isp = "$($geo.isp) ($($geo.city), $($geo.regionName))"
    } catch { Write-Output "  Public IP : lookup failed ($($_.Exception.Message))" }
    if ($publicIp) { Write-Output "  Public IP : $publicIp"; Write-Output "  ISP       : $isp" }
}

# DNS check
$dnsVerdict = 'not checked'
if ($ExpectedDnsServers.Count -gt 0 -and $dns) {
    $unexpected = @()
    foreach ($d in $dns) {
        $ok = $false
        foreach ($e in $ExpectedDnsServers) { if ($d -like $e) { $ok = $true; break } }
        if (-not $ok) { $unexpected += $d }
    }
    if ($unexpected) {
        $dnsVerdict = "UNEXPECTED: $($unexpected -join ', ')"
        Write-Output "  DNS check : $dnsVerdict"
        if ($TicketOnUnexpectedDns) { $exitCode = 1 }
    } else { $dnsVerdict = 'ok'; Write-Output "  DNS check : ok" }
}

$field = "$($ip.IPAddress) gw $($route.NextHop) dns $($dns -join '/') $($ipcfg.Dhcp) | pub $publicIp $isp | dns $dnsVerdict"
if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) { try { Ninja-Property-Set $CustomField $field } catch {} }

if ($exitCode -eq 0) { Write-Output "RESULT: Recorded." } else { Write-Output "RESULT: DNS does not match expected servers." }
exit $exitCode
