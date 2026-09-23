<#
.SYNOPSIS
    Resets the Windows Update client when it's stuck in a download or install loop.
.DESCRIPTION
    Stops the update services, renames SoftwareDistribution and catroot2 with a timestamp
    (never deletes, so a bad reset is reversible), restarts the services, and kicks off a scan.
    Old .bak folders from earlier resets are cleaned up after $KeepBakDays.
    Run on demand, not on a schedule. If updates fail again after this, the problem is the
    package or the servicing stack, not the client cache.
.NOTES
    Run context : SYSTEM
    Exit 0      : Reset complete, scan started
    Exit 1      : A service would not stop or start -> manual review
    Ninja setup : On demand. Pair with a reboot at the next window. SoftwareDistribution.bak can
                  be several GB, the weekly cleanup or $KeepBakDays clears it.
#>

# ---------------- CONFIG ----------------
$KeepBakDays  = 7
$ResetWinsock = $false    # only if downloads fail with network errors. Needs a reboot.
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$exitCode = 0
$services = 'wuauserv', 'bits', 'cryptsvc', 'msiserver', 'usosvc', 'dosvc'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
Write-Output "=== Windows Update reset on $env:COMPUTERNAME ==="

# Stop
foreach ($s in $services) {
    $svc = Get-Service $s -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    try {
        Stop-Service $s -Force -ErrorAction Stop
        $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 60))
        Write-Output "  stopped $s"
    } catch {
        Write-Output "  could not stop $s : $($_.Exception.Message)"
        if ($s -in 'wuauserv','bits','cryptsvc') { $exitCode = 1 }
    }
}
if ($exitCode -ne 0) { Write-Output "RESULT: Core service would not stop. Reboot and retry."; exit 1 }

# Clear any stuck BITS jobs
try { Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue } catch {}

# Rename caches
foreach ($p in "$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2") {
    if (Test-Path $p) {
        try { Rename-Item $p "$p.bak_$stamp" -ErrorAction Stop; Write-Output "  renamed $p -> .bak_$stamp" }
        catch { Write-Output "  could not rename $p : $($_.Exception.Message)"; $exitCode = 1 }
    }
}

# Old backups from previous resets
foreach ($old in Get-ChildItem "$env:SystemRoot" -Directory -Filter 'SoftwareDistribution.bak_*' -ErrorAction SilentlyContinue) {
    if ($old.LastWriteTime -lt (Get-Date).AddDays(-$KeepBakDays)) { Remove-Item $old.FullName -Recurse -Force -ErrorAction SilentlyContinue; Write-Output "  removed old $($old.Name)" }
}
foreach ($old in Get-ChildItem "$env:SystemRoot\System32" -Directory -Filter 'catroot2.bak_*' -ErrorAction SilentlyContinue) {
    if ($old.LastWriteTime -lt (Get-Date).AddDays(-$KeepBakDays)) { Remove-Item $old.FullName -Recurse -Force -ErrorAction SilentlyContinue; Write-Output "  removed old $($old.Name)" }
}

if ($ResetWinsock) { netsh winsock reset | Out-Null; Write-Output "  winsock reset (reboot needed)" }

# Start
foreach ($s in $services) {
    $svc = Get-Service $s -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.StartType -eq 'Disabled') { continue }
    try { Start-Service $s -ErrorAction Stop; Write-Output "  started $s" }
    catch {
        Write-Output "  could not start $s : $($_.Exception.Message)"
        if ($s -in 'wuauserv','bits','cryptsvc') { $exitCode = 1 }
    }
}

# Kick a scan
try { Start-Process UsoClient.exe -ArgumentList 'StartScan' -WindowStyle Hidden -ErrorAction SilentlyContinue; Write-Output "  scan started" } catch {}

if ($exitCode -eq 0) { Write-Output "RESULT: Reset complete. Retry the update, reboot at the next window." } else { Write-Output "RESULT: Reset incomplete. Manual review." }
exit $exitCode
