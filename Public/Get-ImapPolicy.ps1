<#
.SYNOPSIS
Lists the policies that accounts can follow, and which accounts follow each.

.DESCRIPTION
The `Get-ImapPolicy` function returns the policies kept by Set-ImapPolicy, with their settings and the
accounts that follow each one (given to Set-ImapAccount -Policy). A setting not given is empty: the
policy has no such rule, or no such limit. See Set-ImapPolicy for what each setting does.

The policies are kept in accounts.json, with the accounts, in the folder ElektoImapPosh of the user's
configuration folder (%APPDATA% on Windows, ~/.config elsewhere), or in the folder named by
IMAP_CONFIG_DIR.

.PARAMETER Name
The name of the policy, or a wildcard pattern. If not provided, lists all policies.

.EXAMPLE
Get-ImapPolicy

Lists all policies.

.EXAMPLE
Get-ImapPolicy agent

Shows the settings of the policy "agent", and the accounts that follow it.
#>
Function Get-ImapPolicy {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string]$Name = '*'
    )

    $file = Read-AccountFile
    if (-not $file) {
        Write-Verbose "There is no accounts file at '$(Get-AccountFilePath)'."
    }

    $names = @(if ($file) { $file.Policies.psbase.Keys | Where-Object { Test-Wildcard $_ $Name } })
    if ($names.Count -eq 0 -and -not [WildcardPattern]::ContainsWildcardCharacters($Name)) {
        Write-Error "There is no policy '$Name'."
        return
    }

    foreach ($policyName in $names) {
        $policy = [ordered]@{ Name = $policyName; Accounts = Get-PolicyAccount $file $policyName }
        foreach ($key in $script:PolicySettings.Keys) { $policy[$key] = $file.Policies[$policyName][$key] }
        [PSCustomObject]$policy
    }
}
