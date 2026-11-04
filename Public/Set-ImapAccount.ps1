<#
.SYNOPSIS
Creates or changes an account that the commands of ElektoImapPosh can read from.

.DESCRIPTION
An account is a named set of IMAP settings: each one with its own server, user and password, so the
same machine and user can read several mailboxes. The commands that read take -Account <name>, and use
the default account when called without it.

These accounts are not those of ElektoMailPosh: each module keeps its own, so reading can have an app
password of its own, apart from the one for sending.

The settings are kept in accounts.json, in the folder ElektoImapPosh of the user's configuration
folder (%APPDATA% on Windows, ~/.config elsewhere), or in the folder named by IMAP_CONFIG_DIR.
Passwords are never written there:
- On Windows they go to the Credential Manager, as the generic credential "ElektoImapPosh:<name>",
  encrypted with the user's logon (DPAPI).
- On Linux and macOS they go to the file secrets/<name> in that folder, readable only by its owner.
- On any platform, the environment variable IMAP_PASS_<NAME> (the name in upper case, with any
  character other than letters and digits as "_") takes precedence over the stored password.

Only the settings given are changed. An empty value removes a setting.

.PARAMETER Name
The name of the account: letters, digits, '.', '-' and '_', starting with a letter or digit.

.PARAMETER Server
The IMAP server, such as imap.gmail.com. Required for a new account.

.PARAMETER Port
The IMAP server port. Default is 993.

.PARAMETER User
The IMAP user name, usually the email address. Required for a new account.

.PARAMETER Password
The IMAP password (for Gmail, an app password), stored as described above.

.PARAMETER Default
Makes this the default account. -Default:$false stops it from being the default.

.EXAMPLE
Set-ImapAccount -Name work -Server imap.gmail.com -User me@example.com -Password (Read-Host -AsSecureString 'Password') -Default

Creates the account "work", asking for its password without showing it, and makes it the default.

.EXAMPLE
Set-ImapAccount -Name work -Password (Read-Host -AsSecureString 'Password')

Replaces the stored password of the account "work".
#>
Function Set-ImapAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string]$Name,

        [string]$Server,
        [ValidateRange(1, 65535)]
        [int]$Port,
        [string]$User,
        [securestring]$Password,
        [switch]$Default
    )

    $file = Read-AccountFile
    $accounts = if ($file) { $file.Accounts } else { [ordered]@{} }
    $defaultName = if ($file) { $file.Default } else { $null }

    # An existing account keeps the spelling of its name
    $existingName = Find-AccountName $file $Name
    if ($existingName) { $Name = $existingName }
    $settings = [ordered]@{}
    if ($existingName) { foreach ($key in $accounts[$Name].psbase.Keys) { $settings[$key] = $accounts[$Name][$key] } }

    foreach ($key in $script:AccountSettingNames) {
        if (-not $PSBoundParameters.ContainsKey($key)) { continue }
        $value = $PSBoundParameters[$key]
        if ("$value" -eq '') { $settings.Remove($key) } else { $settings[$key] = $value }
    }
    $secret = if ($Password) { [Net.NetworkCredential]::new('', $Password).Password } else { $null }

    if (-not $settings.Server -or -not $settings.User) {
        throw "Account '$Name' needs a server and a user: give -Server and -User."
    }

    if ($PSBoundParameters.ContainsKey('Default')) {
        if ($Default) { $defaultName = $Name } elseif ($defaultName -eq $Name) { $defaultName = $null }
    }

    if (-not $PSCmdlet.ShouldProcess("account '$Name' in '$(Get-AccountFilePath)'", 'Save')) { return }

    $accounts[$Name] = $settings
    Write-AccountFile $defaultName $accounts
    Write-Verbose "Account '$Name' saved in '$(Get-AccountFilePath)'."

    if ($secret) {
        Save-StoredPassword $Name $settings.User $secret
        Write-Verbose "Password of account '$Name' stored."
    } elseif (-not (Get-AccountPassword $Name)) {
        Write-Warning (Get-MissingPasswordMessage $Name)
    }

    # While an account is the default, the IMAP_* variables are of no use, and IMAP_PASS should not linger
    if ($defaultName -eq $Name) {
        $variables = $script:EnvironmentVariableNames | Where-Object { [Environment]::GetEnvironmentVariable($_) }
        if ($variables) {
            Write-Warning "'$Name' is the default account, so the commands no longer read $($variables -join ', '). Remove them from the environment, above all IMAP_PASS."
        }
    }
}
