<#
.SYNOPSIS
    Monthly "super clean" - system health repair + aggressive cleanup (no reboot).
.DESCRIPTION
    Intended for NinjaOne monthly schedule (e.g., first Sunday, before the nightly
    reboot script). Run as SYSTEM. Combines system repair and heavy cleanup in one job.
    Steps:
      1. DISM /RestoreHealth        - repair the component store first
      2. SFC /scannow               - then verify/repair system files against the healthy store
      3. DISM component cleanup (no /ResetBase - update uninstall/rollback preserved)
      4. Online disk health scan (Repair-Volume) + spot-fix if issues found
      5. Full temp purge (all ages, in-use files skipped)
      6. Browser caches - Chrome/Edge Cache_Data only (cookies/sessions untouched)
      7. Delivery Optimization + WU download cache (full, not age-filtered)
.NOTES
    Runtime: 45-90 minutes typical. Set NinjaOne script timeout to 120 minutes.
    Pair with the nightly reboot script to flush anything pending (DISM 3010).
    Exit 0 = completed (per-step issues are logged, not fatal)
    Exit 1 = script error
#>

$ErrorActionPreference = 'Continue'
$script:BytesFreed = 0

function Remove-FilesIn {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) { return }
    $files = Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue
    $size = ($files | Measure-Object Length -Sum).Sum
    $count = 0
    foreach ($f in $files) {
        try { Remove-Item $f.FullName -Force -ErrorAction Stop; $count++ }
        catch { } # in-use files expected, skip
    }
    if ($size) { $script:BytesFreed += $size }
    Write-Output ("  {0}: removed {1} files ({2:N1} MB)" -f $Label, $count, ($size / 1MB))
}

function Invoke-Exe {
    param([string]$Exe, [string[]]$Arguments, [string]$Label)
    Write-Output "  Running: $Exe $($Arguments -join ' ')"
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    Write-Output "  $Label exit code: $($p.ExitCode)"
    return $p.ExitCode
}

try {
    $hostname = $env:COMPUTERNAME
    Write-Output "=== Monthly super clean on $hostname - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    $freeBefore = (Get-PSDrive C).Free

    # --- 1. DISM RestoreHealth (component store repair FIRST) ---
    Write-Output "[1/7] DISM RestoreHealth..."
    $dismRH = Invoke-Exe dism.exe @('/Online','/Cleanup-Image','/RestoreHealth') 'DISM RestoreHealth'
    if ($dismRH -notin 0, 3010) {
        Write-Output "  WARNING: RestoreHealth returned $dismRH - check C:\Windows\Logs\DISM\dism.log"
    }

    # --- 2. SFC scannow ---
    Write-Output "[2/7] SFC /scannow..."
    $sfc = Invoke-Exe "$env:SystemRoot\System32\sfc.exe" @('/scannow') 'SFC'
    switch ($sfc) {
        0       { Write-Output "  SFC: no integrity violations." }
        default { Write-Output "  SFC exit $sfc - review C:\Windows\Logs\CBS\CBS.log for repair details." }
    }

    # --- 3. Component store cleanup ---
    Write-Output "[3/7] DISM component cleanup (rollback preserved)..."
    Invoke-Exe dism.exe @('/Online','/Cleanup-Image','/StartComponentCleanup') 'Component cleanup' | Out-Null

    # --- 4. Disk health scan ---
    Write-Output "[4/7] Online disk health scan (C:)..."
    try {
        $scan = Repair-Volume -DriveLetter C -Scan -ErrorAction Stop
        Write-Output "  Scan result: $scan"
        if ("$scan" -ne 'NoErrorsFound') {
            Write-Output "  Issues found - running online spot-fix..."
            $fix = Repair-Volume -DriveLetter C -SpotFix -ErrorAction Stop
            Write-Output "  SpotFix result: $fix"
        }
    } catch {
        Write-Output "  Disk scan failed: $($_.Exception.Message)"
    }

    # --- 5. Full temp purge ---
    Write-Output "[5/7] Full temp purge (all ages)..."
    Remove-FilesIn -Path "$env:SystemRoot\Temp" -Label "Windows Temp"
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-FilesIn -Path (Join-Path $_.FullName "AppData\Local\Temp") -Label "Temp: $($_.Name)"
    }

    # --- 6. Browser caches (cache only - cookies/sessions untouched) ---
    Write-Output "[6/7] Browser caches (Chrome/Edge)..."
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $u = $_.FullName; $n = $_.Name
        foreach ($browser in @(
            @{ Label = "Chrome cache: $n"; Path = "$u\AppData\Local\Google\Chrome\User Data" },
            @{ Label = "Edge cache: $n";   Path = "$u\AppData\Local\Microsoft\Edge\User Data" }
        )) {
            if (Test-Path $browser.Path) {
                Get-ChildItem $browser.Path -Directory -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path (Join-Path $_.FullName 'Cache\Cache_Data') } |
                    ForEach-Object {
                        Remove-FilesIn -Path (Join-Path $_.FullName 'Cache\Cache_Data') -Label "$($browser.Label) [$($_.Name)]"
                    }
            }
        }
    }

    # --- 7. WU + Delivery Optimization caches (full) ---
    Write-Output "[7/7] Windows Update + Delivery Optimization caches..."
    try {
        Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
        Remove-FilesIn -Path "$env:SystemRoot\SoftwareDistribution\Download" -Label "WU Download cache"
    } finally {
        Start-Service bits, wuauserv -ErrorAction SilentlyContinue
    }
    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
        Write-Output "  Delivery Optimization cache cleared."
    } catch {
        Write-Output "  DO cache skipped: $($_.Exception.Message)"
    }

    # --- Summary ---
    $freeAfter = (Get-PSDrive C).Free
    Write-Output ("=== Complete. Tracked deletions: {0:N1} MB | C: free space delta: {1:N1} MB ===" -f `
        ($script:BytesFreed / 1MB), (($freeAfter - $freeBefore) / 1MB))
    Write-Output "Reminder: component store reclaim shows up after the next reboot."
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}
