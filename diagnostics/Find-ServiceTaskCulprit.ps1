<#
.SYNOPSIS
    Finds what is stopping or restarting a Windows service on a schedule.
.DESCRIPTION
    Read-only. Dumps the service's config and recovery actions, walks every scheduled task and
    the scripts those tasks call looking for references to the service, pulls Service Control
    Manager events for it, correlates task runs against those events, and lists everything
    non-Microsoft that ran overnight. Set $ServiceName at the top.
.NOTES
    Run context : Elevated by hand, or SYSTEM through NinjaOne
    Exit        : Always 0. This is a diagnostic, read the output.
    Output      : Five sections. STRONG hits name the service, weak hits are generic stop/start
                  commands. Section 5 is the fallback when the service hangs and never logs a stop.
    Requires    : Task Scheduler Operational log enabled for sections 4 and 5. The script prints
                  the wevtutil line to enable it if it's off.
#>

& {
    $ServiceName = 'DentrixACEServer'
    $DaysBack    = 7     # how far back to read event logs
    $WindowMin   = 10    # minutes either side of a service event to look for task activity

    function Section($t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }

    # ---------- 1. The service itself ----------
    Section "1. Service details"
    $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    if (-not $svc) {
        Write-Warning "Service '$ServiceName' not found. Closest matches:"
        Get-CimInstance Win32_Service |
            Where-Object { $_.Name -match 'Dentrix|ACE' -or $_.DisplayName -match 'Dentrix|ACE' } |
            Format-Table Name, DisplayName, State, StartMode -AutoSize
        return
    }
    $svc | Format-List Name, DisplayName, State, StartMode, StartName, ProcessId, PathName

    $gs = Get-Service -Name $ServiceName
    "Depends on      : " + (($gs.ServicesDependedOn | ForEach-Object Name) -join ', ')
    "Dependents      : " + (($gs.DependentServices  | ForEach-Object Name) -join ', ')
    "`nRecovery actions (sc qfailure):"
    sc.exe qfailure $ServiceName | Select-Object -Skip 1

    # Patterns. Strong = names this service. Weak = generic service stop/start commands.
    $strong = ('(?i)' + [regex]::Escape($ServiceName) + '|' + [regex]::Escape($svc.DisplayName) + '|Dentrix')
    $weak   = '(?i)\bnet(1)?(\.exe)?\s+(stop|start)\b|\bsc(\.exe)?\s+(stop|start|config)\b|Stop-Service|Start-Service|Restart-Service|taskkill'
    $nameInEvent = ('(?i)' + [regex]::Escape($svc.DisplayName) + '|' + [regex]::Escape($ServiceName))

    # ---------- 2. Scheduled tasks ----------
    Section "2. Scheduled tasks that reference the service (directly or inside a script they call)"
    $taskHits = foreach ($t in Get-ScheduledTask) {
        foreach ($a in $t.Actions) {
            if ($a.CimClass.CimClassName -ne 'MSFT_TaskExecAction') { continue }
            $exe = [Environment]::ExpandEnvironmentVariables([string]$a.Execute)
            $arg = [Environment]::ExpandEnvironmentVariables([string]$a.Arguments)
            $cmd = "$exe $arg".Trim()

            $why = @()
            if     ($cmd -match $strong) { $why += 'STRONG: command line names the service' }
            elseif ($cmd -match $weak)   { $why += 'weak: command line has a generic stop/start' }

            # Pull any script paths out of the command line and read them
            $files = @([regex]::Matches($cmd, '(?i)(?:[a-z]:\\|\\\\)[^"<>|*?]+?\.(?:bat|cmd|ps1|vbs|js|wsf)') | ForEach-Object Value)
            if ($a.WorkingDirectory -and $exe -and -not [IO.Path]::IsPathRooted($exe.Trim('"'))) {
                $files += Join-Path ([Environment]::ExpandEnvironmentVariables($a.WorkingDirectory)) $exe.Trim('"')
            }
            $scriptLines = @()
            foreach ($f in ($files | Select-Object -Unique)) {
                if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
                $m = Select-String -LiteralPath $f -Pattern $strong -ErrorAction SilentlyContinue
                if ($m) {
                    $why += "STRONG: script names the service ($f)"
                    $scriptLines += $m | ForEach-Object { "{0}:{1}: {2}" -f (Split-Path $f -Leaf), $_.LineNumber, $_.Line.Trim() }
                } else {
                    $m = Select-String -LiteralPath $f -Pattern $weak -ErrorAction SilentlyContinue
                    if ($m) {
                        $why += "weak: script has generic stop/start ($f)"
                        $scriptLines += $m | ForEach-Object { "{0}:{1}: {2}" -f (Split-Path $f -Leaf), $_.LineNumber, $_.Line.Trim() }
                    }
                }
            }

            if ($why) {
                $info = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                # Pre-assigned rather than inline: PS 5.1 rejects a bare if as a hashtable value
                $lastResult = ''
                if ($info -and $null -ne $info.LastTaskResult) { $lastResult = '0x{0:X}' -f $info.LastTaskResult }
                [pscustomobject]@{
                    Task        = $t.TaskPath + $t.TaskName
                    State       = $t.State
                    RunAs       = $t.Principal.UserId
                    Triggers    = ($t.Triggers | ForEach-Object { ($_.CimClass.CimClassName -replace 'MSFT_Task','') + ' ' + $_.StartBoundary }) -join ' | '
                    LastRun     = $info.LastRunTime
                    LastResult  = $lastResult
                    NextRun     = $info.NextRunTime
                    Command     = $cmd
                    Why         = $why -join ' / '
                    ScriptLines = $scriptLines -join "`n              "
                }
            }
        }
    }
    if ($taskHits) {
        $taskHits | Sort-Object { $_.Why -notmatch 'STRONG' }, Task | Format-List
    } else {
        "No scheduled task references the service or a stop/start command."
    }

    # ---------- 3. Service Control Manager events ----------
    Section "3. System log events for this service, last $DaysBack days"
    $since = (Get-Date).AddDays(-$DaysBack)
    $scm = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager'; StartTime=$since } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match $nameInEvent } | Sort-Object TimeCreated
    if ($scm) {
        $scm | Select-Object TimeCreated, Id, @{n='Message';e={ ($_.Message -split "`r?`n")[0] }} | Format-Table -AutoSize -Wrap
    } else {
        "No SCM events mention the service. If it hangs in Stopping it may never log a 'stopped' event, so check section 5."
    }

    # ---------- 4. Task activity around those events ----------
    Section "4. Non-Microsoft tasks that ran within $WindowMin min of those events"
    $tsLog = Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational' -ErrorAction SilentlyContinue
    $taskRuns = @()
    if (-not $tsLog.IsEnabled) {
        Write-Warning "Task Scheduler history is OFF on this box. Turn it on and check again tomorrow:"
        "    wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true"
    } else {
        $taskRuns = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-TaskScheduler/Operational'; Id=200; StartTime=$since } -ErrorAction SilentlyContinue |
            ForEach-Object {
                [pscustomobject]@{ Time = $_.TimeCreated; Task = [string]$_.Properties[0].Value; Action = [string]$_.Properties[1].Value }
            } | Where-Object { $_.Task -notlike '\Microsoft\*' }
        "Oldest task history record: " + $(if ($taskRuns) { ($taskRuns | Sort-Object Time | Select-Object -First 1).Time } else { 'none in range' })

        # Collapse bursts of service events into one anchor each
        $anchors = @()
        foreach ($e in $scm) {
            if (-not $anchors -or ($e.TimeCreated - $anchors[-1]).TotalMinutes -gt $WindowMin) { $anchors += $e.TimeCreated }
        }
        foreach ($when in $anchors) {
            Write-Host "`n-- service event at $when" -ForegroundColor Yellow
            $near = $taskRuns | Where-Object { [math]::Abs(($_.Time - $when).TotalMinutes) -le $WindowMin } | Sort-Object Time
            if ($near) { $near | Format-Table Time, Task, Action -AutoSize -Wrap } else { "   no task activity in the window" }
        }
    }

    # ---------- 5. Fallback: everything non-Microsoft that runs overnight ----------
    Section "5. Non-Microsoft tasks that ran between 6 PM and 6 AM (count and usual start time)"
    $taskRuns | Where-Object { $_.Time.Hour -ge 18 -or $_.Time.Hour -lt 6 } |
        Group-Object Task | Sort-Object Count -Descending |
        Select-Object Count, Name,
            @{n='TypicalStart';e={ ($_.Group | Group-Object { $_.Time.ToString('HH:mm') } | Sort-Object Count -Descending | Select-Object -First 1).Name }},
            @{n='Action';e={ $_.Group[0].Action }} |
        Format-Table -AutoSize -Wrap
}
