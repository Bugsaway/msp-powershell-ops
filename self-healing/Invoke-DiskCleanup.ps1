<#
.SYNOPSIS
    Proactive disk cleanup for low-free-space remediation.
.DESCRIPTION
    Frees space on the system drive when free space falls below a threshold.
    Runs lighter cleanup first, re-checks, then escalates to heavier reclamation
    (Windows Update cache, DISM component cleanup) only if still below threshold.
.NOTES
    Run context : SYSTEM
    Exit 0      : Free space is at/above threshold (nothing to do, or cleanup succeeded)
    Exit 1      : Still below threshold after full cleanup -> create ticket
    Ninja setup : Schedule daily, OR trigger from a "Disk free space < 15%" condition.
                  Create a ticket/alert on script result = failure (exit 1).
#>

# ---------------- CONFIG ----------------
$ThresholdPercent    = 15      # Run cleanup when free % is below this
$ClearRecycleBin     = $true   # Empty Recycle Bin for all users
$ClearBrowserCache   = $true   # Clear Edge/Chrome cache folders
$RunComponentCleanup = $true   # DISM /StartComponentCleanup if still low (slower)
# ----------------------------------------

$drive = $env:SystemDrive

function Get-FreePercent {
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'"
    if (-not $d -or $d.Size -eq 0) { return $null }
    [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
}
function Get-FreeGB {
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'"
    [math]::Round($d.FreeSpace / 1GB, 2)
}
function Clear-PathContent {
    param([string]$Path)
    if (Test-Path $Path) {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$before   = Get-FreePercent
$beforeGB = Get-FreeGB
Write-Output "System drive $drive free: $before% ($beforeGB GB)"

if ($null -eq $before) { Write-Output "Could not read drive info."; exit 1 }
if ($before -ge $ThresholdPercent) {
    Write-Output "Above threshold ($ThresholdPercent%). No cleanup needed."
    exit 0
}

Write-Output "Below threshold ($ThresholdPercent%). Starting cleanup..."

# --- Light cleanup ---
Clear-PathContent "$env:windir\Temp"

Get-ChildItem "$drive\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $u = $_.FullName
    Clear-PathContent "$u\AppData\Local\Temp"
    if ($ClearBrowserCache) {
        Clear-PathContent "$u\AppData\Local\Google\Chrome\User Data\Default\Cache"
        Clear-PathContent "$u\AppData\Local\Microsoft\Edge\User Data\Default\Cache"
        Clear-PathContent "$u\AppData\Local\Microsoft\Windows\INetCache"
    }
}

# Windows Error Reporting queues
Clear-PathContent "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
Clear-PathContent "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"

# Delivery Optimization cache
try { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } catch {}

# Recycle Bin (direct folder method is reliable under SYSTEM)
if ($ClearRecycleBin) {
    $rb = Join-Path $drive '$Recycle.Bin'
    Clear-PathContent $rb
}

$mid = Get-FreePercent
Write-Output "After light cleanup: $mid%"

# --- Heavy cleanup if still low ---
if ($mid -lt $ThresholdPercent) {
    Write-Output "Still below threshold. Escalating..."

    # Windows Update cache
    try {
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Stop-Service bits -Force -ErrorAction SilentlyContinue
        Clear-PathContent "$env:windir\SoftwareDistribution\Download"
        Start-Service bits -ErrorAction SilentlyContinue
        Start-Service wuauserv -ErrorAction SilentlyContinue
    } catch { Write-Output "WU cache cleanup error: $($_.Exception.Message)" }

    # DISM component store cleanup (removes superseded updates - safe but slow)
    if ($RunComponentCleanup) {
        Write-Output "Running DISM component cleanup (may take a while)..."
        Start-Process dism.exe -ArgumentList "/online","/cleanup-image","/StartComponentCleanup" -Wait -NoNewWindow
    }
}

$after   = Get-FreePercent
$afterGB = Get-FreeGB
$freed   = [math]::Round($afterGB - $beforeGB, 2)
Write-Output "Final free: $after% ($afterGB GB). Reclaimed ~$freed GB."

if ($after -lt $ThresholdPercent) {
    Write-Output "RESULT: Still below $ThresholdPercent% after cleanup. Manual review needed."
    exit 1
}
Write-Output "RESULT: Free space restored above threshold."
exit 0
