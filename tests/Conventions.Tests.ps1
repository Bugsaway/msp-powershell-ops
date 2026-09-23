<#
.SYNOPSIS
    Pester tests that enforce the repo conventions on every script.
.DESCRIPTION
    Runs in CI on every push. Checks the things the README promises:
      - every script parses under Windows PowerShell 5.1 syntax rules
      - every script has comment-based help with SYNOPSIS, DESCRIPTION, and NOTES
      - every NOTES block documents the exit contract
      - no script uses DISM /ResetBase
      - no script runs chkdsk with /f or /r
      - allowlist and expected-value variables are committed empty or built-ins only
      - scripts that say they are read-only don't call state-changing cmdlets
#>

BeforeDiscovery {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Scripts  = Get-ChildItem $RepoRoot -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\tests\\' }
}

Describe 'Script: <_.Name>' -ForEach $Scripts {
    BeforeAll {
        $file    = $_
        $content = Get-Content $file.FullName -Raw
        $help    = if ($content -match '(?s)<#(.*?)#>') { $matches[1] } else { '' }
        # Code only: help block and comment lines removed, so a comment that says "no /ResetBase" doesn't trip the test
        $code    = (($content -replace '(?s)<#.*?#>', '') -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    It 'parses without errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has a comment-based help block' {
        $help | Should -Not -BeNullOrEmpty
    }

    It 'help has SYNOPSIS, DESCRIPTION, and NOTES' {
        $help | Should -Match '\.SYNOPSIS'
        $help | Should -Match '\.DESCRIPTION'
        $help | Should -Match '\.NOTES'
    }

    It 'NOTES documents the exit contract' {
        $help | Should -Match '(?i)exit\s*(0|1|:|\s)'
    }

    It 'does not use DISM /ResetBase' {
        $code | Should -Not -Match '(?i)/ResetBase'
    }

    It 'does not run chkdsk /f or /r' {
        $code | Should -Not -Match '(?i)chkdsk\s+\S+\s*/[fr]\b'
    }
}

Describe 'Allowlists are committed empty or built-in only' {
    It 'Find-UnauthorizedRemoteAccess has no ScreenConnect instance IDs' {
        $c = Get-Content "$RepoRoot\security\Find-UnauthorizedRemoteAccess.ps1" -Raw
        $c | Should -Match '\$AllowedScreenConnectInstances\s*=\s*@\(\s*\)'
    }
    It 'Get-NetworkBaseline has no DNS servers' {
        $c = Get-Content "$RepoRoot\monitoring\Get-NetworkBaseline.ps1" -Raw
        $c | Should -Match '\$ExpectedDnsServers\s*=\s*@\(\s*\)'
    }
    It 'Get-LocalAdminAudit expects only built-in groups' {
        $c = Get-Content "$RepoRoot\security\Get-LocalAdminAudit.ps1" -Raw
        $c | Should -Match "\`$ExpectedMembers\s*=\s*@\('Administrator',\s*'Domain Admins',\s*'Enterprise Admins'\)"
    }
    It 'Remove-StaleProfiles excludes only Administrator and ships in dry run' {
        $c = Get-Content "$RepoRoot\self-healing\Remove-StaleProfiles.ps1" -Raw
        $c | Should -Match "\`$ExcludeUsers\s*=\s*@\('Administrator'\)"
        $c | Should -Match '\$DryRun\s*=\s*\$true'
    }
}

Describe 'Read-only scripts stay read-only' {
    BeforeDiscovery {
        $ro = $Scripts | Where-Object { (Get-Content $_.FullName -Raw) -match '(?i)read-only|read only\.' }
    }
    It '<_.Name> does not call a state-changing cmdlet' -ForEach $ro {
        $c = Get-Content $_.FullName -Raw
        $code = (($c -replace '(?s)<#.*?#>', '') -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        # Statement position only (line start, after { or ;), so a regex pattern that names these cmdlets doesn't trip it
        $code | Should -Not -Match '(?im)(^|[{;])\s*(Remove-Item|Set-ItemProperty|New-ItemProperty|Stop-Service|Start-Service|Set-Service|Restart-Service|Remove-LocalUser|Set-MpPreference|Add-MpPreference|Uninstall-)'
    }
}
