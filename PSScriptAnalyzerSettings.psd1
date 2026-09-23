@{
    # Rules deliberately excluded and why.
    ExcludeRules = @(
        # Interactive scripts (PC-Cleanup, Find-ServiceTaskCulprit) use Write-Host for colored section headers on purpose.
        # RMM-run scripts use Write-Output so Ninja captures it.
        'PSAvoidUsingWriteHost',

        # Get-WmiObject is used on purpose in the USB power scripts. MSPower_DeviceEnable.Put() needs the WMI
        # object model. Windows PowerShell 5.1 is the target host.
        'PSAvoidUsingWMICmdlet',

        # Several fleet scripts set a value and exit. ShouldProcess prompts would hang an unattended SYSTEM run.
        'PSUseShouldProcessForStateChangingFunctions',

        # Script-level config blocks assign variables that the .bat or a later section reads.
        # The analyzer can't see through string replacement or heredocs.
        'PSUseDeclaredVarsMoreThanAssignments',

        # Empty catch blocks are intentional where a locked file or missing cmdlet is the expected case and
        # the surrounding code already reports the outcome.
        'PSAvoidUsingEmptyCatchBlock',

        # Ninja-Property-Set is provided by the NinjaOne agent at runtime.
        'PSAvoidUsingCmdletAliases'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
