<#
.SYNOPSIS
    Daily workstation reboot with light cleanup.
.DESCRIPTION
    Intended for NinjaOne nightly scheduled deployment on workstations (run as SYSTEM).
    Cleanup (safe, daily-appropriate):
      1. Windows temp + all user temp files older than 1 day
      2. Stuck print jobs older than 24 hours
      3. Windows Error Reporting queue files older than 7 days
      4. DNS cache flush
    Then FORCES a reboot regardless of logged-on users (open apps are force-closed;
    unsaved work is lost - schedule accordingly).
.NOTES
    Exit 0 = cleanup done + reboot initiated
    Exit 1 = script error
#>

$ErrorActionPreference = 'Continue'
$RebootDelaySeconds = 60
$TempFileAgeDays    = 1
$WERAgeDays         = 7
$script:BytesFreed  = 0

function Remove-OldFile {
    param([string]$Path, [int]$AgeDays, [string]$Label)
    if (-not (Test-Path $Path)) { return }
    $cutoff = (Get-Date).AddDays(-$AgeDays)
    $files = Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -lt $cutoff }
    $size = ($files | Measure-Object -Property Length -Sum).Sum
    $count = 0
    foreach ($f in $files) {
        try { Remove-Item $f.FullName -Force -ErrorAction Stop; $count++ }
        catch { } # in-use files are expected, skip silently
    }
    if ($size) { $script:BytesFreed += $size }
    Write-Output ("  {0}: removed {1} files ({2:N1} MB)" -f $Label, $count, ($size / 1MB))

    # Remove now-empty directories
    Get-ChildItem -Path $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Where-Object { -not (Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue) } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

try {
    $hostname = $env:COMPUTERNAME
    Write-Output "=== Daily reboot + cleanup on $hostname - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

    # --- 1. Temp files ---
    Write-Output "[1/4] Cleaning temp files older than $TempFileAgeDays day(s)..."
    Remove-OldFile -Path "$env:SystemRoot\Temp" -AgeDays $TempFileAgeDays -Label "Windows Temp"
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $userTemp = Join-Path $_.FullName "AppData\Local\Temp"
        if (Test-Path $userTemp) {
            Remove-OldFile -Path $userTemp -AgeDays $TempFileAgeDays -Label "Temp: $($_.Name)"
        }
    }

    # --- 2. Stuck print jobs older than 24h ---
    Write-Output "[2/4] Checking for stuck print jobs..."
    $stuckJobs = Get-Printer -ErrorAction SilentlyContinue | ForEach-Object {
        Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.SubmittedTime -lt (Get-Date).AddHours(-24) }
    }
    if ($stuckJobs) {
        $stuckJobs | ForEach-Object {
            Write-Output "  Removing stuck job: '$($_.DocumentName)' on $($_.PrinterName) (submitted $($_.SubmittedTime))"
            Remove-PrintJob -InputObject $_ -ErrorAction SilentlyContinue
        }
    } else {
        Write-Output "  No stuck print jobs."
    }

    # --- 3. WER queue older than 7 days ---
    Write-Output "[3/4] Cleaning Windows Error Reporting queue older than $WERAgeDays days..."
    Remove-OldFile -Path "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"   -AgeDays $WERAgeDays -Label "WER ReportQueue"
    Remove-OldFile -Path "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" -AgeDays $WERAgeDays -Label "WER ReportArchive"

    # --- 4. DNS flush ---
    Write-Output "[4/4] Flushing DNS cache..."
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Write-Output "  DNS cache flushed."

    Write-Output ("Cleanup complete. Total freed: {0:N1} MB" -f ($script:BytesFreed / 1MB))

    # --- Forced reboot ---
    $sessions = (quser 2>$null)
    if ($sessions) {
        Write-Output "Logged-on sessions at reboot time (rebooting anyway):"
        Write-Output ($sessions -join "`n")
    }
    Write-Output "RESULT: Forcing reboot in $RebootDelaySeconds seconds."
    shutdown.exe /r /f /t $RebootDelaySeconds /c "Nightly maintenance reboot via NinjaOne" /d p:4:1
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}
