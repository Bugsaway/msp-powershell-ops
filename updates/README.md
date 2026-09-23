# updates

## Invoke-WindowsUpdate.ps1

Installs the PSWindowsUpdate module if missing, then installs pending updates with the reboot deferred to an evening clock time. Run as SYSTEM through Ninja. Windows 7 exits 0 untouched.

Config block at the top:

| Setting | Default | Meaning |
|---|---|---|
| `$Mode` | Install | `ModuleOnly` only ensures the module is present. `Install` also installs updates |
| `$RebootAt` | 19:30 | 24-hour local time to reboot if one is required. Empty string leaves the reboot to Ninja's policy |
| `$IncludeDrivers` | false | Pull drivers from Microsoft Update. Off because MU drivers lag Dell, HP, and Lenovo tools |
| `$ExcludeKBs` | none | KBs to skip, for a server or a box with picky hardware |

Flow: TLS 1.2, NuGet provider, PSWindowsUpdate module, then `Get-WindowsUpdate`. If nothing is pending it exits 0 and touches nothing. Otherwise `Install-WindowsUpdate -AcceptAll -IgnoreReboot`, then `Get-WURebootStatus`. If a reboot is needed and `$RebootAt` is set, it runs `shutdown /r /f /t <seconds until that time>` with a message to the user. If the time already passed today it targets tomorrow.

Cancel a scheduled reboot with `shutdown /a`.

### Notes

- Ninja timeout 120 min. Cumulative updates on spinning disks take a while.
- The shutdown timer is cleared by any reboot, including one a user does by hand. That's fine, the reboot happened either way.
- `Set-ExecutionPolicy RemoteSigned` is set during module install. Under SYSTEM through Ninja this is the machine policy.
- Exit 1 on gallery unreachable, module install failure, or an update install exception. Ticket on exit 1.

## Reset-WindowsUpdate.ps1

On demand, when a box is stuck in a download or install loop. Stops wuauserv, bits, cryptsvc, msiserver, usosvc, dosvc, clears stuck BITS jobs, renames SoftwareDistribution and catroot2 with a timestamp (never deletes, so it's reversible), restarts the services, kicks a scan. Old .bak folders from earlier resets are removed after 7 days. Exit 1 if a core service won't stop or start.

Pair with a reboot at the next window. If the update fails again after this, the problem is the package or the servicing stack, not the client cache, and DISM RestoreHealth is the next step.

`$ResetWinsock` is off. Turn it on only for network-error download failures, and it needs a reboot.

## Configuration reference

| Script | Variable | Default | Change it when |
|---|---|---|---|
| Invoke-WindowsUpdate | `$Mode` | Install | ModuleOnly to just stage the module |
| | `$RebootAt` | 19:30 | Site closing time. Empty string defers to the RMM reboot policy |
| | `$IncludeDrivers` | false | true only on hardware with no OEM update tool |
| | `$ExcludeKBs` | empty | A known-bad KB for a server or a device with picky drivers |
| Reset-WindowsUpdate | `$KeepBakDays` | 7 | |
| | `$ResetWinsock` | false | true for download failures with network errors. Needs a reboot |
