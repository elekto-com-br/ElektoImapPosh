<#
.SYNOPSIS
Removes accounts and their stored passwords.

.DESCRIPTION
The `Remove-ImapAccount` function removes accounts from accounts.json and deletes their passwords
from the Windows Credential Manager (or, on Linux and macOS, their password files). If the default
account is removed, there is no default account afterwards, and the commands go back to the IMAP_*
environment variables. An IMAP_PASS_<NAME> environment variable is not touched.

.PARAMETER Name
The names of the accounts, or wildcard patterns. Also taken from the pipeline, as names or as the
accounts listed by Get-ImapAccount.

.EXAMPLE
Remove-ImapAccount old

.EXAMPLE
Get-ImapAccount test* | Remove-ImapAccount -WhatIf

Shows which accounts would be removed, without removing them.

.EXAMPLE
Remove-ImapAccount *

Removes every account and its stored password, so the commands read the IMAP_* environment variables
again.
#>
Function Remove-ImapAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [SupportsWildcards()]
        [string[]]$Name
    )

    process {
        foreach ($pattern in $Name) {
            $file = Read-AccountFile
            # Account names hold no wildcard characters, so a plain name matches only itself
            $names = @(if ($file) { $file.Accounts.psbase.Keys | Where-Object { $_ -like $pattern } })
            if ($names.Count -eq 0 -and -not [WildcardPattern]::ContainsWildcardCharacters($pattern)) {
                Write-Error "There is no account '$pattern'."
                continue
            }

            $defaultName = $file.Default
            foreach ($existingName in $names) {
                if (-not $PSCmdlet.ShouldProcess("account '$existingName' in '$($file.Path)' and its stored password", 'Remove')) { continue }

                # The file first: if it cannot be written, the password stays
                $file.Accounts.Remove($existingName)
                if ($defaultName -eq $existingName) { $defaultName = $null }
                Write-AccountFile $defaultName $file.Accounts
                Write-Verbose "Account '$existingName' removed from '$($file.Path)'."

                if (Clear-StoredPassword $existingName) { Write-Verbose "Stored password of account '$existingName' deleted." }

                $variable = Get-PasswordVariableName $existingName
                if ([Environment]::GetEnvironmentVariable($variable)) {
                    Write-Warning "The environment variable $variable still holds the password of '$existingName'."
                }
            }
        }
    }
}
