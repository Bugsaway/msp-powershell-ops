<#
.SYNOPSIS
    One-screen GPU and RAM readout.
.DESCRIPTION
    Read-only. Prints each video controller with its VRAM, then total RAM, slots used of slots
    available, and each stick with slot name, size, and speed. VRAM is read from the display
    class registry key because Win32_VideoController.AdapterRAM is a 32-bit field and caps at 4 GB.
.NOTES
    Run context : Any. Elevated gives the registry VRAM read, otherwise falls back to AdapterRAM.
    Exit        : Always 0.
    Use         : Spec check before an imaging software install or a memory upgrade quote.
#>

$g = Get-CimInstance Win32_VideoController
foreach ($x in $g) {
    $key = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}" -ErrorAction SilentlyContinue |
           Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DriverDesc -eq $x.Name } | Select-Object -First 1
    $qw = if ($key) { (Get-ItemProperty $key.PSPath)."HardwareInformation.qwMemorySize" }
    $vram = if ($qw) { [math]::Round($qw / 1GB, 1) } else { [math]::Round($x.AdapterRAM / 1GB, 1) }
    Write-Output ("GPU: {0} | {1} GB" -f $x.Name, $vram)
}
$d = Get-CimInstance Win32_PhysicalMemory
$slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object MemoryDevices -Sum).Sum
Write-Output ("RAM: {0} GB | {1} of {2} slots used" -f [math]::Round(($d | Measure-Object Capacity -Sum).Sum / 1GB), $d.Count, $slots)
$d | ForEach-Object { Write-Output ("  {0} | {1} GB | {2} MT/s" -f $_.DeviceLocator, [math]::Round($_.Capacity / 1GB), $_.Speed) }
