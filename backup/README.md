# backup

## Setup-ODMariaBackupTask.ps1

Registers a nightly mariabackup job for an Open Dental server on MariaDB 10.5. Run once elevated on the OD server or push through Ninja as SYSTEM. Re-running it is safe, it overwrites the .bat and the task.

What it does:

- Creates `C:\MariaBackupFiles` with FullBackups, RestoredBackups, Logs, and Scripts underneath
- Writes `C:\MariaBackupFiles\Scripts\od_backup.bat`, which does the actual work
- Registers the scheduled task `OpenDental MariaBackup` running as SYSTEM at 11:00 PM daily

Knobs at the top: `$BackupTime`, `$KeepDays` (7), `$TaskName`, `$ArchiveDest`, and the paths to mariabackup.exe and 7z.exe.

### Changing where the backups go

`$ArchiveDest` in the config block controls where the nightly archives land. It defaults to `C:\MariaBackupFiles\FullBackups`. To keep backups off the OS disk, point it at a data drive or an external drive before running the setup:

```powershell
$ArchiveDest = 'D:\ODBackups'      # second internal drive
$ArchiveDest = 'E:\ODBackups'      # external USB drive
```

The setup creates the folder, writes the path into the .bat, and the task uses it from then on. Re-run the setup after changing it. `$Root` stays on C: for the scripts, logs, and the LSN checkpoint, which is fine, they're small.

If the destination is a mapped drive letter, it won't exist for SYSTEM. Use a UNC path in the .bat directly, or keep the archive local and let a separate job move it. External USB drives need to be present at 11 PM or the run fails and status.log records it.

Update `monitoring/Test-BackupFreshness.ps1` to the same path so the freshness check looks in the right place.

### Why a .bat

Task Scheduler can't run a pipe directly, and PowerShell 5.1 corrupts binary data piped between two exes. The mariabackup to 7z pipe has to live in cmd.

### What the .bat does differently from a bare mariabackup command

- Dated archive names, one per night, pruned after `$KeepDays`. Writing to the same filename every night means 7z updates one archive in place and you only ever have one copy.
- Real success check. In a pipe the exit code only reflects 7z, so mariabackup can fail and the task still shows success. The .bat greps mariabackup's log for `completed OK!`, deletes the bad archive if it's missing, and exits 1.
- Prunes only after a good run so a string of failures can't age out the last good backup.
- No `--password` flag. Built for a blank root password, which is how OD ships. SYSTEM connects as root@localhost.
- Appends a one-line result to `Logs\status.log` every run. That file plus the exit code are the hook for a Ninja condition.

### Test it before trusting it

```powershell
Start-ScheduledTask -TaskName 'OpenDental MariaBackup'
Get-Content C:\MariaBackupFiles\Logs\status.log -Tail 5
```

Then prove a backup restores:

```bat
mkdir C:\MariaBackupFiles\RestoreTest
"C:\Program Files\7-Zip\7z.exe" x -so C:\MariaBackupFiles\FullBackups\opendental_bak_XXXX.xb.7z | "C:\Program Files\MariaDB 10.5\bin\mbstream.exe" -x -C C:\MariaBackupFiles\RestoreTest
"C:\Program Files\MariaDB 10.5\bin\mariabackup.exe" --prepare --target-dir=C:\MariaBackupFiles\RestoreTest
```

### Before rolling to more sites

- By default archives land on the same C: as the database. Set `$ArchiveDest` to another drive, and something still has to move them offsite.
- Blank root on a box holding PHI is worth fixing first. When you do, put the credentials in a `[mariabackup]` section of my.ini rather than on the command line so they don't show up in the task definition or process list.
- If 7z's default compression drags on bigger databases, add `-mx=3` after `a` in the .bat.

## Configuration reference

| Variable | Default | Change it when |
|---|---|---|
| `$BackupTime` | 11:00PM | Pick a slot clear of other nightly jobs and the RMM reboot |
| `$KeepDays` | 7 | Local retention. Offsite handles the rest |
| `$TaskName` | OpenDental MariaBackup | |
| `$Root` | C:\MariaBackupFiles | Scripts, logs, and the LSN checkpoint. Fine on C: |
| `$ArchiveDest` | `$Root\FullBackups` | A data or external drive. See the section above |
| `$MariaBin` | MariaDB 10.5 path | The installed MariaDB version |
| `$SevenZip` | 7-Zip path | |

The `--databases` list, the user, and the 7z compression level are in the `.bat` heredoc inside the script. Edit there if the database name or the root credential setup differs.
