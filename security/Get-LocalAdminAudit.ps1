<#
.SYNOPSIS
    Audits local Administrators membership and flags anything unexpected.
.DESCRIPTION
    Lists every member of the local Administrators group, including orphaned SIDs that
    Get-LocalGroupMember chokes on, and compares against the expected list.
.NOTES
    Run context : SYSTEM
    Exit 0      : Membership matches expectations
    Exit 1      : Unexpected member or orphaned SID -> ticket
    Ninja setup : Weekly. Ticket on exit 1. Writes the member list to custom field localAdmins if present.
#>

# ---------------- CONFIG ----------------
# Names expected in Administrators. Domain accounts as DOMAIN\Name or just Name. Case-insensitive.
$ExpectedMembers = @('Administrator', 'Domain Admins', 'Enterprise Admins')   # add the local admin accounts in use
$FlagOrphanedSids = $true
$CustomField      = 'localAdmins'
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$members = @()

# ADSI enumerates orphaned SIDs where Get-LocalGroupMember throws
try {
    $group = [ADSI]"WinNT://./Administrators,group"
    foreach ($m in $group.psbase.Invoke('Members')) {
        $name = $m.GetType().InvokeMember('Name', 'GetProperty', $null, $m, $null)
        $path = $m.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $m, $null)
        $cls  = $m.GetType().InvokeMember('Class', 'GetProperty', $null, $m, $null)
        $src  = ($path -replace '^WinNT://', '' -split '/')[0]
        $members += [pscustomobject]@{ Name = $name; Source = $src; Class = $cls; Orphaned = ($name -match '^S-1-5-21-') }
    }
}
catch {
    Write-Output "ADSI enumeration failed, falling back: $($_.Exception.Message)"
    foreach ($m in Get-LocalGroupMember Administrators -ErrorAction SilentlyContinue) {
        $members += [pscustomobject]@{ Name = ($m.Name -split '\\')[-1]; Source = $m.PrincipalSource; Class = $m.ObjectClass; Orphaned = $false }
    }
}

Write-Output "=== Local Administrators on $env:COMPUTERNAME ==="
$unexpected = @()
foreach ($m in $members) {
    $ok = $false
    foreach ($e in $ExpectedMembers) {
        $short = ($e -split '\\')[-1]
        if ($m.Name -ieq $short) { $ok = $true; break }
    }
    if ($m.Orphaned) { $ok = -not $FlagOrphanedSids }
    $tag = if ($ok) { 'ok      ' } else { 'UNEXPECTED' }
    Write-Output ("  {0} {1}\{2} ({3})" -f $tag, $m.Source, $m.Name, $m.Class)
    if (-not $ok) { $unexpected += "$($m.Source)\$($m.Name)" }
}

if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
    try { Ninja-Property-Set $CustomField (($members | ForEach-Object { "$($_.Source)\$($_.Name)" }) -join ', ') } catch {}
}

if ($unexpected) {
    Write-Output "RESULT: $($unexpected.Count) unexpected admin(s): $($unexpected -join ', ')"
    exit 1
}
Write-Output "RESULT: Administrators membership as expected."
exit 0
