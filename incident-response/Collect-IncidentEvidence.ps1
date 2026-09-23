<#
.SYNOPSIS
    Incident evidence collection for a compromised Windows endpoint. Run locally as Administrator or through NinjaOne as SYSTEM.

.DESCRIPTION
    Read-only logical collection for remote-access and endpoint compromise incidents.
    Copies evidence to an output folder, hashes every file, writes a chain of custody log,
    and zips the result. Does not modify, delete, or stop anything on the host.

    Collection order: volatile state first (network, processes, services, sessions),
    then event logs, registry, remote access tool artifacts, Recycle Bin, user profiles, system artifacts.

.PARAMETER OutputRoot
    Where to write the collection. Use a USB drive if you have one (E:\ etc) so you are not
    writing onto the evidence disk. Defaults to C:\IR if nothing is passed.

.PARAMETER Collector
    Your name for the chain of custody log.

.PARAMETER CaseId
    Ticket or case number for the log. Defaults to INC-<today's date>.

.PARAMETER SkipFullListing
    Skip the full C:\ directory listing. Saves a lot of time on big disks, at the cost of the
    single most useful timeline artifact once the box is gone.

.PARAMETER NoZip
    Leave the collection as a folder instead of zipping it.

.NOTES
    Run context : Elevated by hand, or SYSTEM through NinjaOne
    Exit 0      : Collection complete. Per-item failures are logged to 00_CollectionErrors.txt and do not stop the run
    Exit 1      : Not running elevated
    Runtime     : 15 to 30 minutes. Full disk listing and browser profiles are the slow parts
    Output      : <OutputRoot>\<CaseId>_<host>_<stamp>.zip plus a .sha256 beside it. Chain of custody log inside
.EXAMPLE
    # Local, default output C:\IR
    Set-ExecutionPolicy Bypass -Scope Process -Force
    .\Collect-IncidentEvidence.ps1 -Collector "J. Smith" -CaseId "INC-1042"

    # Via NinjaOne: paste as a PowerShell script, run as SYSTEM. Output lands in C:\IR\<case>_<host>_<stamp>.zip
    # Pull the zip with the Ninja file browser, or robocopy it to a server share afterward.
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = "C:\IR",
    [string]$Collector  = "$env:USERDOMAIN\$env:USERNAME",
    [string]$CaseId     = ("INC-" + (Get-Date -Format "yyyy-MMdd")),
    [switch]$SkipFullListing,
    [switch]$NoZip
)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Continue"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Run this as Administrator. Exiting." -ForegroundColor Red
    exit 1
}

$hostName  = $env:COMPUTERNAME
$stamp     = Get-Date -Format "yyyyMMdd_HHmmss"
$caseDir   = Join-Path $OutputRoot "$CaseId`_$hostName`_$stamp"
$log       = Join-Path $caseDir "00_ChainOfCustody.txt"
$errLog    = Join-Path $caseDir "00_CollectionErrors.txt"

New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
Write-Host "Starting collection -> $caseDir" -ForegroundColor Cyan

function Log {
    param([string]$Msg)
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Msg
    Write-Host $line
    Add-Content -Path $log -Value $line
}

function Invoke-Step {
    param([string]$Label, [scriptblock]$Action)
    try {
        & $Action
        Log "OK    $Label"
    } catch {
        Log "FAIL  $Label  ($($_.Exception.Message))"
        Add-Content -Path $errLog -Value "$Label`n$($_ | Out-String)`n"
    }
}

function Copy-Tree {
    # Read-only copy that preserves timestamps and does not retry locked files forever
    param([string]$Source, [string]$Dest, [string]$Label)
    if (Test-Path $Source) {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
        $null = robocopy $Source $Dest /E /COPY:DAT /DCOPY:T /R:0 /W:0 /XJ /NFL /NDL /NJH /NJS /NP
        # robocopy exit codes 0-7 are success variants
        if ($LASTEXITCODE -le 7) { Log "OK    $Label  <- $Source" } else { Log "WARN  $Label  robocopy exit $LASTEXITCODE  <- $Source" }
    } else {
        Log "SKIP  $Label  (not present) $Source"
    }
}

# Script hash for the custody record. Pasted into the Ninja editor there is no file on disk, so note that instead.
$scriptHash = "n/a (no script file on disk, run from RMM editor or console paste)"
if ($MyInvocation.MyCommand.Path -and (Test-Path $MyInvocation.MyCommand.Path)) {
    $scriptHash = (Get-FileHash -Algorithm SHA256 $MyInvocation.MyCommand.Path).Hash
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
Log "=== Incident Evidence Collection ==="
Log "Case:        $CaseId"
Log "Host:        $hostName"
Log "Collector:   $Collector"
Log "Run as:      $env:USERDOMAIN\$env:USERNAME"
Log "Output:      $caseDir"
Log "Script hash: $scriptHash"
Log "Method:      Live logical collection, read-only, no host changes"
Log "Note:        Collection written to $OutputRoot. If this is the evidence disk, note that in the custody record."
Log ""

# ---------------------------------------------------------------------------
# 1. Volatile state (do this first)
# ---------------------------------------------------------------------------
$vol = Join-Path $caseDir "01_Volatile"
New-Item -ItemType Directory -Path $vol -Force | Out-Null
Log "--- 1. Volatile state ---"

Invoke-Step "System info"        { systeminfo | Out-File "$vol\systeminfo.txt" -Encoding UTF8 }
Invoke-Step "Date and timezone"  { Get-Date | Out-File "$vol\datetime.txt"; tzutil /g | Out-File "$vol\timezone.txt" }
Invoke-Step "Uptime"             { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime | Out-File "$vol\lastboot.txt" }
Invoke-Step "Logged on users"    { query user 2>&1 | Out-File "$vol\query_user.txt"; quser 2>&1 | Out-File "$vol\quser.txt" -Append }
Invoke-Step "Net sessions"       { net session 2>&1 | Out-File "$vol\net_session.txt" }
Invoke-Step "netstat -anob"      { netstat -anob | Out-File "$vol\netstat_anob.txt" }
Invoke-Step "TCP connections"    { Get-NetTCPConnection | Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess,@{n="Process";e={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName}} | Export-Csv "$vol\tcp_connections.csv" -NoTypeInformation }
Invoke-Step "DNS cache"          { ipconfig /displaydns | Out-File "$vol\dns_cache.txt"; Get-DnsClientCache | Export-Csv "$vol\dns_cache.csv" -NoTypeInformation }
Invoke-Step "ipconfig /all"      { ipconfig /all | Out-File "$vol\ipconfig_all.txt" }
Invoke-Step "ARP table"          { arp -a | Out-File "$vol\arp.txt" }
Invoke-Step "Routes"             { route print | Out-File "$vol\route_print.txt" }
Invoke-Step "Hosts file"         { Copy-Item "$env:SystemRoot\System32\drivers\etc\hosts" "$vol\hosts.txt" -Force }
Invoke-Step "Processes (detail)" {
    Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine,CreationDate,
        @{n="Owner";e={ $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue; "$($o.Domain)\$($o.User)" }} |
        Export-Csv "$vol\processes.csv" -NoTypeInformation
}
Invoke-Step "Process hashes"     {
    Get-Process | Where-Object { $_.Path } | Select-Object Id,ProcessName,Path,@{n="SHA256";e={ (Get-FileHash $_.Path -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash }} |
        Sort-Object Path -Unique | Export-Csv "$vol\process_hashes.csv" -NoTypeInformation
}
Invoke-Step "Services (all)"     { Get-CimInstance Win32_Service | Select-Object Name,DisplayName,State,StartMode,StartName,PathName,ProcessId | Export-Csv "$vol\services.csv" -NoTypeInformation }
Invoke-Step "Services (sc query)" { sc.exe query type= service state= all | Out-File "$vol\sc_query_all.txt" }
Invoke-Step "Scheduled tasks"    {
    Get-ScheduledTask | ForEach-Object {
        $t = $_
        $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        [pscustomobject]@{
            TaskName = $t.TaskName
            Path     = $t.TaskPath
            State    = $t.State
            Author   = $t.Author
            RunAs    = $t.Principal.UserId
            Actions  = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join " | "
            LastRun  = $i.LastRunTime
            NextRun  = $i.NextRunTime
        }
    } | Export-Csv "$vol\scheduled_tasks.csv" -NoTypeInformation
    schtasks /query /fo CSV /v | Out-File "$vol\schtasks_verbose.csv" -Encoding UTF8
}
Invoke-Step "Local users"        { Get-LocalUser | Select-Object Name,Enabled,LastLogon,PasswordLastSet,Description,SID | Export-Csv "$vol\local_users.csv" -NoTypeInformation }
Invoke-Step "Local admins"       { Get-LocalGroupMember Administrators | Select-Object Name,ObjectClass,PrincipalSource | Export-Csv "$vol\local_admins.csv" -NoTypeInformation }
Invoke-Step "RDP group"          { Get-LocalGroupMember "Remote Desktop Users" -ErrorAction SilentlyContinue | Export-Csv "$vol\rdp_users.csv" -NoTypeInformation }
Invoke-Step "Mapped drives"      { net use 2>&1 | Out-File "$vol\net_use.txt"; Get-SmbMapping -ErrorAction SilentlyContinue | Export-Csv "$vol\smb_mappings.csv" -NoTypeInformation }
Invoke-Step "Shares"             { Get-SmbShare | Export-Csv "$vol\smb_shares.csv" -NoTypeInformation }
Invoke-Step "Firewall rules"     { Get-NetFirewallRule | Where-Object Enabled -eq True | Select-Object DisplayName,Direction,Action,Profile,Program | Export-Csv "$vol\firewall_rules.csv" -NoTypeInformation }
Invoke-Step "Installed programs" {
    $paths = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
             "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
             "HKU:\*\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    if (-not (Get-PSDrive HKU -ErrorAction SilentlyContinue)) { New-PSDrive HKU Registry HKEY_USERS | Out-Null }
    Get-ItemProperty $paths -ErrorAction SilentlyContinue | Select-Object DisplayName,DisplayVersion,Publisher,InstallDate,InstallLocation,UninstallString,PSPath | Export-Csv "$vol\installed_programs.csv" -NoTypeInformation
}
Invoke-Step "Defender status"    { Get-MpComputerStatus | Out-File "$vol\defender_status.txt"; Get-MpThreatDetection -ErrorAction SilentlyContinue | Export-Csv "$vol\defender_detections.csv" -NoTypeInformation; Get-MpPreference | Out-File "$vol\defender_prefs.txt" }

# ---------------------------------------------------------------------------
# 2. Event logs
# ---------------------------------------------------------------------------
$evt = Join-Path $caseDir "02_EventLogs"
New-Item -ItemType Directory -Path $evt -Force | Out-Null
Log "--- 2. Event logs ---"

$logsToExport = @(
    "System", "Application", "Security", "Setup",
    "Microsoft-Windows-PowerShell/Operational",
    "Windows PowerShell",
    "Microsoft-Windows-TaskScheduler/Operational",
    "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational",
    "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational",
    "Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational",
    "Microsoft-Windows-WMI-Activity/Operational",
    "Microsoft-Windows-Windows Defender/Operational",
    "Microsoft-Windows-Bits-Client/Operational",
    "Microsoft-Windows-Sysmon/Operational",
    "Microsoft-Windows-Shell-Core/Operational",
    "Microsoft-Windows-NetworkProfile/Operational",
    "Microsoft-Windows-WinRM/Operational",
    "Microsoft-Windows-Kernel-PnP/Configuration"
)
foreach ($l in $logsToExport) {
    $safe = ($l -replace '[\\/ ]', '_') + ".evtx"
    Invoke-Step "evtx $l" {
        $r = wevtutil epl "$l" "$evt\$safe" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "wevtutil: $r" }
    }
}
# Raw copy of the whole log folder as a backstop
Copy-Tree "$env:SystemRoot\System32\winevt\Logs" "$evt\RawLogs" "Raw winevt copy"

# Quick-read extracts for the things that matter most
Invoke-Step "7045 service installs (csv)" {
    Get-WinEvent -FilterHashtable @{LogName="System"; Id=7045} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated,Id,@{n="Message";e={$_.Message -replace "`r`n"," | "}} |
        Export-Csv "$evt\Extract_7045_ServiceInstalls.csv" -NoTypeInformation
}
Invoke-Step "MSI installer events (csv)" {
    Get-WinEvent -FilterHashtable @{LogName="Application"; ProviderName="MsiInstaller"} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated,Id,@{n="Message";e={$_.Message -replace "`r`n"," | "}} |
        Export-Csv "$evt\Extract_MsiInstaller.csv" -NoTypeInformation
}
Invoke-Step "Logon events 4624/4625/4634/4648/4672 (csv)" {
    Get-WinEvent -FilterHashtable @{LogName="Security"; Id=4624,4625,4634,4648,4672,4720,4722,4724,4728,4732,4738} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated,Id,@{n="Message";e={$_.Message -replace "`r`n"," | "}} |
        Export-Csv "$evt\Extract_Security_Logons_Accounts.csv" -NoTypeInformation
}
Invoke-Step "Security 4688 process creation (csv)" {
    Get-WinEvent -FilterHashtable @{LogName="Security"; Id=4688} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated,Id,@{n="Message";e={$_.Message -replace "`r`n"," | "}} |
        Export-Csv "$evt\Extract_Security_4688.csv" -NoTypeInformation
}
Invoke-Step "Log clear events 1102/104 (csv)" {
    $a = Get-WinEvent -FilterHashtable @{LogName="Security"; Id=1102} -ErrorAction SilentlyContinue
    $b = Get-WinEvent -FilterHashtable @{LogName="System"; Id=104} -ErrorAction SilentlyContinue
    ($a + $b) | Select-Object TimeCreated,Id,LogName,@{n="Message";e={$_.Message -replace "`r`n"," | "}} |
        Export-Csv "$evt\Extract_LogCleared.csv" -NoTypeInformation
}

# ---------------------------------------------------------------------------
# 3. Registry
# ---------------------------------------------------------------------------
$reg = Join-Path $caseDir "03_Registry"
New-Item -ItemType Directory -Path $reg -Force | Out-Null
Log "--- 3. Registry ---"

# Full hive saves (works live via reg save)
foreach ($h in "SYSTEM","SOFTWARE","SECURITY","SAM") {
    Invoke-Step "reg save $h" {
        $r = reg save "HKLM\$h" "$reg\$h.hiv" /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw "reg save: $r" }
    }
}
# Per-user hives for every loaded profile
Get-ChildItem "C:\Users" -Directory | ForEach-Object {
    $u = $_.Name
    $nt = Join-Path $_.FullName "NTUSER.DAT"
    $uc = Join-Path $_.FullName "AppData\Local\Microsoft\Windows\UsrClass.dat"
    New-Item -ItemType Directory -Path "$reg\Users\$u" -Force | Out-Null
    if (Test-Path $nt) { Invoke-Step "NTUSER.DAT $u" { $null = robocopy $_.FullName "$reg\Users\$u" NTUSER.DAT /COPY:DAT /R:0 /W:0 /B /NFL /NDL /NJH /NJS 2>&1 ; if ($LASTEXITCODE -gt 7) { esentutl /y "$nt" /d "$reg\Users\$u\NTUSER.DAT" /o | Out-Null } } }
    if (Test-Path $uc) { Invoke-Step "UsrClass.dat $u" { esentutl /y "$uc" /d "$reg\Users\$u\UsrClass.dat" /o | Out-Null } }
}
# Targeted text exports for quick reading
$regTargets = @{
    "Run_HKLM"            = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    "RunOnce_HKLM"        = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    "Run_HKLM_WOW"        = "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    "Services"            = "HKLM\SYSTEM\CurrentControlSet\Services"
    "Uninstall_HKLM"      = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    "Uninstall_HKLM_WOW"  = "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    "Winlogon"            = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    "IFEO"                = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
    "TermService"         = "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server"
    "NetworkList"         = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList"
    "USBSTOR"             = "HKLM\SYSTEM\CurrentControlSet\Enum\USBSTOR"
    "MountedDevices"      = "HKLM\SYSTEM\MountedDevices"
    "PolicyScripts"       = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts"
}
foreach ($k in $regTargets.Keys) {
    Invoke-Step "reg export $k" {
        $r = reg export $regTargets[$k] "$reg\$k.reg" /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw "reg export: $r" }
    }
}
Invoke-Step "ScreenConnect service keys" {
    reg query "HKLM\SYSTEM\CurrentControlSet\Services" /s /f "ScreenConnect" /k 2>&1 | Out-File "$reg\ScreenConnect_ServiceKeys.txt"
    reg query "HKLM\SOFTWARE" /s /f "ScreenConnect" 2>&1 | Out-File "$reg\ScreenConnect_SOFTWARE_search.txt"
}
Invoke-Step "Per-user Run keys" {
    if (-not (Get-PSDrive HKU -ErrorAction SilentlyContinue)) { New-PSDrive HKU Registry HKEY_USERS | Out-Null }
    Get-ChildItem "HKU:\" | ForEach-Object {
        $sid = $_.PSChildName
        foreach ($sub in "Run","RunOnce") {
            $p = "HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\$sub"
            if (Test-Path $p) { "[$sid] $sub" | Out-File "$reg\PerUser_Run.txt" -Append; Get-ItemProperty $p | Out-File "$reg\PerUser_Run.txt" -Append }
        }
    }
}

# ---------------------------------------------------------------------------
# 4. ScreenConnect and other remote access artifacts
# ---------------------------------------------------------------------------
$sc = Join-Path $caseDir "04_RemoteAccess"
New-Item -ItemType Directory -Path $sc -Force | Out-Null
Log "--- 4. Remote access artifacts ---"

$scRoots = @(
    "${env:ProgramFiles(x86)}", "$env:ProgramFiles", "$env:ProgramData",
    "$env:SystemRoot\Temp", "$env:SystemRoot\Installer"
)
foreach ($root in $scRoots) {
    if (Test-Path $root) {
        Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "ScreenConnect|ConnectWise|AnyDesk|TeamViewer|Splashtop|LogMeIn|RustDesk|Atera|SimpleHelp|Supremo|RemotePC|GoToAssist|UltraViewer|Zoho|MeshAgent|Syncro|NinjaRMM|NinjaOne|Level" } | ForEach-Object {
            $dest = Join-Path $sc ("{0}__{1}" -f ($root -replace '[:\\]','_'), $_.Name)
            Copy-Tree $_.FullName $dest "RA folder $($_.Name)"
        }
    }
}
# MSI cache inventory
Invoke-Step "Installer MSI cache inventory" {
    Get-ChildItem "$env:SystemRoot\Installer" -Filter *.msi -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ File=$_.FullName; Size=$_.Length; Created=$_.CreationTime; Modified=$_.LastWriteTime; SHA256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    } | Export-Csv "$sc\Installer_msi_inventory.csv" -NoTypeInformation
}
Invoke-Step "Remote access config dump" {
    Get-ChildItem $sc -Recurse -Include "system.config","app.config","*.config" -ErrorAction SilentlyContinue | ForEach-Object {
        "==== $($_.FullName)" | Out-File "$sc\_AllConfigs.txt" -Append
        Get-Content $_.FullName -ErrorAction SilentlyContinue | Out-File "$sc\_AllConfigs.txt" -Append
        "" | Out-File "$sc\_AllConfigs.txt" -Append
    }
}
Invoke-Step "Per-user remote access folders" {
    Get-ChildItem "C:\Users" -Directory | ForEach-Object {
        $u = $_.Name
        foreach ($sub in "AppData\Local","AppData\Roaming","AppData\Local\Temp") {
            $base = Join-Path $_.FullName $sub
            if (Test-Path $base) {
                Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "ScreenConnect|ConnectWise|AnyDesk|TeamViewer|Splashtop|RustDesk|SimpleHelp|Supremo|UltraViewer" } | ForEach-Object {
                    Copy-Tree $_.FullName (Join-Path $sc "User_$u`__$($sub -replace '\\','_')__$($_.Name)") "User RA folder $u $($_.Name)"
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Recycle Bin (all users, includes $I metadata)
# ---------------------------------------------------------------------------
$rb = Join-Path $caseDir "05_RecycleBin"
New-Item -ItemType Directory -Path $rb -Force | Out-Null
Log "--- 5. Recycle Bin ---"
Copy-Tree 'C:\$Recycle.Bin' "$rb\Recycle.Bin" "Recycle Bin raw"
Invoke-Step "Recycle Bin listing" {
    Get-ChildItem 'C:\$Recycle.Bin' -Recurse -Force -ErrorAction SilentlyContinue |
        Select-Object FullName,Length,CreationTime,LastWriteTime,LastAccessTime |
        Export-Csv "$rb\RecycleBin_listing.csv" -NoTypeInformation
}
Invoke-Step "Recycle Bin `$I decode" {
    # $I files: 8 bytes header, 8 bytes size, 8 bytes FILETIME deleted, 4 bytes name length (v2), then UTF-16 name
    Get-ChildItem 'C:\$Recycle.Bin' -Recurse -Force -Filter '$I*' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $b = [IO.File]::ReadAllBytes($_.FullName)
            $ver = [BitConverter]::ToInt64($b,0)
            $size = [BitConverter]::ToInt64($b,8)
            $ft = [BitConverter]::ToInt64($b,16)
            $deleted = [DateTime]::FromFileTimeUtc($ft)
            if ($ver -eq 2) { $len = [BitConverter]::ToInt32($b,24); $name = [Text.Encoding]::Unicode.GetString($b,28,($len-1)*2) }
            else { $name = [Text.Encoding]::Unicode.GetString($b,24,$b.Length-24).TrimEnd([char]0) }
            [pscustomobject]@{ IFile=$_.FullName; OriginalPath=$name; OriginalSize=$size; DeletedUTC=$deleted; SID=$_.Directory.Name }
        } catch { [pscustomobject]@{ IFile=$_.FullName; OriginalPath="DECODE FAIL"; OriginalSize=$null; DeletedUTC=$null; SID=$_.Directory.Name } }
    } | Sort-Object DeletedUTC | Export-Csv "$rb\RecycleBin_Decoded.csv" -NoTypeInformation
}

# ---------------------------------------------------------------------------
# 6. User profiles: browsers, downloads, recent, temp, shell history
# ---------------------------------------------------------------------------
$up = Join-Path $caseDir "06_UserProfiles"
New-Item -ItemType Directory -Path $up -Force | Out-Null
Log "--- 6. User profiles ---"

Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin "Public","Default","Default User","All Users" } | ForEach-Object {
    $u = $_.Name
    $h = $_.FullName
    $d = Join-Path $up $u
    Log "  user: $u"
    Copy-Tree "$h\Downloads"  "$d\Downloads"  "$u Downloads"
    Copy-Tree "$h\Desktop"    "$d\Desktop"    "$u Desktop"
    Copy-Tree "$h\Documents"  "$d\Documents"  "$u Documents"
    Copy-Tree "$h\AppData\Local\Temp" "$d\Temp" "$u Temp"
    Copy-Tree "$h\AppData\Roaming\Microsoft\Windows\Recent" "$d\Recent" "$u Recent (LNK + jumplists)"
    Copy-Tree "$h\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine" "$d\PSReadLine" "$u PSReadLine history"
    Copy-Tree "$h\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup" "$d\Startup" "$u Startup"
    # Browsers: whole profile folders, locked DB files will be skipped by robocopy, so also use esentutl for the key DBs below
    Copy-Tree "$h\AppData\Local\Google\Chrome\User Data"      "$d\Chrome"  "$u Chrome"
    Copy-Tree "$h\AppData\Local\Microsoft\Edge\User Data"     "$d\Edge"    "$u Edge"
    Copy-Tree "$h\AppData\Roaming\Mozilla\Firefox\Profiles"   "$d\Firefox" "$u Firefox"
    Copy-Tree "$h\AppData\Local\BraveSoftware\Brave-Browser\User Data" "$d\Brave" "$u Brave"
    # Outlook OST/PST listing only (too large to copy, and the mailbox is in M365 anyway)
    Invoke-Step "$u Outlook file listing" {
        Get-ChildItem "$h\AppData\Local\Microsoft\Outlook" -Include *.ost,*.pst,*.nst -Recurse -ErrorAction SilentlyContinue |
            Select-Object FullName,Length,CreationTime,LastWriteTime | Export-Csv "$d\Outlook_files.csv" -NoTypeInformation
    }
    # Full profile file listing with timestamps for timeline work
    Invoke-Step "$u profile listing" {
        Get-ChildItem $h -Recurse -Force -ErrorAction SilentlyContinue |
            Select-Object FullName,Length,CreationTime,LastWriteTime,LastAccessTime,Attributes |
            Export-Csv "$d\_FullListing.csv" -NoTypeInformation
    }
}
# Locked browser DBs: force copy with esentutl for Chromium History/Cookies/Login Data
Invoke-Step "Locked browser DB copies" {
    Get-ChildItem "C:\Users\*\AppData\Local\*\*\User Data\*\" -Include "History","Cookies","Login Data","Web Data","Network\Cookies" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName -replace '^C:\\Users\\',''
        $dst = Join-Path "$up\_LockedDBCopies" ($rel -replace '[:]','')
        New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
        if (-not (Test-Path $dst)) { esentutl /y "$($_.FullName)" /d "$dst" /o | Out-Null }
    }
}

# ---------------------------------------------------------------------------
# 7. System artifacts (execution and timeline evidence)
# ---------------------------------------------------------------------------
$sys = Join-Path $caseDir "07_SystemArtifacts"
New-Item -ItemType Directory -Path $sys -Force | Out-Null
Log "--- 7. System artifacts ---"

Copy-Tree "$env:SystemRoot\Prefetch" "$sys\Prefetch" "Prefetch"
Copy-Tree "$env:SystemRoot\Temp"     "$sys\WindowsTemp" "Windows Temp"
Copy-Tree "$env:SystemRoot\System32\Tasks" "$sys\TasksXML" "Scheduled task XML"
Copy-Tree "$env:SystemRoot\System32\LogFiles" "$sys\LogFiles" "System32 LogFiles"
Copy-Tree "$env:SystemRoot\System32\sru" "$sys\SRUM" "SRUM (network usage per app)"
Copy-Tree "$env:SystemRoot\AppCompat\Programs" "$sys\Amcache" "Amcache"
Copy-Tree "$env:ProgramData\Microsoft\Windows Defender\Support" "$sys\DefenderSupport" "Defender support logs"
Copy-Tree "$env:ProgramData\Microsoft\Windows Defender\Quarantine" "$sys\DefenderQuarantine" "Defender quarantine"
Copy-Tree "$env:ProgramData\Microsoft\Windows Defender\Scans\History" "$sys\DefenderScanHistory" "Defender scan history"
Copy-Tree "$env:SystemRoot\inf" "$sys\inf_setupapi" "setupapi logs (device history)"
Invoke-Step "Amcache.hve forced copy" { esentutl /y "$env:SystemRoot\AppCompat\Programs\Amcache.hve" /d "$sys\Amcache.hve" /o | Out-Null }
Invoke-Step "SRUDB.dat forced copy"   { esentutl /y "$env:SystemRoot\System32\sru\SRUDB.dat" /d "$sys\SRUDB.dat" /o | Out-Null }
Invoke-Step "Recent file changes (45 days)" {
    $cut = (Get-Date).AddDays(-45)
    # foreach is a statement, not a pipeline element, so collect first then pipe
    $scan = foreach ($p in "C:\Windows\Temp","C:\ProgramData","C:\Users","C:\Program Files","C:\Program Files (x86)","C:\Windows\System32","C:\Windows\SysWOW64","C:\Temp","C:\PerfLogs","C:\Intel","C:\") {
        Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue -Depth 4 | Where-Object { $_.CreationTime -gt $cut -or $_.LastWriteTime -gt $cut } |
            Select-Object FullName,Length,CreationTime,LastWriteTime,LastAccessTime
    }
    $scan | ForEach-Object { $_ } | Sort-Object CreationTime | Export-Csv "$sys\RecentFiles_since_$($cut.ToString('yyyyMMdd')).csv" -NoTypeInformation
}
Invoke-Step "Executables in user-writable paths" {
    Get-ChildItem "C:\Users","C:\ProgramData","C:\Windows\Temp","C:\Temp" -Recurse -Force -Include *.exe,*.dll,*.msi,*.ps1,*.bat,*.cmd,*.vbs,*.js,*.hta,*.scr -ErrorAction SilentlyContinue |
        Select-Object FullName,Length,CreationTime,LastWriteTime,@{n="SHA256";e={ (Get-FileHash $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash }} |
        Export-Csv "$sys\UserWritable_Executables.csv" -NoTypeInformation
}
Invoke-Step "Alternate data streams (Zone.Identifier) in Downloads" {
    Get-ChildItem "C:\Users\*\Downloads" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $z = Get-Content -Path $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
        if ($z) { [pscustomobject]@{ File=$_.FullName; Created=$_.CreationTime; ZoneIdentifier=($z -join " | ") } }
    } | Export-Csv "$sys\Downloads_ZoneIdentifier.csv" -NoTypeInformation
}
if (-not $SkipFullListing) {
    Invoke-Step "Full C:\ directory listing" {
        # Big, but it is the single most useful thing for timeline reconstruction after the box is gone.
        # Excludes the collection folder so the listing doesn't eat its own output.
        Get-ChildItem "C:\" -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "$caseDir*" } |
            Select-Object FullName,Length,CreationTime,LastWriteTime,LastAccessTime,Attributes |
            Export-Csv "$sys\_FullDiskListing.csv" -NoTypeInformation
    }
} else { Log "SKIP  Full disk listing (SkipFullListing)" }

# ---------------------------------------------------------------------------
# 8. Hash manifest and package
# ---------------------------------------------------------------------------
Log "--- 8. Hashing and packaging ---"
$manifest = Join-Path $caseDir "00_HashManifest_SHA256.csv"
Invoke-Step "Hash manifest" {
    Get-ChildItem $caseDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $manifest } |
        ForEach-Object {
            $h = Get-FileHash $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue
            [pscustomobject]@{ RelativePath = $_.FullName.Substring($caseDir.Length+1); Size=$_.Length; SHA256=$h.Hash }
        } | Export-Csv $manifest -NoTypeInformation
}
$fileCount = (Get-ChildItem $caseDir -Recurse -File).Count
$sizeMB    = [math]::Round(((Get-ChildItem $caseDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB),1)
Log "Files collected: $fileCount  ($sizeMB MB)"

$zip = "$caseDir.zip"
$zipHash = $null
if (-not $NoZip) {
    Invoke-Step "Zip package" {
        Compress-Archive -Path "$caseDir\*" -DestinationPath $zip -CompressionLevel Optimal -Force
    }
}
if (Test-Path $zip) {
    $zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash
    Log "Package:      $zip"
    Log "Package SHA256: $zipHash"
    # Write the zip hash beside it as well
    "$zipHash  $(Split-Path $zip -Leaf)" | Out-File "$zip.sha256" -Encoding ASCII
}

Log ""
Log "=== Collection complete ==="
Log "Next: record the package hash in the ticket, copy the zip off this machine, verify the hash on the destination, then proceed with drive pull."
Log "Custody: collected by $Collector on $hostName, stored at $caseDir, package $zip"

Write-Host ""
if ($zipHash) { Write-Host "DONE. Package: $zip" -ForegroundColor Green; Write-Host "SHA256: $zipHash" -ForegroundColor Green }
else { Write-Host "DONE. Folder: $caseDir" -ForegroundColor Green }
Write-Host "Custody log: $log" -ForegroundColor Green
