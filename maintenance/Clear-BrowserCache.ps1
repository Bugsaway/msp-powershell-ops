<#
.SYNOPSIS
    Kills Chrome and Edge, clears their disk caches for the current user, relaunches whichever was running.
.DESCRIPTION
    Runs in the USER context, not SYSTEM. It uses $env:LOCALAPPDATA, so under SYSTEM it
    would clear the wrong profile. In Ninja, run as "Current logged on user".
    Also stops Weave first since it holds a Chrome window open and blocks the cache delete.
    Cache_Data only. Cookies, sessions, passwords, and history are untouched.
    For the fleet-wide, all-users version run as SYSTEM, see Monthly-Super-Clean.ps1 step 6.
#>

$browsers = @(
    @{ Name = 'Chrome'; Process = 'chrome'; Exe = 'chrome'; Path = "$env:LOCALAPPDATA\Google\Chrome\User Data" }
    @{ Name = 'Edge';   Process = 'msedge'; Exe = 'msedge'; Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
)

# Weave keeps a Chrome window pinned, kill it first or the cache delete fails on locked files
Stop-Process -Name Weave -Force -ErrorAction SilentlyContinue

foreach ($b in $browsers) {
    $wasRunning = [bool](Get-Process -Name $b.Process -ErrorAction SilentlyContinue)
    Stop-Process -Name $b.Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (Test-Path $b.Path) {
        # Every profile folder (Default, Profile 1, ...), cache only
        Get-ChildItem $b.Path -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'Cache') } |
            ForEach-Object {
                Remove-Item (Join-Path $_.FullName 'Cache\*') -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $_.FullName 'Code Cache\*') -Recurse -Force -ErrorAction SilentlyContinue
                Write-Output "$($b.Name) cache cleared: $($_.Name)"
            }
    } else {
        Write-Output "$($b.Name) not installed for this user, skipped."
    }

    if ($wasRunning) { Start-Process $b.Exe -ErrorAction SilentlyContinue }
}
