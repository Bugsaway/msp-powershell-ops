@{
    # Rules deliberately excluded and why.
    ExcludeRules = @(
        # Interactive scripts use Write-Host for colored section headers on purpose.
        # RMM-run scripts use Write-Output so the RMM captures it.
        'PSAvoidUsingWriteHost',

        # Get-WmiObject is used on purpose where the WMI object model is needed (MSPower_DeviceEnable.Put()).
        # Windows PowerShell 5.1 is a target host.
        'PSAvoidUsingWMICmdlet',

        # Fleet scripts set a value and exit. ShouldProcess prompts would hang an unattended SYSTEM run.
        # Scripts that change state in a user-facing way implement -WhatIf explicitly.
        'PSUseShouldProcessForStateChangingFunctions',

        # Script-level config blocks assign variables that a heredoc or a later section reads.
        # The analyzer can't see through string replacement.
        'PSUseDeclaredVarsMoreThanAssignments',

        # Empty catch blocks are intentional where a locked file or missing cmdlet is the expected case
        # and the surrounding code already reports the outcome.
        'PSAvoidUsingEmptyCatchBlock',

        # Short internal helpers (Step, Check, Log) are called positionally for readability in
        # scripts that are read top to bottom as a checklist.
        'PSAvoidUsingPositionalParameters',

        # Scripts share a common parameter set so a runner can splat the same arguments to all of them.
        # Not every script uses every parameter.
        'PSReviewUnusedParameter'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
