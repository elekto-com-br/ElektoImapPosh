<#
.SYNOPSIS
Removes policies that no account follows.

.DESCRIPTION
The `Remove-ImapPolicy` function removes policies from accounts.json. A policy that an account follows
is not removed, since the account would then refuse to read: give the account another policy, or none
(Set-ImapAccount <account> -Policy ''), first.

.PARAMETER Name
The names of the policies, or wildcard patterns. Also taken from the pipeline, as names or as the
policies listed by Get-ImapPolicy.

.EXAMPLE
Remove-ImapPolicy old

.EXAMPLE
Get-ImapPolicy test* | Remove-ImapPolicy -WhatIf

Shows which policies would be removed, without removing them.
#>
Function Remove-ImapPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [SupportsWildcards()]
        [string[]]$Name
    )

    process {
        foreach ($pattern in $Name) {
            $file = Read-AccountFile
            # Policy names hold no wildcard characters, so a plain name matches only itself
            $names = @(if ($file) { $file.Policies.psbase.Keys | Where-Object { $_ -like $pattern } })
            if ($names.Count -eq 0 -and -not [WildcardPattern]::ContainsWildcardCharacters($pattern)) {
                Write-Error "There is no policy '$pattern'."
                continue
            }

            foreach ($policyName in $names) {
                $accounts = Get-PolicyAccount $file $policyName
                if ($accounts) {
                    $followers = if ($accounts.Count -eq 1) { "the account $($accounts[0])" } else { "the accounts $($accounts -join ', ')" }
                    Write-ImapError $PSCmdlet "The policy '$policyName' is followed by $followers, which would refuse to read without it: give each another policy, or none (Set-ImapAccount $($accounts[0]) -Policy ''), first." 'PolicyInUse' ResourceBusy $policyName
                    continue
                }
                if (-not $PSCmdlet.ShouldProcess("policy '$policyName' in '$($file.Path)'", 'Remove')) { continue }

                $file.Policies.Remove($policyName)
                Write-AccountFile $file.Default $file.Accounts $file.Policies
                Write-Verbose "Policy '$policyName' removed from '$($file.Path)'."

                if ($env:IMAP_POLICY -eq $policyName) {
                    Write-Warning "The environment variable IMAP_POLICY still names the policy '$policyName', so the commands refuse to read without an account until it names another policy or is removed."
                }
            }
        }
    }
}
