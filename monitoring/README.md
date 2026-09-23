# monitoring

Detect-only scripts. They change nothing and exit 1 when something needs a human.

## Find-CrashLoop.ps1

Hourly. Counts service crashes (System 7031, 7034, 7024) and application crashes (Application 1000, 1026) over the last 60 minutes, grouped by offender. Anything at 5 or more is a loop. Prints the service's ImagePath so you can see if it's under nssm or another wrapper doing the restarting. Also checks how many days System and Application hold and flags under 7 days at 90% full, since a loop rolls the logs and eats the evidence.

Output per offender: type (service or application), name, crash count in the window, which event IDs fired, and the service's ImagePath. Then days of history held in System and Application with percent full. Exit 1 means either a loop over threshold or a log rolling under 7 days.

## Test-DiskHealth.ps1

Daily. Get-PhysicalDisk health and operational status, then Get-StorageReliabilityCounter for uncorrected read and write errors, wear, temperature, and power-on hours. Exit 1 on anything not Healthy or any counter over threshold. Prints HDD vs SSD per disk, which tells you which boxes PC-Cleanup won't help. Writes custom field `diskSummary`.

Disks behind a RAID controller may not show. Use the controller tool on those.

## Test-BackupFreshness.ps1

Daily, a couple hours after the backup window. Each entry in `$Checks` names a path, a filename filter, a max age, a minimum size, and optionally a status log and OK marker. The newest matching file has to be young enough and big enough, and the status log's last line has to say OK. A path that doesn't exist is skipped, so one script runs on every server and only bites where a job is configured.

Ships with the Open Dental MariaBackup check matching backup/Setup-ODMariaBackupTask.ps1. Add Eaglesoft, Dentrix, or image store checks the same way.

## Test-DefenderHealth.ps1

Daily. Checks the AM service, antivirus enabled, real-time protection, behavior monitoring, tamper protection, cloud-delivered protection, signature age under 3 days, quick scan under 7 days, and that Defender isn't in passive mode. If a third-party AV is registered with Security Center it checks that instead and expects Defender to be passive. Exit 1 on any failed check. Writes custom field `defenderStatus`.

Output: one PASS or FAIL line per check with the actual value, so the ticket says what's wrong without a second look.

## Get-NetworkBaseline.ps1

Weekly, or on a network-change condition. Records the active adapter's IP, prefix, DHCP or static, gateway, DNS servers, MAC, link speed, domain, and the public IP and ISP. Compares DNS against `$ExpectedDnsServers` and flags anything else. Exit 0 by default, exit 1 only when `$TicketOnUnexpectedDns` is on and DNS doesn't match. Writes custom field `netBaseline`.

Fill `$ExpectedDnsServers` per site or device group with the gateway, DC, or filtering DNS in use. Unexpected DNS on a managed machine is a misconfiguration at best. Set `$LookupPublic` to `$false` where outbound web calls are blocked.

## Configuration reference

| Script | Variable | Default | Change it when |
|---|---|---|---|
| Find-CrashLoop | `$WindowMinutes` | 60 | Match the run interval |
| | `$MaxPerWindow` | 5 | Lower on servers, higher on kiosks with flaky apps |
| | `$MinRetentionDays` | 7 | Compliance wants more |
| Test-DiskHealth | `$MaxUncorrectedErrors` | 0 | Leave 0. Any uncorrected error is a replacement |
| | `$MaxWearPercent` | 90 | Replace SSDs earlier on critical servers |
| | `$MaxTempC` | 60 | Hot closets run higher, adjust after a baseline |
| | `$CustomField` | diskSummary | Match the Ninja field name |
| Test-BackupFreshness | `$Checks` | Open Dental MariaBackup | One entry per backup job: Name, Path, Filter, MaxAgeHours, MinSizeMB, optional StatusLog and OkMarker. Missing paths are skipped |
| Test-DefenderHealth | `$MaxSignatureAgeDays` | 3 | |
| | `$MaxQuickScanAgeDays` | 7 | |
| | `$RequireTamper` | true | false on builds where tamper protection isn't available |
| | `$RequireCloud` | true | false where outbound to Microsoft is blocked |
| | `$CustomField` | defenderStatus | Match the Ninja field name |
| Get-NetworkBaseline | `$ExpectedDnsServers` | empty (check off) | Gateway, DC, or filtering DNS per site. Wildcards allowed |
| | `$TicketOnUnexpectedDns` | false | true once the expected list is right |
| | `$LookupPublic` | true | false where outbound web is blocked |
| | `$CustomField` | netBaseline | Match the Ninja field name |
