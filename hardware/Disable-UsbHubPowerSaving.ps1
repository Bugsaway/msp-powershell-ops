<#
.SYNOPSIS
    Unchecks "Allow the computer to turn off this device to save power" on every USB hub.
.DESCRIPTION
    Walks Win32_USBHub, matches each hub to its MSPower_DeviceEnable instance, and sets
    Enable to false. Keeps USB devices such as intraoral sensors from being suspended.
    Set-Win10-Win11-NeverSleep.ps1 does this same pass as one of its steps plus the global
    registry switch. Use this one for a single machine that only needs the hub fix.
.NOTES
    Run context : Elevated. Windows PowerShell 5.1 only, Get-WmiObject is not in PowerShell 7.
    Exit        : Always 0. Read the per-hub lines.
    Output      : One line per hub: already disabled, disabled now, or a warning if the hub
                  has no power management instance or more than one.
    After       : Reboot so the USB stack re-enumerates with the new settings.
#>

$USBHubs = Get-WmiObject -Class Win32_USBHub
$PowerMgmt = Get-WmiObject -Class MSPower_DeviceEnable -Namespace root\wmi

ForEach ($Hub in $USBHubs) {
    Write-Host
    Write-Host -Object "Checking USB Hub '$($Hub.Name)'..."
    $VarPowerSettings = $PowerMgmt | Where {$_.InstanceName -like "*$($Hub.DeviceID)*"}
    If (($VarPowerSettings | Measure).Count -eq 1) {
        If (($VarPowerSettings | Select -ExpandProperty Enable) -eq $False) {Write-Host -Object "USB Hub '$($Hub.Name)' already has power saving disabled" -ForegroundColor Green}
        Else {
            Try {
                $VarPowerSettings.Enable = $False
                $Null = $VarPowerSettings.psbase.Put()
                Write-Host -Object "Disabled power saving features for USB Hub '$($Hub.Name)'" -ForegroundColor Green
            }
            Catch {Write-Warning -Message "One or more exceptions occurred when trying to set power saving settings for USB Hub '$($Hub.Name)'"}
        }
    }
    ElseIf (($VarPowerSettings | Measure).Count -gt 1) {Write-Warning -Message "More than one WMI object representing power settings was found for '$($Hub.Name)', no settings have been changed for this device"}
    Else {Write-Warning -Message "No power settings were found for '$($Hub.Name)', please check if the device supports power saving features"}
}
