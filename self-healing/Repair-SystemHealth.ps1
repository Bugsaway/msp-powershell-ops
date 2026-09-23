<#
.SYNOPSIS
    Detect-first component store, system file, and volume repair.
.DESCRIPTION
    Checks before it fixes. Nothing heavy runs unless a detection says it should.
      1. DISM /CheckHealth then /ScanHealth. Only if corruption is flagged: DISM /RestoreHealth.
      2. SFC /verifyonly. Only if violations are found: SFC /scannow.
      3. Repair-Volume -Scan on C:. Only if the scan finds errors: Repair-Volume -SpotFix.
    Order matters. DISM repairs the store SFC pulls from, so DISM always goes first.
    No /ResetBase, so a bad update can still be uninstalled. No chkdsk /r or /f, so no
    offline scan gets queued on a production box. SpotFix is online and takes seconds.
.NOTES
    Run context : SYSTEM
    Exit 0      : Healthy, or repaired
    Exit 1      : Corruption found and not fixed -> ticket
    Ninja setup : Trigger on repeated 7034/7031 crashes, a BSOD condition, or on demand.
                  Also fine monthly. Timeout 120 min. RestoreHealth needs Windows Update
                  reachable or it will fail with 0x800f081f.
#>

# ---------------- CONFIG ----------------
$DriveLetter = 'C'
# ----------------------------------------

$ErrorActionPreference = 'Continue'
$exitCode = 0

function Invoke-Native {
    # Runs an exe, captures output as one clean string (SFC under SYSTEM emits UTF-16 with nulls), returns exit code
    param([string]$Exe, [string[]]$Arguments, [string]$Label)
    Write-Output "  Running: $Exe $($Arguments -join ' ')"
    $out = (& $Exe @Arguments 2>&1) -join "`n"
    $out = $out -replace "`0", ''
    $script:LastOutput = $out
    Write-Output "  $Label exit code: $LASTEXITCODE"
    return $LASTEXITCODE
}

$hostname = $env:COMPUTERNAME
Write-Output "=== System health check on $hostname - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

# ---------- 1. Component store ----------
Write-Output "[1/3] Component store"
$check = Invoke-Native dism.exe @('/Online','/Cleanup-Image','/CheckHealth') 'CheckHealth'
$storeBad = $false
if ($script:LastOutput -match 'repairable|corrupt') { $storeBad = $true }

if (-not $storeBad) {
    $scan = Invoke-Native dism.exe @('/Online','/Cleanup-Image','/ScanHealth') 'ScanHealth'
    if ($script:LastOutput -match 'repairable|corrupt') { $storeBad = $true }
}

if ($storeBad) {
    Write-Output "  Store corruption flagged. Running RestoreHealth..."
    $restore = Invoke-Native dism.exe @('/Online','/Cleanup-Image','/RestoreHealth') 'RestoreHealth'
    if ($restore -notin 0, 3010) {
        Write-Output "  RestoreHealth failed ($restore). Check C:\Windows\Logs\DISM\dism.log. 0x800f081f means no source, WU unreachable."
        $exitCode = 1
    } else {
        Write-Output "  Component store repaired."
    }
} else {
    Write-Output "  Component store healthy."
}

# ---------- 2. System files ----------
Write-Output "[2/3] System files"
$verify = Invoke-Native "$env:SystemRoot\System32\sfc.exe" @('/verifyonly') 'SFC verify'
if ($script:LastOutput -match 'did not find any integrity violations') {
    Write-Output "  No integrity violations."
}
elseif ($script:LastOutput -match 'could not perform') {
    Write-Output "  SFC could not run (pending reboot or servicing lock). Reboot and re-run."
    $exitCode = 1
}
else {
    Write-Output "  Violations found. Running SFC /scannow..."
    $fix = Invoke-Native "$env:SystemRoot\System32\sfc.exe" @('/scannow') 'SFC scannow'
    if ($script:LastOutput -match 'successfully repaired') {
        Write-Output "  System files repaired."
    }
    elseif ($script:LastOutput -match 'did not find any integrity violations') {
        Write-Output "  Clean on second pass."
    }
    else {
        Write-Output "  SFC found corruption it could not fix. Review C:\Windows\Logs\CBS\CBS.log (search [SR])."
        $exitCode = 1
    }
}

# ---------- 3. Volume ----------
Write-Output "[3/3] Volume $DriveLetter`:"
try {
    $scanResult = Repair-Volume -DriveLetter $DriveLetter -Scan -ErrorAction Stop
    Write-Output "  Scan result: $scanResult"
    if ("$scanResult" -ne 'NoErrorsFound') {
        Write-Output "  Errors found. Running online SpotFix..."
        $fixResult = Repair-Volume -DriveLetter $DriveLetter -SpotFix -ErrorAction Stop
        Write-Output "  SpotFix result: $fixResult"
        if ("$fixResult" -ne 'NoErrorsFound') {
            Write-Output "  SpotFix did not clear it. Do not queue chkdsk /f or /r from here. Backup and escalate."
            $exitCode = 1
        }
    }
} catch {
    Write-Output "  Volume check failed: $($_.Exception.Message)"
    $exitCode = 1
}

# ---------- Reboot pending? ----------
$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
if ($pending) { Write-Output "Reboot pending. The nightly reboot script will clear it." }

if ($exitCode -eq 0) { Write-Output "RESULT: System healthy." } else { Write-Output "RESULT: Unresolved issues. Manual review needed." }
exit $exitCode
