<#
.SYNOPSIS
    Weekly workstation deep cleanup (no reboot - the nightly script handles that).
.DESCRIPTION
    Intended for NinjaOne weekly schedule (e.g., Sunday, 1-2 hours BEFORE the nightly
    reboot script fires). Run as SYSTEM.
    Cleanup items:
      1. Windows Update download cache older than 7 days (services stopped/restarted safely)
      2. Delivery Optimization cache
      3. Component store cleanup (DISM /StartComponentCleanup - no /ResetBase, so
         update rollback capability is preserved)
      4. Crash dumps older than 14 days (Minidump, MEMORY.DMP, LiveKernelReports)
      5. Recycle Bin items older than 7 days (all users)
      6. Archived CBS/DISM logs older than 30 days
.NOTES
    Runtime: DISM component cleanup can take 10-30+ minutes. Set NinjaOne script
    timeout to 60 minutes.
    Exit 0 = success (individual item failures are logged, not fatal)
    Exit 1 = script error
#>

$ErrorActionPreference = 'Continue'
$script:BytesFreed = 0

function Remove-OldFile {
    param([string]$Path, [int]$AgeDays, [string]$Label)
    if (-not (Test-Path $Path)) { Write-Output "  $Label - path not found, skipping."; return }
    $cutoff = (Get-Date).AddDays(-$AgeDays)
    $files = Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -lt $cutoff }
    $size = ($files | Measure-Object -Property Length -Sum).Sum
    $count = 0
    foreach ($f in $files) {
        try { Remove-Item $f.FullName -Force -ErrorAction Stop; $count++ }
        catch { }
    }
    if ($size) { $script:BytesFreed += $size }
    Write-Output ("  {0}: removed {1} files ({2:N1} MB)" -f $Label, $count, ($size / 1MB))
}

try {
    $hostname = $env:COMPUTERNAME
    Write-Output "=== Weekly deep cleanup on $hostname - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    $freeBefore = (Get-PSDrive C).Free

    # --- 1. Windows Update download cache ---
    Write-Output "[1/6] Windows Update download cache (>7 days)..."
    $wuPath = "$env:SystemRoot\SoftwareDistribution\Download"
    try {
        Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
        Remove-OldFile -Path $wuPath -AgeDays 7 -Label "WU Download cache"
        # Prune now-empty subfolders
        Get-ChildItem $wuPath -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Get-ChildItem $_.FullName -Recurse -Force -File -ErrorAction SilentlyContinue) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    finally {
        Start-Service bits, wuauserv -ErrorAction SilentlyContinue
    }

    # --- 2. Delivery Optimization cache ---
    Write-Output "[2/6] Delivery Optimization cache..."
    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
        Write-Output "  Delivery Optimization cache cleared."
    } catch {
        Write-Output "  Skipped (cmdlet unavailable or cache empty): $($_.Exception.Message)"
    }

    # --- 3. Component store cleanup ---
    Write-Output "[3/6] Component store cleanup (DISM StartComponentCleanup - may take a while)..."
    $dism = Start-Process -FilePath dism.exe `
        -ArgumentList '/Online','/Cleanup-Image','/StartComponentCleanup' `
        -Wait -PassThru -WindowStyle Hidden
    Write-Output "  DISM exit code: $($dism.ExitCode) (0 = success, 3010 = success/reboot pending)"

    # --- 4. Crash dumps ---
    Write-Output "[4/6] Crash dumps older than 14 days..."
    Remove-OldFile -Path "$env:SystemRoot\Minidump" -AgeDays 14 -Label "Minidumps"
    Remove-OldFile -Path "$env:SystemRoot\LiveKernelReports" -AgeDays 14 -Label "LiveKernelReports"
    $memDmp = Get-Item "$env:SystemRoot\MEMORY.DMP" -ErrorAction SilentlyContinue
    if ($memDmp -and $memDmp.LastWriteTime -lt (Get-Date).AddDays(-14)) {
        $script:BytesFreed += $memDmp.Length
        Write-Output ("  MEMORY.DMP removed ({0:N1} MB)" -f ($memDmp.Length / 1MB))
        Remove-Item $memDmp.FullName -Force -ErrorAction SilentlyContinue
    }

    # --- 5. Recycle Bin items older than 7 days ---
    Write-Output "[5/6] Recycle Bin items older than 7 days (all users)..."
    $binRoot = "C:\`$Recycle.Bin"
    if (Test-Path $binRoot) {
        Remove-OldFile -Path $binRoot -AgeDays 7 -Label "Recycle Bin"
    }

    # --- 6. Archived CBS/DISM logs ---
    Write-Output "[6/6] Archived CBS/DISM logs older than 30 days..."
    $cbsOld = Get-ChildItem "$env:SystemRoot\Logs\CBS" -Filter "CbsPersist_*" -File -ErrorAction SilentlyContinue |
              Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) }
    $cbsSize = ($cbsOld | Measure-Object Length -Sum).Sum
    $cbsOld | Remove-Item -Force -ErrorAction SilentlyContinue
    if ($cbsSize) { $script:BytesFreed += $cbsSize }
    Write-Output ("  CBS archived logs: removed {0} files ({1:N1} MB)" -f @($cbsOld).Count, ($cbsSize / 1MB))

    # --- Summary ---
    $freeAfter = (Get-PSDrive C).Free
    Write-Output ("=== Complete. Tracked deletions: {0:N1} MB | C: free space delta: {1:N1} MB ===" -f `
        ($script:BytesFreed / 1MB), (($freeAfter - $freeBefore) / 1MB))
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}
