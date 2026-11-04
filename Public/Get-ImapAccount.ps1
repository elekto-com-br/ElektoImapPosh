<#
.SYNOPSIS
Lists the accounts the commands of ElektoImapPosh can read from.

.DESCRIPTION
The `Get-ImapAccount` function returns the accounts kept by Set-ImapAccount, with their settings
and where the password of each one comes from (never the password itself):
- Environment: the IMAP_PASS_<ACCOUNT> environment variable
- CredentialManager: the Windows Credential Manager
- File: a file readable only by its owner (Linux and macOS)
- Missing: no password, so the account cannot be used yet

NoTls tells whether the account connects in plain text, and SkipCertificateCheck whether it
accepts any certificate from its server. AllowWrite tells whether the commands that change the
mailbox may do so in the account; without it, ElektoImapPosh only reads. See Set-ImapAccount.

The accounts are kept in accounts.json, in the folder ElektoImapPosh of the user's configuration
folder (%APPDATA% on Windows, ~/.config elsewhere), or in the folder named by IMAP_CONFIG_DIR.

.PARAMETER Name
The name of the account, or a wildcard pattern. If not provided, lists all accounts.

.EXAMPLE
Get-ImapAccount

Lists all accounts, marking the default one.

.EXAMPLE
Get-ImapAccount work | Format-List

Shows the settings of the account "work".
#>
Function Get-ImapAccount {
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

    $names = @(if ($file) { $file.Accounts.psbase.Keys | Where-Object { $_ -like $Name } })
    if ($names.Count -eq 0 -and -not [WildcardPattern]::ContainsWildcardCharacters($Name)) {
        Write-Error "There is no account '$Name'."
        return
    }

    foreach ($accountName in $names) {
        $account = $file.Accounts[$accountName]
        try {
            $password = Get-AccountPassword $accountName
            $passwordSource = if ($password) { $password.Source } else { 'Missing' }
        } catch {
            Write-Warning $_.Exception.Message
            $passwordSource = 'Unusable'
        }

        [PSCustomObject]@{
            Name                 = $accountName
            Default              = $accountName -eq $file.Default
            Server               = $account.Server
            Port                 = if ($account.Port) { $account.Port } else { $script:DefaultPort }
            User                 = $account.User
            PasswordSource       = $passwordSource
            NoTls                = $account.NoTls -eq $true
            SkipCertificateCheck = $account.SkipCertificateCheck -eq $true
            AllowWrite           = $account.AllowWrite -eq $true
        }
    }
}
