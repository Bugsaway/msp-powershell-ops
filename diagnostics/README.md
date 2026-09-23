# diagnostics

Read-only. These scripts print findings and change nothing on the host.

## Find-ServiceTaskCulprit.ps1

Finds what is stopping or restarting a Windows service on a schedule. `$ServiceName` at the top defaults to DentrixACEServer, change it for any service.

Run elevated or push through Ninja as SYSTEM. Paste the whole thing into an admin PowerShell window or run it as a file:

```powershell
powershell -ExecutionPolicy Bypass -File .\Find-ServiceTaskCulprit.ps1
```

What it checks, in order:

1. Service config, dependencies, dependents, and recovery actions. If something nightly stops a service this one depends on, that takes it down too.
2. Every scheduled task. Flags any whose command line names the service (STRONG) or has a generic net stop / Stop-Service / taskkill (weak). It also opens any .bat, .cmd, .ps1, .vbs the task calls and greps inside, because a backup batch file with `net stop` in it is the usual culprit and you'd never see it from the task's command line.
3. Service Control Manager events for the service over the last 7 days (7036 state changes, 7011 timeouts, 7031 and 7034 crashes).
4. Non-Microsoft tasks that fired within 10 minutes of each of those events.
5. Fallback list of everything non-Microsoft that runs between 6 PM and 6 AM with its usual start time. A service that hangs in Stopping never logs a stopped event, so section 4 can come up empty and this is what you go off instead.

Knobs at the top: `$ServiceName`, `$DaysBack`, `$WindowMin`.

### Notes

- If Task Scheduler history is off on the box, sections 4 and 5 are empty and the script prints the `wevtutil` line to enable it. Let it run one more night.
- If everything comes back clean the stop isn't coming from Task Scheduler. Next places to look are the backup agent's pre and post job commands and any Ninja automation or condition on the device.
- Windows PowerShell 5.1 compatible.
- If the stop isn't coming from a scheduled task, the other common source is a vendor updater service that stops dependent services during its own install and doesn't restart them. Section 5 shows what ran overnight either way.

## Get-HardwareSummary.ps1

One-screen GPU and RAM readout for spec checks before an imaging software install or a Win11 eligibility call. Prints each video controller with its VRAM, then total RAM, slots used of slots available, and each stick with its slot name, size, and speed.

VRAM comes from `HardwareInformation.qwMemorySize` in the display class registry key. `Win32_VideoController.AdapterRAM` is a 32-bit field and reports 4 GB for anything bigger, so the registry read is the one to trust. Falls back to AdapterRAM if the key isn't there.

## Test-Win11Eligibility.ps1

Once per device, re-run after hardware changes. Checks TPM 2.0, UEFI and Secure Boot, 64-bit, cores and clock, RAM, system disk size and partition style, and a CPU generation heuristic (Intel 8th gen and up, AMD Zen 2 and up). Always exit 0. Writes custom fields `win11Eligible` (Yes, No, Verify, Already, N/A) and `win11Blockers` (text). Filter Windows 10 replacement candidates from the Ninja console by those fields.

The CPU check reads the model string, not Microsoft's list. Celeron, Pentium, and Xeon come back as Verify. A TPM or firmware fail is definitive. An MBR system disk on UEFI firmware gets flagged for mbr2gpt before upgrade.

## Configuration reference

| Script | Variable | Default | Change it when |
|---|---|---|---|
| Find-ServiceTaskCulprit | `$ServiceName` | DentrixACEServer | The service under investigation |
| | `$DaysBack` | 7 | How far back to read event logs |
| | `$WindowMin` | 10 | Minutes either side of a service event to look for task activity |
| Get-HardwareSummary | none | | |
| Test-Win11Eligibility | `$FieldEligible` | win11Eligible | Match the Ninja field name |
| | `$FieldBlockers` | win11Blockers | Match the Ninja field name |
