<#
.SYNOPSIS
    Reports SMBv1 state and who is actually using it. Changes nothing.
.DESCRIPTION
    SMBv1 enabled is a HIPAA finding, but some older pano, CBCT, and scanner boxes still
    speak it. This tells you whether it's on, and whether anything is talking over it,
    so you know what breaks before you disable it.
.NOTES
    Run context : SYSTEM
    Exit 0      : Report written (default). Set $TicketIfEnabled to exit 1 when SMB1 is on.
    Ninja setup : Monthly. Writes custom field smb1Status if present.
#>

# ---------------- CONFIG ----------------
$TicketIfEnabled = $false
$CustomField     = 'smb1Status'
# ----------------------------------------

$ErrorActionPreference = 'Continue'
Write-Output "=== SMBv1 status on $env:COMPUTERNAME ==="

$serverOn = $null
try { $serverOn = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol } catch {}
$feature = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
$clientFeature = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol-Client -ErrorAction SilentlyContinue
$serverFeature = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol-Server -ErrorAction SilentlyContinue
$mrxsmb10 = Get-Service mrxsmb10 -ErrorAction SilentlyContinue

Write-Output "  Server config EnableSMB1Protocol : $serverOn"
Write-Output "  Feature SMB1Protocol             : $($feature.State)"
Write-Output "  Feature SMB1Protocol-Client      : $($clientFeature.State)"
Write-Output "  Feature SMB1Protocol-Server      : $($serverFeature.State)"
Write-Output "  Driver mrxsmb10                  : $(if ($mrxsmb10) { $mrxsmb10.Status } else { 'not present' })"

# Who is connecting to us over SMB1
$inbound = Get-SmbSession -ErrorAction SilentlyContinue | Where-Object { $_.Dialect -and [version]$_.Dialect -lt [version]'2.0' }
if ($inbound) {
    Write-Output "  Inbound SMB1 sessions:"
    $inbound | ForEach-Object { Write-Output "    $($_.ClientComputerName) as $($_.ClientUserName) dialect $($_.Dialect)" }
} else { Write-Output "  Inbound SMB1 sessions            : none" }

# Where we connect out over SMB1
$outbound = Get-SmbConnection -ErrorAction SilentlyContinue | Where-Object { $_.Dialect -and [version]$_.Dialect -lt [version]'2.0' }
if ($outbound) {
    Write-Output "  Outbound SMB1 connections:"
    $outbound | ForEach-Object { Write-Output "    \\$($_.ServerName)\$($_.ShareName) dialect $($_.Dialect)" }
} else { Write-Output "  Outbound SMB1 connections        : none" }

$enabled = ($serverOn -eq $true) -or ($feature.State -eq 'Enabled') -or ($clientFeature.State -eq 'Enabled') -or ($serverFeature.State -eq 'Enabled')
$inUse   = [bool]($inbound -or $outbound)
$status  = if (-not $enabled) { 'disabled' } elseif ($inUse) { 'enabled, IN USE' } else { 'enabled, idle' }

if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) { try { Ninja-Property-Set $CustomField $status } catch {} }

Write-Output "RESULT: SMBv1 $status"
if ($enabled -and $TicketIfEnabled) { exit 1 }
exit 0
