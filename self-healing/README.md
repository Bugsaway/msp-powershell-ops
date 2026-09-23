# self-healing

NinjaOne scripts on a detect-first, condition-triggered pattern. All run as SYSTEM. Exit 0 means healthy or fixed. Exit 1 means unresolvable, and a ticket fires only on exit 1.

| Script | Trigger | What it does | Exit 1 when |
|---|---|---|---|
| Remove-StaleProfiles.ps1 | Monthly, or after DiskCleanup on a low-space condition | Dual-signal stale detection: Win32_UserProfile LastUseTime AND NTUSER.DAT last write both older than 90 days. Skips loaded, special, Administrator, Default, Public, the exclusion list, and anyone with a live session. Dry-run by default | A removal fails (live mode only) |
| Repair-SystemHealth.ps1 | Repeated 7034/7031, BSOD condition, or on demand | DISM CheckHealth and ScanHealth, RestoreHealth only if flagged. SFC verifyonly, scannow only if violations. Repair-Volume -Scan, SpotFix only if errors. No /ResetBase, never chkdsk /f or /r | Store, files, or volume still bad after repair |
| Invoke-DiskCleanup.ps1 | C: free below 15%, or daily | Light cleanup first (temp, browser cache, WER, DO cache, Recycle Bin), re-checks, escalates to WU download cache and DISM StartComponentCleanup only if still low | Still under threshold after everything |
| Repair-PrintSpooler.ps1 | Spooler stopped condition, or every 15 to 30 min | Sets Automatic, starts it, hard-recovers (purge queue, restart) if it won't start, clears jobs in Error or Blocked older than 15 min | Spooler won't start |
| Set-PowerPolicy.ps1 | Daily | Never sleep or hibernate on AC, monitor off after 15 min, laptops sleep after 30 min on battery, Fast Startup off. Servers and DCs get AC no-standby only | powercfg or registry write fails |
| Set-Win10-Win11-NeverSleep.ps1 | Daily | Forces High Performance, never sleep, never hibernate, never display off, USB selective suspend off (plan, global registry switch, per-device), Fast Startup off. Win10 and 11 clients only, servers skipped by ProductType | A load-bearing powercfg or registry step fails |
| Sync-SystemTime.ps1 | Daily | W32Time Automatic and running, domain hierarchy or public NTP depending on join state, forced resync, then measures offset against 120 s tolerance. DCs skipped | Offset unverifiable or still out of tolerance (usually UDP 123 blocked) |

## Pick one power script, not both

Set-PowerPolicy and Set-Win10-Win11-NeverSleep overlap and disagree. PowerPolicy lets the monitor turn off after 15 minutes and lets laptops sleep on battery. NeverSleep sets display to never and sleep to never on both AC and DC, and adds the USB fixes. If both run daily the last one to fire wins and the fleet flips back and forth.

NeverSleep covers the intraoral sensor USB drops and keeps the display on, so it's the standard for op workstations. PowerPolicy is the lighter option for front desk or laptop machines where a dark monitor is fine. Assign by device group, don't stack them.

## Remove-StaleProfiles ships in dry-run

`$DryRun = $true` at the top. First run on any site prints what it would delete and exits 0. Read that output, add anything surprising to `$ExcludeUsers`, then flip it. The delete goes through the Win32_UserProfile Delete method so the ProfileList registry entry goes with the folder and you don't get orphaned SIDs in the next login screen.

Add any local service or admin accounts to `$ExcludeUsers`. Output in both modes: one line per stale profile with username, last use date, NTUSER.DAT date, and size in MB, plus the total.

## Repair-SystemHealth vs Monthly-Super-Clean

Monthly always runs RestoreHealth and scannow. This one only runs them when a check says to, so it's the one to hang on a crash condition where you don't want a 45 minute repair kicking off on a box that's fine. RestoreHealth needs Windows Update reachable, otherwise it fails 0x800f081f and the script exits 1.

## Repair-StoppedAutoServices.ps1

Every 30 min on servers, hourly on workstations. Finds Automatic services that aren't running, skips delayed-start, trigger-start, and a known-noise list of Windows services that idle by design, and starts the rest. Exit 1 if one won't start.

`$PriorityServices` is the dental list: DentrixACEServer, DDX, DtxCommSrv, MySQL and MariaDB, SQLANYs_*, Eaglesoft, Patterson, DEXIS, Sidexis, Vatech, Carestream, Weave, Open Dental. Those are always checked and reported by name regardless of the skip rules.

Output: each service started, tagged PRIORITY or auto, with its previous state. A failed start prints the exception. Exit 1 means at least one service would not come up and needs a look at its dependencies or event log.

## Configuration reference

Every value lives in the config block at the top of its script.

| Script | Variable | Default | Change it when |
|---|---|---|---|
| Invoke-DiskCleanup | `$ThresholdPercent` | 15 | Servers with large disks can go lower, small SSDs higher |
| | `$ClearRecycleBin` | true | Users keep things in the bin on purpose |
| | `$ClearBrowserCache` | true | A web app depends on cached state |
| | `$RunComponentCleanup` | true | The box can't afford a 20 minute DISM run |
| Remove-StaleProfiles | `$DaysInactive` | 90 | Seasonal or rotating staff need longer |
| | `$DryRun` | true | Set false only after reading a dry run on that site |
| | `$ExcludeUsers` | Administrator | Add local admin, service, and kiosk accounts |
| | `$MinSizeMB` | 0 | Only chase profiles worth the space |
| Repair-PrintSpooler | `$ClearStuckJobs` | true | A site wants failed jobs left for review |
| | `$StuckMinutes` | 15 | Slow plotters or label printers need longer |
| | `$ClearAllOnRestart` | false | Set true if a corrupt spool file keeps killing the service |
| Repair-StoppedAutoServices | `$PriorityServices` | dental list | Add the practice management, imaging, and phone services in use |
| | `$IgnoreServices` | Windows idle list | Add any Auto service that stops by design on that build |
| | `$StartTimeoutSec` | 30 | Database engines that take longer to come up |
| Repair-SystemHealth | `$DriveLetter` | C | Never anything else from automation |
| Set-PowerPolicy | `$MonitorOffMinutesAC` | 15 | 0 keeps the display on |
| | `$StandbyMinutesDC` | 30 | Laptop battery policy |
| | `$DisableFastStartup` | true | Leave true |
| Set-Win10-Win11-NeverSleep | `$TargetPlan` | HighPerformance | Balanced on Modern Standby laptops, empty to leave the plan alone |
| | `$KeepMonitorOn` | true | false lets the display sleep |
| | `$DisableUsbPowerSaving` | true | Leave true anywhere a sensor or scanner is plugged in |
| | `$DisableFastStartup` | true | Leave true |
| | `$DisableHibernationFeature` | false | true removes hiberfil.sys and reclaims the space |
| Sync-SystemTime | `$ToleranceSeconds` | 120 | Kerberos breaks at 300, keep well under |
| | `$WorkgroupPeers` | time.windows.com, pool.ntp.org | Internal NTP for workgroup boxes |
