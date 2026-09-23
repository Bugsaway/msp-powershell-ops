# incident-response

## Collect-IncidentEvidence.ps1

Read-only logical evidence collection for a compromised Windows endpoint, with emphasis on remote access tool artifacts. Nothing on the host is stopped, deleted, or changed.

Run locally as Administrator, or paste into Ninja as a PowerShell script and run as SYSTEM.

```powershell
# Local, defaults to C:\IR
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Collect-IncidentEvidence.ps1 -Collector "J. Smith" -CaseId "INC-1042"

# Write to a USB stick so you aren't writing onto the evidence disk
.\Collect-IncidentEvidence.ps1 -OutputRoot E:\ -CaseId "INC-1042"

# Faster run, skip the full C:\ listing and leave it as a folder
.\Collect-IncidentEvidence.ps1 -SkipFullListing -NoZip
```

Output lands at `<OutputRoot>\<CaseId>_<HOSTNAME>_<timestamp>.zip` with a `.sha256` beside it. The chain of custody log is `00_ChainOfCustody.txt` inside.

### Collection order

Volatile state first, then everything that survives a power-off.

1. Volatile: netstat, TCP connections with owning process, processes with hashes, services, scheduled tasks, logged-on users, DNS and ARP cache, local users and admins, shares, firewall rules, installed programs, Defender status
2. Event logs as .evtx plus pre-filtered CSVs for 7045 service installs, MsiInstaller, logons and account changes, 4688 process creation, and log-clear events
3. Registry: full SYSTEM, SOFTWARE, SECURITY, SAM hives, per-user NTUSER.DAT and UsrClass.dat, targeted exports of Run keys, Services, Uninstall, Winlogon, IFEO, USBSTOR, MountedDevices
4. Remote access tool folders (ScreenConnect, AnyDesk, TeamViewer, Splashtop, RustDesk, and a dozen others) with every config file dumped into one text file, plus the MSI cache inventory
5. Recycle Bin raw copy with the $I metadata decoded to CSV (original path, size, deletion time)
6. Per-user: Downloads, Desktop, Documents, Temp, Recent, PSReadLine history, Startup, full browser profiles, locked Chromium DBs pulled with esentutl, Outlook file listing
7. System artifacts: Prefetch, Amcache, SRUM, task XML, Defender quarantine and scan history, setupapi, recent file changes (45 days), executables in user-writable paths, Zone.Identifier on downloads, full disk listing
8. SHA256 manifest of everything collected, then zip and hash the zip

### After it runs

Record the package hash in the ticket. Copy the zip off the machine. Run Get-FileHash on the copy and confirm it matches. Then pull the drive, label it (site, hostname, date, your name, EVIDENCE DO NOT WIPE), bag it, and lock it up. Put a fresh SSD in for the rebuild rather than wiping the original.

Keep a plain text custody log in the ticket: date, time, what was collected, how, hash, where it's stored. That log is what makes the evidence worth anything to a carrier or a lawyer.

### Notes

- Takes 15 to 30 minutes per box. The full disk listing and browser copies are the slow parts.
- Leave the machine on until it finishes. Powered off loses live sessions and the chance to run this remotely.
- Robocopy runs with /R:0 so it won't hang on locked files. esentutl handles the ones that are always locked.
- When pasted into the Ninja editor there is no script file on disk, so the custody log records that instead of a script hash.
- The default CaseId is INC-<today>. Pass the real ticket number.
- Exit 1 only if not running elevated. Per-item failures are logged to `00_CollectionErrors.txt` inside the package and do not stop the run.

## Configuration reference

All parameters, no config block. Pass them on the command line or edit the defaults in the `param` block.

| Parameter | Default | Change it when |
|---|---|---|
| `-OutputRoot` | C:\IR | Writing to a USB drive so the collection isn't on the evidence disk |
| `-Collector` | current user | Your name for the custody log. Under SYSTEM it records the machine, so pass it |
| `-CaseId` | INC-today's date | Always pass the real ticket number |
| `-SkipFullListing` | off | Big disks where the full C:\ listing would take too long |
| `-NoZip` | off | Leaving the folder in place for a tool that reads it directly |

To add an artifact: copy any `Copy-Tree` or `Try-Run` line in the matching section and change the source path and label. The hash manifest and zip pick it up automatically.
