#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers a nightly Open Dental MariaDB backup job (mariabackup piped to 7-Zip).
.DESCRIPTION
    Run once, elevated, on the Open Dental server, or push through NinjaOne as SYSTEM.
    Creates the folder structure, writes a cmd wrapper that runs the mariabackup to 7z pipe,
    and registers a daily scheduled task running as SYSTEM. Re-running is safe, it overwrites
    the .bat and the task. Set $ArchiveDest to move the archives off the OS disk.
.NOTES
    Run context : Elevated once, or SYSTEM through NinjaOne
    Exit 0      : Task registered
    Throws      : mariabackup.exe or 7z.exe not found at the configured path
    Verify      : Start-ScheduledTask -TaskName 'OpenDental MariaBackup'
                  Get-Content C:\MariaBackupFiles\Logs\status.log -Tail 5
#>

$BackupTime = '11:00PM'   # pick a slot clear of other nightly jobs
$KeepDays   = 7           # local retention
$TaskName   = 'OpenDental MariaBackup'

$Root        = 'C:\MariaBackupFiles'          # scripts, logs, and the LSN checkpoint live here
$ArchiveDest = "$Root\FullBackups"             # where the nightly .7z archives land
                                              # point this at a data or external drive to keep
                                              # backups off the OS disk, e.g. 'D:\ODBackups' or 'E:\ODBackups'
$ScriptDir   = "$Root\Scripts"
$BatPath   = "$ScriptDir\od_backup.bat"
$MariaBin  = 'C:\Program Files\MariaDB 10.5\bin\mariabackup.exe'
$SevenZip  = 'C:\Program Files\7-Zip\7z.exe'

# Pre-checks
foreach ($exe in $MariaBin, $SevenZip) {
    if (-not (Test-Path $exe)) { throw "Not found: $exe" }
}

# Folders
foreach ($dir in $ArchiveDest, "$Root\RestoredBackups\RestoredFullBackup", "$Root\Logs", $ScriptDir) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

# The .bat that does the actual work. The pipe has to run under cmd.
# PowerShell 5.1 mangles binary data piped between two exes and the archive comes out corrupt.
$bat = @'
@echo off
setlocal
set "MB=__MARIABIN__"
set "SZ=__SEVENZIP__"
set "ROOT=__ROOT__"
set "DEST=__DEST__"
set "LSN=%ROOT%\RestoredBackups\RestoredFullBackup"
set "LOGDIR=%ROOT%\Logs"
set "KEEPDAYS=__KEEPDAYS__"

for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "STAMP=%%i"
set "OUT=%DEST%\opendental_bak_%STAMP%.xb.7z"
set "LOG=%LOGDIR%\mariabackup_%STAMP%.log"

"%MB%" --backup --databases="opendental mysql" --extra-lsndir="%LSN%" --target-dir="%DEST%" --user=root --stream=xbstream 2>"%LOG%" | "%SZ%" a -si "%OUT%" >"%LOGDIR%\7z_%STAMP%.log" 2>&1

rem In a pipe, errorlevel only reflects 7z. mariabackup's real result is the last line of its log.
findstr /c:"completed OK!" "%LOG%" >nul
if errorlevel 1 (
    echo %STAMP% FAILED see %LOG%>>"%LOGDIR%\status.log"
    if exist "%OUT%" del "%OUT%"
    exit /b 1
)

echo %STAMP% OK %OUT%>>"%LOGDIR%\status.log"

rem Prune only after a good run so a string of failures can't age out the last good backup
forfiles /p "%DEST%" /m opendental_bak_*.xb.7z /d -%KEEPDAYS% /c "cmd /c del @path" >nul 2>&1
forfiles /p "%LOGDIR%" /m *_*.log /d -30 /c "cmd /c del @path" >nul 2>&1
exit /b 0
'@
$bat = $bat.Replace('__MARIABIN__', $MariaBin).Replace('__SEVENZIP__', $SevenZip).Replace('__KEEPDAYS__', "$KeepDays").Replace('__ROOT__', $Root).Replace('__DEST__', $ArchiveDest)
Set-Content -Path $BatPath -Value $bat -Encoding ASCII

# Scheduled task, runs as SYSTEM whether or not anyone is logged in
$action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$BatPath`""
$trigger   = New-ScheduledTaskTrigger -Daily -At $BackupTime
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Task '$TaskName' registered for $BackupTime daily. Archives: $ArchiveDest"
Write-Host "Test now:  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Result:    Get-Content $Root\Logs\status.log -Tail 5"
