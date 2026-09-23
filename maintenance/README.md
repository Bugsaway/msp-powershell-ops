# maintenance

Scheduled cleanup and reboot scripts for the fleet, plus a couple of by-hand tools.

## Scheduled (NinjaOne, SYSTEM)

### Daily-Reboot-Cleanup.ps1

Nightly. Temp files older than 1 day (system and every user), print jobs older than 24 hours, WER queue older than 7 days, DNS flush. Then `shutdown /r /f /t 60`, unconditionally, because offices leave PCs on. Logged-on sessions are listed in the output but do not stop the reboot. Unsaved work is lost, so schedule it after hours.

### Weekly-Deep-Cleanup.ps1

Sunday, 1 to 2 hours before the nightly reboot. No reboot of its own. WU download cache older than 7 days (wuauserv and bits stopped and restarted around it), Delivery Optimization cache, DISM StartComponentCleanup with no /ResetBase, crash dumps older than 14 days, Recycle Bin items older than 7 days, archived CBS logs older than 30 days. Ninja timeout 60 min.

### Monthly-Super-Clean.ps1

First Sunday, before the nightly reboot. Combines system repair and heavy cleanup in one job. DISM RestoreHealth first, then SFC, then component cleanup with no /ResetBase, then Repair-Volume -Scan and -SpotFix only if the scan finds something (never /r or /f), full temp purge, Chrome and Edge Cache_Data only with cookies and sessions untouched, full WU and DO cache. Ninja timeout 120 min. Component store space shows up after the next reboot.

### Reboot-NonEaglesoftServers.ps1

Scheduled server reboot that refuses to fire if Eaglesoft is live. Two detection layers: running services matching Eaglesoft, Patterson, or SQLANYs_*, and running processes Eaglesoft.exe or any dbsrv*.exe. A dbsrv engine whose command line doesn't name Patterson is still treated as a hit out of caution. Detection verified against Eaglesoft 20, 21.10, and 25. Skipped and rebooted both exit 0 since both are expected. Note this one does not use /f, so a hung app can hold the reboot.

## By hand

### PC-Cleanup.ps1

Interactive tune-up for a single slow Windows 10 or 11 box. Run elevated, reboot after. 20 to 40 minutes. Read the section 1 baseline first: if it reports an HDD, stop and swap in an SSD, nothing below will help.

It turns off hibernate, sets the High Performance plan, and clears event logs. Comment out any section that doesn't fit the machine. Don't run it on anything under investigation, since section 9 wipes the logs. The scheduled scripts above are the fleet-safe equivalents.

### Clear-BrowserCache.ps1

User-context script. Kills Weave (it pins a Chrome window open and blocks the delete), then Chrome and Edge, clears Cache and Code Cache for every profile folder under the user's Local AppData, relaunches whichever browser was running. Cookies, passwords, history untouched.

Runs as the logged-on user, not SYSTEM, because it reads `$env:LOCALAPPDATA`. In Ninja set run-as to current logged on user. For the all-users SYSTEM version, Monthly-Super-Clean step 6 does the same job.

### New-WorkstationBaseline.ps1

New-device automation, and safe to re-run on an existing machine to bring it back to standard. Every step is detect-first: ok if already set, set if it changed it, FAILED with the error otherwise. Exit 1 on any failure.

Owns: time zone, RDP with NLA and the firewall rule, Fast Startup off, consumer features and Cortana and tips off, Xbox services disabled, OneDrive sync off by policy, file extensions and hidden files shown (current and default profile), and Windows Update told not to auto-reboot with users logged on.

Chains, when run from the repo on disk: Set-Win10-Win11-NeverSleep, Set-EventLogSizes, Set-DentalDefenderExclusions, Sync-SystemTime. In Ninja, add those to the same automation after this script instead. Doesn't rename, domain-join, or install software, since those need credentials or installers.

`$TimeZone` defaults to Eastern. Change per site group.

## Configuration reference

| Script | Variable | Default | Change it when |
|---|---|---|---|
| Daily-Reboot-Cleanup | `$RebootDelaySeconds` | 60 | Give users longer to save if the window overlaps staff hours |
| | `$TempFileAgeDays` | 1 | An app writes temp files it reopens later |
| | `$WERAgeDays` | 7 | Keeping crash reports longer for a support case |
| Weekly-Deep-Cleanup | ages are inline per step | 7, 14, 30 days | Edit the `-AgeDays` value on the step that needs it |
| Monthly-Super-Clean | none | | Comment out a step number to skip it |
| Reboot-NonEaglesoftServers | `$RebootDelaySeconds` | 60 | |
| | `$svcPatterns` | Eaglesoft, Patterson, SQLANYs_* | Add patterns for another database engine that must not be interrupted |
| New-WorkstationBaseline | `$TimeZone` | Eastern Standard Time | Per site group. `Get-TimeZone -ListAvailable` for IDs |
| | `$EnableRdp` | true | false where RDP is not permitted |
| | `$DisableFastStartup` | true | Leave true |
| | `$DisableConsumerNoise` | true | false to keep Xbox services or Cortana |
| | `$RemoveOneDriveAutorun` | true | false if the site uses OneDrive |
| | `$ExplorerTweaks` | true | |
| | `$WuNoAutoReboot` | true | |
| | `$ChainSiblings` | true | false when run from Ninja, the automation chains them instead |
| PC-Cleanup | section blocks | all on | Comment out a section. Section 8 bloat removal is off by default |
| Clear-BrowserCache | `$browsers` | Chrome, Edge | Add a row for another Chromium browser: process name, exe, User Data path |
