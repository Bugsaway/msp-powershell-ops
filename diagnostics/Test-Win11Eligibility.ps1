<#
.SYNOPSIS
    Checks Windows 11 hardware requirements and writes the result to Ninja custom fields.
.DESCRIPTION
    TPM 2.0, Secure Boot capable UEFI, 64-bit, 2+ cores at 1 GHz, 4 GB RAM, 64 GB disk, and a
    CPU generation heuristic (Intel 8th gen+, AMD Zen 2+). Read-only. Skips machines already
    on Windows 11 and servers.
.NOTES
    Run context : SYSTEM
    Exit 0      : Always. This is inventory, not a fault. Filter on the custom field.
    Ninja setup : Once per device, re-run after hardware changes. Custom fields:
                  win11Eligible (Yes/No/Already/N/A) and win11Blockers (text).
    CPU check is a heuristic on the model string, not Microsoft's list. Treat a CPU-only
    fail as "verify" rather than a hard no. Everything else is definitive.
#>

# ---------------- CONFIG ----------------
$FieldEligible = 'win11Eligible'
$FieldBlockers = 'win11Blockers'
# ----------------------------------------

$ErrorActionPreference = 'Continue'
function Set-Field { param($n, $v) if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) { try { Ninja-Property-Set $n $v } catch {} } }

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
Write-Output "=== Windows 11 eligibility on $env:COMPUTERNAME ==="
Write-Output "  OS: $($os.Caption) build $build"

if ($os.ProductType -ne 1) { Write-Output "RESULT: Server, N/A"; Set-Field $FieldEligible 'N/A'; exit 0 }
if ($build -ge 22000)      { Write-Output "RESULT: Already on Windows 11"; Set-Field $FieldEligible 'Already'; Set-Field $FieldBlockers ''; exit 0 }

$blockers = @()
$verify   = @()

# TPM 2.0
$tpm = $null
try { $tpm = Get-Tpm -ErrorAction Stop } catch {}
$tpmVer = $null
try { $tpmVer = (Get-CimInstance -Namespace root\cimv2\security\microsofttpm -ClassName Win32_Tpm -ErrorAction Stop).SpecVersion } catch {}
$tpmOk = $tpm -and $tpm.TpmPresent -and $tpmVer -and ($tpmVer -split ',')[0].Trim() -ge '2.0'
Write-Output "  TPM: present=$($tpm.TpmPresent) ready=$($tpm.TpmReady) spec=$tpmVer"
if (-not $tpmOk) { $blockers += if ($tpm -and $tpm.TpmPresent) { "TPM $tpmVer (need 2.0, check BIOS for fTPM/PTT)" } else { 'no TPM (check BIOS for fTPM/PTT)' } }

# UEFI and Secure Boot
$firmware = $env:firmware_type
$sb = $null
try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop } catch { $sb = 'unsupported' }
Write-Output "  Firmware: $firmware  SecureBoot: $sb"
if ($firmware -ne 'UEFI') { $blockers += 'legacy BIOS boot (needs UEFI, may need MBR to GPT conversion)' }
elseif ($sb -eq 'unsupported') { $blockers += 'Secure Boot not supported' }

# CPU
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cores = ($cpu | Measure-Object NumberOfCores -Sum).Sum
Write-Output "  CPU: $($cpu.Name.Trim()) cores=$cores MHz=$($cpu.MaxClockSpeed) arch=$($cpu.AddressWidth)-bit"
if ($cpu.AddressWidth -ne 64) { $blockers += '32-bit CPU' }
if ($cores -lt 2) { $blockers += "$cores core" }
if ($cpu.MaxClockSpeed -lt 1000) { $blockers += "$($cpu.MaxClockSpeed) MHz" }
$name = $cpu.Name
$cpuOk = $null
if ($name -match 'Intel.*i[3579]-(\d{4,5})') {
    $gen = if ($matches[1].Length -eq 5) { [int]$matches[1].Substring(0,2) } else { [int]$matches[1].Substring(0,1) }
    $cpuOk = $gen -ge 8
}
elseif ($name -match 'Intel.*(Celeron|Pentium)') { $cpuOk = $null }   # too mixed to guess
elseif ($name -match 'Ryzen [3579] (\d{4})') { $cpuOk = [int]$matches[1] -ge 3000 -or ($name -match 'Ryzen [3579] 2\d{3}(?!U|H)') }
elseif ($name -match 'Ryzen (Threadripper|PRO)') { $cpuOk = $true }
elseif ($name -match 'Xeon') { $cpuOk = $null }
if ($cpuOk -eq $false) { $blockers += "CPU too old ($($name.Trim()))" }
elseif ($null -eq $cpuOk) { $verify += "CPU not on heuristic, verify against Microsoft list ($($name.Trim()))" }

# RAM and disk
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$sysDisk = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue | Get-Disk -ErrorAction SilentlyContinue
$diskGB = if ($sysDisk) { [math]::Round($sysDisk.Size / 1GB) } else { 0 }
$style = if ($sysDisk) { $sysDisk.PartitionStyle } else { 'unknown' }
Write-Output "  RAM: $ramGB GB  System disk: $diskGB GB $style"
if ($ramGB -lt 4) { $blockers += "$ramGB GB RAM" }
if ($diskGB -and $diskGB -lt 64) { $blockers += "$diskGB GB disk" }
if ($style -eq 'MBR' -and $firmware -eq 'UEFI') { $verify += 'system disk is MBR, run mbr2gpt before upgrade' }

$eligible = if ($blockers) { 'No' } elseif ($verify) { 'Verify' } else { 'Yes' }
$text = (($blockers + $verify) -join '; ')
Set-Field $FieldEligible $eligible
Set-Field $FieldBlockers $text

Write-Output "RESULT: $eligible$(if ($text) { " - $text" })"
exit 0
