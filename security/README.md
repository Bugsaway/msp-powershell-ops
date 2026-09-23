# security

Audit and hardening scripts. Every finding here is also a HIPAA artifact if you keep the output.

## Find-UnauthorizedRemoteAccess.ps1

Daily on every endpoint. Looks for remote access tools four ways: services, uninstall registry (machine and every user hive), install folders under Program Files, ProgramData, and each user's AppData, and running processes with their live TCP connections. Anything not on the allowlist is reported. Exit 1.

For ScreenConnect it parses the 16-character instance ID out of the service name and the relay host out of the ImagePath, so the output tells you whose instance it is. Populate `$AllowedScreenConnectInstances` with your own instance IDs, taken from a known-good machine. With the list empty every ScreenConnect is flagged, which is the safe direction.

Output per finding: the source (service, installed, folder, or process), the tool name, and for services the state and ImagePath, for installs the version and install date, for folders the creation time, and for processes the PID, path, and every established remote address and port. That's enough to know what it is and where it's talking before you touch the machine.

Do not uninstall from this script. Ticket, then run incident-response/Collect-IncidentEvidence.ps1, then decide.

## Get-LocalAdminAudit.ps1

Weekly. Enumerates local Administrators through ADSI so orphaned SIDs show up instead of crashing Get-LocalGroupMember. Compares against `$ExpectedMembers`. Exit 1 on anything unexpected or any orphaned SID. Writes the full list to custom field `localAdmins`.

Add the local admin accounts in use to `$ExpectedMembers`. Output is one line per member marked ok or UNEXPECTED, with source and object class, so an unexpected entry shows whether it's a local account, a domain account, or a leftover SID.

## Set-EventLogSizes.ps1

Monthly or at onboarding. Detect-first, only raises a log that's under target, never shrinks. System and Application to 256 MB, Security to 1 GB (2 GB on a DC), PowerShell and TaskScheduler Operational up, and TaskScheduler history switched on since it's off by default and Find-ServiceTaskCulprit needs it. Prints how many days each log currently holds and points at Find-CrashLoop if it's under a week.

Default sizes on a busy domain controller can hold under two days of Security log, which isn't enough to reconstruct a weekend.

## Get-SmbV1Status.ps1

Monthly. Report only, exit 0 by default. Shows whether SMBv1 is enabled at the server config and feature level, whether the mrxsmb10 driver is loaded, and, the useful part, every inbound session and outbound connection currently negotiating a dialect under 2.0. That's the list of devices that will break if you turn it off. Writes custom field `smb1Status` as disabled, enabled idle, or enabled IN USE.

Set `$TicketIfEnabled = $true` once the fleet is clean and you want it to stay that way.

## Set-DentalDefenderExclusions.ps1

Monthly and in the new-workstation baseline. Detect-first per vendor: if the vendor's install path exists, the vendor's recommended path and process exclusions are compared against `Get-MpPreference` and only the missing ones are added. Vendors not on the box are skipped, so one script runs everywhere. Nothing is ever removed. Exit 1 if Add-MpPreference fails, which usually means tamper protection managed by MDM or Defender isn't the active AV.

Covers Dentrix, Eaglesoft (including the Sybase engine), Open Dental (including MariaDB and the backup folder), DEXIS, Sidexis, Carestream, and SOTA Image. Each vendor block in `$Vendors` has a detect list, a path list, and a process list. Check them against the vendor's current KB article before rolling to a group, since install paths move between versions.

Output: per vendor, installed or skipped, then each exclusion added with a plus sign, then totals. A clean re-run prints only the vendor lines.

## Configuration reference

| Script | Variable | Default | Change it when |
|---|---|---|---|
| Find-UnauthorizedRemoteAccess | `$AllowedScreenConnectInstances` | empty (all flagged) | Your own ScreenConnect instance IDs, from the service name on a known-good machine |
| | `$AllowedToolPatterns` | NinjaOne names | Add the RMM and remote tool you deploy on purpose |
| Get-LocalAdminAudit | `$ExpectedMembers` | Administrator, Domain Admins, Enterprise Admins | Add the local admin accounts in use |
| | `$FlagOrphanedSids` | true | false if old SIDs are known and tolerated |
| | `$CustomField` | localAdmins | Match the Ninja field name |
| Set-EventLogSizes | `$Targets` | System 256 MB, Application 256 MB, Security 1 GB, others | Raise for compliance retention. Never lowers |
| | `$SecurityOnDC` | 2 GB | |
| | `$EnableLogs` | TaskScheduler Operational | Add other logs that ship disabled |
| Get-SmbV1Status | `$TicketIfEnabled` | false | true once the fleet is clean |
| | `$CustomField` | smb1Status | Match the Ninja field name |
| Set-DentalDefenderExclusions | `$Vendors` | 7 dental vendors | One block per product: Name, Detect paths, Paths, Processes. Remove blocks for vendors you don't support, add blocks for ones you do |
