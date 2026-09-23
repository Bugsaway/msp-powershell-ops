<#
.SYNOPSIS
    Interactive tune-up for a single slow Windows 10 or 11 workstation.
.DESCRIPTION
    Nine independent sections: baseline diagnostics, temp and cache cleanup, component store
    cleanup, DISM and SFC, network stack reset, volume optimization, power and visual tweaks,
    optional bloat removal, event log clear. Comment out any section that doesn't fit the box.
    Read the section 1 baseline first. If the disk is an HDD, nothing below it will help much.
.NOTES
    Run context : Elevated, by hand. Not for RMM. The scheduled maintenance scripts are the
                  fleet-safe equivalents.
    Exit        : Always 0. Reboot when it finishes.
    Runtime     : 20 to 40 minutes, mostly DISM and SFC.
    Side effects: chkdsk /f queued for next boot, hibernate off, High Performance plan,
                  event logs cleared. Don't run on a machine under investigation.
#>

$ErrorActionPreference = "SilentlyContinue"
Write-Host "=== Starting cleanup ===" -ForegroundColor Cyan

# ---------- 1. Baseline: what's eating the box right now ----------
Write-Host "`n--- Top CPU consumers ---"
Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, Id, @{n="CPU(s)";e={[math]::Round($_.CPU,1)}}, @{n="MemMB";e={[math]::Round($_.WS/1MB)}} | Format-Table -AutoSize

Write-Host "--- Top memory consumers ---"
Get-Process | Sort-Object WS -Descending | Select-Object -First 10 Name, Id, @{n="MemMB";e={[math]::Round($_.WS/1MB)}} | Format-Table -AutoSize

Write-Host "--- Disk type and health (HDD = your real problem) ---"
Get-PhysicalDisk | Select-Object FriendlyName, MediaType, HealthStatus, @{n="SizeGB";e={[math]::Round($_.Size/1GB)}} | Format-Table -AutoSize

Write-Host "--- Free space ---"
Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel, @{n="FreeGB";e={[math]::Round($_.SizeRemaining/1GB,1)}}, @{n="TotalGB";e={[math]::Round($_.Size/1GB,1)}} | Format-Table -AutoSize

Write-Host "--- Startup items (review and disable junk in Task Manager > Startup) ---"
Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location | Format-Table -AutoSize -Wrap

# ---------- 2. Temp and cache cleanup ----------
Write-Host "`n--- Clearing temp files ---"
$paths = @(
    "$env:TEMP\*",
    "C:\Windows\Temp\*",
    "C:\Windows\Prefetch\*",
    "C:\Windows\SoftwareDistribution\Download\*",
    "C:\ProgramData\Microsoft\Windows\WER\*",
    "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\*",
    "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*",
    "$env:LOCALAPPDATA\CrashDumps\*",
    "C:\Windows\Logs\CBS\*.log",
    "C:\Windows\Minidump\*"
)

# Stop services that lock files in SoftwareDistribution
Stop-Service wuauserv, bits -Force

foreach ($p in $paths) {
    Remove-Item -Path $p -Recurse -Force
    Write-Host "Cleared $p"
}

Start-Service wuauserv, bits

# Delivery Optimization cache
Delete-DeliveryOptimizationCache -Force

# Recycle bin
Clear-RecycleBin -Force

# Windows Store cache
Start-Process wsreset.exe -Wait -WindowStyle Hidden

# ---------- 3. Component store cleanup ----------
Write-Host "`n--- DISM component cleanup (takes a while) ---"
# No /ResetBase. It makes installed updates permanent and removes the ability to uninstall one.
Dism.exe /Online /Cleanup-Image /StartComponentCleanup

# Built-in Disk Cleanup, all categories checked, silent
Write-Host "--- cleanmgr ---"
$volCaches = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
Get-ChildItem $volCaches | ForEach-Object { New-ItemProperty -Path $_.PSPath -Name StateFlags0099 -Value 2 -PropertyType DWord -Force | Out-Null }
Start-Process cleanmgr.exe -ArgumentList "/sagerun:99" -Wait -WindowStyle Hidden

# ---------- 4. Integrity and repair ----------
Write-Host "`n--- DISM RestoreHealth then SFC ---"
Dism.exe /Online /Cleanup-Image /RestoreHealth
sfc /scannow

# ---------- 5. Network stack ----------
Write-Host "`n--- Network reset ---"
Clear-DnsClientCache
ipconfig /flushdns
netsh winsock reset
netsh int ip reset

# ---------- 6. Storage optimization ----------
Write-Host "`n--- Optimize volumes (TRIM on SSD, defrag on HDD) ---"
Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq "Fixed" } | ForEach-Object {
    Optimize-Volume -DriveLetter $_.DriveLetter -Verbose
}

# Schedule chkdsk on next boot for C:
Write-Host "--- Scheduling chkdsk /f on C: for next reboot ---"
echo Y | chkdsk C: /f

# ---------- 7. Power and visual tweaks ----------
Write-Host "`n--- Power plan ---"
# High performance
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
# Disable hibernation, frees hiberfil.sys (skip if you use hibernate)
powercfg /h off

# Set visual effects to "best performance"
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name VisualFXSetting -Value 2 -Type DWord

# ---------- 8. Optional: stop common background bloat ----------
# Uncomment if you want these gone
# Get-AppxPackage *xbox* | Remove-AppxPackage
# Get-AppxPackage *bing* | Remove-AppxPackage
# Get-AppxPackage *solitaire* | Remove-AppxPackage
# Stop-Service SysMain -Force
# Set-Service SysMain -StartupType Disabled   # only helps on HDD systems

# ---------- 9. Event log cleanup ----------
Write-Host "`n--- Clearing event logs ---"
wevtutil el | ForEach-Object { wevtutil cl "$_" }

Write-Host "`n=== Done. Reboot now. ===" -ForegroundColor Green
