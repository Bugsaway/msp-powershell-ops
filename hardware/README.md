# hardware

## Disable-UsbHubPowerSaving.ps1

Unchecks "Allow the computer to turn off this device to save power" on every USB hub, the same box you'd untick by hand in Device Manager. Built for intraoral sensors dropping mid-exam when Windows suspends the hub.

Run elevated. Windows PowerShell 5.1 only, it uses Get-WmiObject which PS 7 dropped. Prints one line per hub: already disabled, disabled now, or a warning if the hub has no power management instance or more than one.

Set-Win10-Win11-NeverSleep.ps1 in self-healing does this same per-device pass as step 3b, plus the global DisableSelectiveSuspend registry switch and the power plan setting. Use that one for the fleet. This one is for a single box where you only want the hub fix.

A reboot lets the USB stack re-enumerate with the new settings.

## Configuration reference

No variables. The script walks every USB hub it finds. To limit it to specific hubs, add a `Where-Object { $_.Name -like '*Root Hub*' }` after `Get-WmiObject -Class Win32_USBHub`.
