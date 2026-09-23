# msp-powershell-ops

Operations automation for a multi-tenant Windows MSP environment serving dental practices, managed through NinjaOne RMM. They cover self-healing automation, scheduled maintenance, monitoring, security auditing, patching, diagnostics, incident response, backup, and device onboarding.

Windows PowerShell 5.1 compatible unless a script says otherwise. Most run elevated locally or as SYSTEM through NinjaOne. Every push is parse-checked and linted by GitHub Actions.

## Contents

- [How to use](#how-to-use)
- [Start here](#start-here)
- [Conventions](#conventions)
- [Layout](#layout)
- [Script catalog](#script-catalog)
  - [self-healing](#self-healing)
  - [maintenance](#maintenance)
  - [monitoring](#monitoring)
  - [security](#security)
  - [updates](#updates)
  - [diagnostics](#diagnostics)
  - [incident-response](#incident-response)
  - [backup](#backup)
  - [hardware](#hardware)
- [Deployment schedule](#deployment-schedule)
- [NinjaOne setup](#ninjaone-setup)
- [Linting](#linting)
- [License](#license)
- [Author](#author)

## How to use

1. Every script has a config block at the top. Thresholds, paths, schedules, and allowlists live there. Nothing needs editing below it.
2. Run elevated by hand, or paste into a NinjaOne script and run as SYSTEM.
3. Exit codes drive automation. Exit 0 is healthy or fixed. Exit 1 is unresolvable. In Ninja, set a condition to open a ticket on script result = failure and nothing else.
4. Anything marked read-only in its header changes nothing on the host and is safe to run anywhere.
5. `Get-Help .\<script>.ps1 -Full` works on every script. The `.NOTES` block carries run context, exit codes, and what the output means.

Each folder has its own README with more detail per script: what to change, what the output looks like, and what to check when it exits 1.

## Start here

Four scripts that show the range of the repo. Each is self-contained.

| Script | What it shows |
|---|---|
| [incident-response/Collect-IncidentEvidence.ps1](incident-response/Collect-IncidentEvidence.ps1) | Forensic collection under chain of custody. Volatile state first, event log extracts, registry hives, remote access artifacts, Recycle Bin $I decoding, hashed and packaged |
| [diagnostics/Find-ServiceTaskCulprit.ps1](diagnostics/Find-ServiceTaskCulprit.ps1) | Diagnostic reasoning. Correlates scheduled task runs against Service Control Manager events, and reads inside the batch files tasks call |
| [maintenance/Reboot-NonEaglesoftServers.ps1](maintenance/Reboot-NonEaglesoftServers.ps1) | Domain knowledge and safety. Two-layer detection of a live practice management database before a server reboot is allowed |
| [self-healing/Repair-SystemHealth.ps1](self-healing/Repair-SystemHealth.ps1) | The detect-first pattern. DISM, SFC, and volume repair each gated on their own check, with the rollback-hostile options deliberately left out |

## Conventions

- Detect first. Fix only when the detection says something is wrong.
- Exit 0 means healthy or fixed. Exit 1 means unresolvable and should raise a ticket. Inventory scripts always exit 0 and write a custom field instead.
- Read-only scripts say so in the header and stay that way.
- No DISM /ResetBase on anything that touches production. It welds installed updates in place and kills the ability to uninstall one that breaks practice software.
- No chkdsk /f or /r from automation. Repair-Volume -Scan then -SpotFix is online and takes seconds. Offline scans are a manual decision.
- Backup and escalate before touching servers, databases, AD, or the registry.
- Scripts that run through Ninja assume SYSTEM and no interactive desktop.
- Server reboots check for live Eaglesoft, Patterson, and Sybase processes first.
- Nothing is deleted when a rename will do (Windows Update cache reset, profile removal goes through the supported API).

## Layout

```
msp-powershell-ops/
  self-healing/        Detect-first, condition-triggered fixes. Exit 1 = ticket
  maintenance/         Scheduled cleanup and reboots, onboarding baseline, by-hand tune-ups
  monitoring/          Detect-only checks that ticket on exit 1 (crash loops, disks, backups, Defender, network)
  security/            Remote access audit, local admin audit, event log sizing, SMBv1 report, Defender exclusions
  updates/             Windows Update via PSWindowsUpdate with deferred reboot, WU client reset
  diagnostics/         Read-only investigation scripts. Change nothing, print findings
  incident-response/   Evidence collection under chain of custody
  backup/              Backup job setup for practice management databases
  hardware/            Device-level fixes (USB power management)
  tests/               Pester tests that enforce the conventions above
  .github/workflows/   Parse check, Pester, and PSScriptAnalyzer on every push
```

## Script catalog

### self-healing

Condition-triggered or scheduled. Each one checks, fixes only if needed, and exits 1 only when the fix didn't take.

| Script | What it does | Trigger | Exit 1 when |
|---|---|---|---|
| Invoke-DiskCleanup.ps1 | Light cleanup (temp, browser cache, WER, DO cache, Recycle Bin), re-checks free space, escalates to WU download cache and DISM StartComponentCleanup only if still under threshold | C: free below 15%, or daily | Still under threshold after everything |
| Remove-StaleProfiles.ps1 | Removes profiles where both Win32_UserProfile LastUseTime and NTUSER.DAT last write are older than 90 days. Skips loaded, special, Administrator, Default, Public, exclusion list, and live sessions. Dry-run by default | Monthly, or after DiskCleanup on low space | A removal fails (live mode) |
| Repair-PrintSpooler.ps1 | Sets Automatic, starts it, hard-recovers (purge queue, restart) if it won't start, clears jobs in Error or Blocked older than 15 min | Spooler-stopped condition, or every 15 to 30 min | Spooler won't start |
| Repair-StoppedAutoServices.ps1 | Starts Automatic services that aren't running, skipping delayed-start, trigger-start, and a known-idle list. Dental services (Dentrix, DDX, DtxCommSrv, MySQL, MariaDB, SQLANYs, Eaglesoft, DEXIS, Sidexis, Weave, Open Dental) are priority and always reported by name | Every 30 min on servers, hourly on workstations | A service won't start |
| Repair-SystemHealth.ps1 | DISM CheckHealth and ScanHealth, RestoreHealth only if flagged. SFC verifyonly, scannow only if violations. Repair-Volume -Scan, SpotFix only if errors | Repeated 7031/7034, BSOD condition, or on demand | Store, files, or volume still bad after repair |
| Set-PowerPolicy.ps1 | Never sleep or hibernate on AC, monitor off after 15 min, laptops sleep after 30 min on battery, Fast Startup off. Servers get AC no-standby only | Daily | powercfg or registry write fails |
| Set-Win10-Win11-NeverSleep.ps1 | High Performance plan, never sleep, never hibernate, never display off, USB selective suspend off at plan, registry, and per-device levels, Fast Startup off. Clients only, servers skipped | Daily | A load-bearing powercfg or registry step fails |
| Sync-SystemTime.ps1 | W32Time Automatic and running, domain hierarchy or public NTP by join state, forced resync, offset measured against 120 s. DCs skipped | Daily | Offset unverifiable or still out of tolerance |

Pick one power script per device group. Set-PowerPolicy lets the display sleep. Set-Win10-Win11-NeverSleep does not and adds the USB fixes for op rooms with sensors. Running both daily makes them fight.

### maintenance

Scheduled fleet jobs, an onboarding baseline, and two by-hand tools.

| Script | What it does | Trigger | Exit 1 when |
|---|---|---|---|
| Daily-Reboot-Cleanup.ps1 | Temp older than 1 day, print jobs older than 24 h, WER older than 7 days, DNS flush, then a forced reboot in 60 s regardless of sessions | Nightly | Script error |
| Weekly-Deep-Cleanup.ps1 | WU download cache older than 7 days, Delivery Optimization cache, DISM StartComponentCleanup, crash dumps older than 14 days, Recycle Bin older than 7 days, CBS archives older than 30 days. No reboot | Sunday, 1 to 2 h before nightly | Script error |
| Monthly-Super-Clean.ps1 | DISM RestoreHealth, SFC, component cleanup, Repair-Volume scan and SpotFix, full temp purge, Chrome and Edge Cache_Data only, full WU and DO cache. No reboot | First Sunday, before nightly | Script error |
| Reboot-NonEaglesoftServers.ps1 | Server reboot that refuses if Eaglesoft, Patterson, or SQLANYs services or any dbsrv engine are running. Skipped and rebooted both exit 0 | Server maintenance window | Script error |
| New-WorkstationBaseline.ps1 | Onboarding: time zone, RDP with NLA, Fast Startup off, consumer features and Cortana off, Xbox services off, OneDrive off by policy, Explorer shows extensions, WU no auto-reboot with users. Chains NeverSleep, EventLogSizes, DefenderExclusions, SystemTime | New device automation, re-runnable | Any step fails |
| PC-Cleanup.ps1 | Interactive nine-section tune-up for one slow PC. Baseline first, then temp, DISM, SFC, network reset, optimize, power, optional bloat, event logs. By hand only | Manual | Never (always 0) |
| Clear-BrowserCache.ps1 | User-context. Kills Weave, Chrome, Edge, clears Cache and Code Cache for every profile, relaunches what was open | Manual, run as logged-on user | Never (always 0) |

### monitoring

Detect-only. Nothing is changed on the host.

| Script | What it does | Trigger | Exit 1 when |
|---|---|---|---|
| Find-CrashLoop.ps1 | Counts service crashes (7031, 7034, 7024) and app crashes (1000, 1026) per offender over 60 min, prints the ImagePath of anything over 5. Checks days of log history held | Hourly | Loop over threshold, or a log rolling under 7 days |
| Test-DiskHealth.ps1 | Get-PhysicalDisk health plus reliability counters: uncorrected errors, wear, temperature, power-on hours. Reports HDD vs SSD. Writes `diskSummary` | Daily | Any disk not Healthy or a counter over threshold |
| Test-BackupFreshness.ps1 | Newest file in each configured backup path must be young enough and big enough, and the status log's last line must say OK. Paths that don't exist are skipped | Daily, after the backup window | Stale, undersized, or last run failed |
| Test-DefenderHealth.ps1 | AM service, real-time, behavior monitoring, tamper, cloud, signature age under 3 days, quick scan under 7 days, not passive. Handles third-party AV via Security Center. Writes `defenderStatus` | Daily | Any check fails |
| Get-NetworkBaseline.ps1 | Active adapter IP, gateway, DNS, MAC, link speed, DHCP or static, domain, public IP and ISP. Flags DNS not in the expected list. Writes `netBaseline` | Weekly | Only if enabled and DNS doesn't match |

### security

| Script | What it does | Trigger | Exit 1 when |
|---|---|---|---|
| Find-UnauthorizedRemoteAccess.ps1 | Finds remote access tools by service, uninstall registry, install folders (machine and per-user), and running process with live connections. ScreenConnect instance ID and relay host parsed out. Anything not allowlisted is reported | Daily | Unrecognized tool found. Collect evidence before removing |
| Get-LocalAdminAudit.ps1 | Local Administrators via ADSI so orphaned SIDs show. Compares against the expected list. Writes `localAdmins` | Weekly | Unexpected member or orphaned SID |
| Set-EventLogSizes.ps1 | Raises System and Application to 256 MB, Security to 1 GB (2 GB on a DC), PowerShell and TaskScheduler Operational up, TaskScheduler history on. Never shrinks. Prints days of history held | Monthly, or at onboarding | wevtutil fails |
| Get-SmbV1Status.ps1 | SMBv1 at config, feature, and driver level, plus every inbound session and outbound connection under dialect 2.0. Report only. Writes `smb1Status` | Monthly | Only if `$TicketIfEnabled` |
| Set-DentalDefenderExclusions.ps1 | Per vendor (Dentrix, Eaglesoft, Open Dental, DEXIS, Sidexis, Carestream, SOTA), detects by install path, adds only missing path and process exclusions. Removes nothing | Monthly, and at onboarding | Add-MpPreference fails |

### updates

| Script | What it does | Trigger | Exit 1 when |
|---|---|---|---|
| Invoke-WindowsUpdate.ps1 | Installs PSWindowsUpdate if missing, lists pending, installs with IgnoreReboot, then schedules `shutdown /r` for `$RebootAt` (default 19:30) if a reboot is needed. Empty `$RebootAt` defers to Ninja policy | Patch window | Gallery unreachable, module install fails, or update install throws |
| Reset-WindowsUpdate.ps1 | Stops the update services, renames SoftwareDistribution and catroot2 with a timestamp, clears stuck BITS jobs, restarts, kicks a scan. Old .bak folders removed after 7 days | On demand | A core service won't stop or start |

### diagnostics

Read-only. Print findings.

| Script | What it does | Trigger | Exit |
|---|---|---|---|
| Find-ServiceTaskCulprit.ps1 | Service config and recovery actions, every scheduled task and the scripts they call grepped for the service name, SCM events for 7 days, task runs within 10 min of each event, and everything non-Microsoft that ran overnight | On demand | Always 0 |
| Get-HardwareSummary.ps1 | Each GPU with VRAM from the registry (AdapterRAM caps at 4 GB), total RAM, slots used of available, each stick with slot, size, speed | On demand | Always 0 |
| Test-Win11Eligibility.ps1 | TPM 2.0, UEFI and Secure Boot, 64-bit, cores and clock, RAM, disk size and partition style, CPU generation heuristic. Writes `win11Eligible` and `win11Blockers` | Once, then after hardware changes | Always 0 |

### incident-response

| Script | What it does | Trigger | Exit 1 when |
|---|---|---|---|
| Collect-IncidentEvidence.ps1 | Read-only collection in order: volatile state, event logs as .evtx plus filtered CSVs, registry hives and targeted exports, remote access tool folders and configs, Recycle Bin with $I decoded, per-user browser and shell artifacts, Prefetch, Amcache, SRUM, Defender history, full disk listing. SHA256 manifest, zipped, zip hashed, chain of custody log | On demand, before any wipe | Not running elevated |

Parameters: `-OutputRoot` (default C:\IR, use a USB drive to keep off the evidence disk), `-Collector`, `-CaseId`, `-SkipFullListing`, `-NoZip`. 15 to 30 minutes per machine.

### backup

| Script | What it does | Trigger | Exit |
|---|---|---|---|
| Setup-ODMariaBackupTask.ps1 | Registers a nightly SYSTEM task for Open Dental on MariaDB 10.5: mariabackup streamed into 7-Zip through a cmd wrapper (PowerShell 5.1 corrupts binary pipes). Dated archives, real success check on mariabackup's log, prune only after a good run, status.log for monitoring. `$ArchiveDest` moves archives to a data or external drive | Once per server, re-runnable | Throws if mariabackup or 7z is missing |

Pair with monitoring/Test-BackupFreshness.ps1, which ships with the matching check.

### hardware

| Script | What it does | Trigger | Exit |
|---|---|---|---|
| Disable-UsbHubPowerSaving.ps1 | Unchecks "Allow the computer to turn off this device to save power" on every USB hub via WMI. Windows PowerShell 5.1 only | On demand, single machine | Always 0 |

Set-Win10-Win11-NeverSleep does the same pass fleet-wide plus the global registry switch. This one is for a single box that only needs the hub fix.

## Deployment schedule

| When | Script | Ninja timeout |
|---|---|---|
| New device automation | maintenance/New-WorkstationBaseline.ps1 | 15 min |
| Nightly | maintenance/Daily-Reboot-Cleanup.ps1 | 15 min |
| Weekly, Sunday, 1 to 2 hours before nightly | maintenance/Weekly-Deep-Cleanup.ps1 | 60 min |
| Monthly, first Sunday, before nightly | maintenance/Monthly-Super-Clean.ps1 | 120 min |
| Server maintenance window | maintenance/Reboot-NonEaglesoftServers.ps1 | 5 min |
| Daily | self-healing/Set-Win10-Win11-NeverSleep.ps1 or Set-PowerPolicy.ps1 | 10 min |
| Daily | self-healing/Sync-SystemTime.ps1 | 5 min |
| Every 15 to 30 min or on spooler-stopped condition | self-healing/Repair-PrintSpooler.ps1 | 5 min |
| Hourly (30 min on servers) | self-healing/Repair-StoppedAutoServices.ps1 | 10 min |
| On C: free < 15% condition | self-healing/Invoke-DiskCleanup.ps1 | 60 min |
| Monthly, or after DiskCleanup | self-healing/Remove-StaleProfiles.ps1 | 30 min |
| On crash condition or on demand | self-healing/Repair-SystemHealth.ps1 | 120 min |
| Hourly | monitoring/Find-CrashLoop.ps1 | 5 min |
| Daily | monitoring/Test-DiskHealth.ps1 | 5 min |
| Daily, after backup window | monitoring/Test-BackupFreshness.ps1 | 5 min |
| Daily | monitoring/Test-DefenderHealth.ps1 | 5 min |
| Weekly | monitoring/Get-NetworkBaseline.ps1 | 5 min |
| Daily | security/Find-UnauthorizedRemoteAccess.ps1 | 10 min |
| Weekly | security/Get-LocalAdminAudit.ps1 | 5 min |
| Monthly | security/Set-EventLogSizes.ps1, security/Get-SmbV1Status.ps1 | 5 min |
| Monthly, and at onboarding | security/Set-DentalDefenderExclusions.ps1 | 5 min |
| Patch window | updates/Invoke-WindowsUpdate.ps1 | 120 min |
| Once, then after hardware changes | diagnostics/Test-Win11Eligibility.ps1 | 5 min |

On demand only: updates/Reset-WindowsUpdate, diagnostics/Find-ServiceTaskCulprit, diagnostics/Get-HardwareSummary, incident-response/Collect-IncidentEvidence, backup/Setup-ODMariaBackupTask, hardware/Disable-UsbHubPowerSaving, maintenance/PC-Cleanup, maintenance/Clear-BrowserCache.

## NinjaOne setup

- Run every scheduled script as SYSTEM except Clear-BrowserCache, which needs the logged-on user.
- Ticket condition: script result = failure. Nothing else. Exit 1 is the only signal that means a human is needed.
- Custom fields (device, text) the scripts write to: `localAdmins`, `smb1Status`, `diskSummary`, `win11Eligible`, `win11Blockers`, `defenderStatus`, `netBaseline`. Scripts check for `Ninja-Property-Set` and skip silently outside Ninja.
- Allowlists and expected lists to fill before first run: `$AllowedScreenConnectInstances` (remote access audit), `$ExpectedMembers` (admin audit), `$ExpectedDnsServers` (network baseline), `$ExcludeUsers` (stale profiles), `$Checks` (backup freshness), `$TimeZone` (baseline).
- Pilot detect-only scripts first (monitoring, security audits). They change nothing and show what the fleet looks like before the self-healing scripts start acting on it.

## Linting and tests

Every push runs `.github/workflows/lint.yml` in three steps:

1. A Windows PowerShell 5.1 parse check across every script.
2. Pester tests in `tests/` that enforce the conventions: every script has comment-based help with an exit contract, no `/ResetBase`, no `chkdsk /f` or `/r`, allowlists committed empty, and scripts that call themselves read-only don't call state-changing cmdlets.
3. PSScriptAnalyzer with the rules in `PSScriptAnalyzerSettings.psd1`. Excluded rules are listed there with the reason each one is off.

Run the tests locally with `Invoke-Pester -Path ./tests`.

## License

MIT. See [LICENSE](LICENSE).

## Author

Roy Burns
[linkedin.com/in/roy-burns-633942190](https://www.linkedin.com/in/roy-burns-633942190/)
