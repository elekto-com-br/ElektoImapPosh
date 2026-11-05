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

Only the settings given are changed. An empty value removes a setting, a switch given as $false
(-NoTls:$false) turns it off, and -AllowWrite None takes back the permission to change the mailbox.

.PARAMETER Name
The name of the account: letters, digits, '.', '-' and '_', starting with a letter or digit.
A new account cannot differ from another only in case or in '.', '-' and '_' (work.prod and
work-prod): both would read their password from the same IMAP_PASS_<NAME> variable.

.PARAMETER Server
The IMAP server, such as imap.gmail.com. Required for a new account.

.PARAMETER Port
The IMAP server port. Default is 993.

.PARAMETER User
The IMAP user name, usually the email address. Required for a new account.

.PARAMETER Password
The IMAP password (for Gmail, an app password), stored as described above.

.PARAMETER NoTls
Connects to this account in plain text, without TLS: the password and everything read cross the
network unencrypted. Meant for test servers on the same machine that have no TLS, such as
smtp4dev. Always use TLS with a real mailbox, and be responsible. Without it, the connection is
encrypted: TLS from the start on port 993, and STARTTLS, required, on any other port.

.PARAMETER SkipCertificateCheck
Accepts the certificate of this account's server without checking it: one that is self-signed,
issued by an authority this machine does not trust, expired, or for another name. The connection
is still encrypted, but nothing proves that the other end is the server meant, rather than someone
in between. Meant for test servers and servers with a certificate of their own; a mailbox such as
Gmail never needs it. Be responsible.

.PARAMETER Default
Makes this the default account. -Default:$false stops it from being the default.

.PARAMETER AllowWrite
The kinds of change that the commands that change the mailbox (not in this version yet) may make
in this account:
- Flags: marking messages as read or unread, starring them.
- Move: moving messages to another folder, the trash included. Nothing is ever deleted.
- Labels: adding and removing labels, on Gmail.
- All: every kind, those that later versions add too.
- None: no change, which is the default.
Without the permission, ElektoImapPosh only reads: a command that would make a change of a kind
not allowed stops with an error, and folders are opened read-only, so that the server itself
refuses changes to their messages and nothing is marked as read.

.PARAMETER Policy
The policy that the commands follow when they read from this account, created with Set-ImapPolicy:
what of its messages may be read in full or saved, and how much one command may download. An empty
value ('') removes it, and the account allows all reading again.

.EXAMPLE
Set-ImapAccount -Name work -Server imap.gmail.com -User me@example.com -Password (Read-Host -AsSecureString 'Password') -Default

Creates the account "work", asking for its password without showing it, and makes it the default.

.EXAMPLE
Set-ImapAccount -Name work -Password (Read-Host -AsSecureString 'Password')

Replaces the stored password of the account "work".

.EXAMPLE
Set-ImapAccount -Name work -AllowWrite Flags, Move

Allows the commands that change the mailbox to mark messages and to move them in the account
"work", but not to change labels.

.EXAMPLE
Set-ImapAccount -Name work -AllowWrite None

Takes back the permission to change the mailbox of the account "work".

.EXAMPLE
Set-ImapAccount -Name work -Policy agent

Makes the commands follow the policy "agent" when they read from the account "work".

.EXAMPLE
Set-ImapAccount -Name office -SkipCertificateCheck

Accepts the certificate of the server of the account "office", which no authority this machine
trusts has issued.
#>
Function Set-ImapAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        # Options None tells case apart, as the pattern names both: by default it ignores case as the culture does,
        # and took a dotless i in Turkish
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$', Options = 'None')]
        [string]$Name,

        [string]$Server,
        [ValidateRange(1, 65535)]
        [int]$Port,
        [string]$User,
        [securestring]$Password,
        [switch]$NoTls,
        [switch]$SkipCertificateCheck,
        [switch]$Default,
        [ValidateSet('Flags', 'Move', 'Labels', 'All', 'None')]
        [string[]]$AllowWrite,
        [string]$Policy
    )

    # $writeKinds, since $allowWrite would be the parameter itself (variable names ignore case)
    $writeKinds = if ($PSBoundParameters.ContainsKey('AllowWrite')) { ConvertTo-WriteKindList $AllowWrite }
    if ($PSBoundParameters.ContainsKey('AllowWrite') -and $null -eq $writeKinds) {
        throw "-AllowWrite takes $($script:WriteKindsHint), not $($AllowWrite -join ', ')."
    }

    $file = Read-AccountFile
    $accounts = if ($file) { $file.Accounts } else { [ordered]@{} }
    $defaultName = if ($file) { $file.Default } else { $null }
    $policies = if ($file) { $file.Policies } else { [ordered]@{} }

    # The policy as the file spells it: one that does not exist would leave the account unable to read
    $policyName = Find-PolicyName $file $Policy
    if ($Policy -and -not $policyName) {
        $known = if ($policies.psbase.Count) { " Policies: $($policies.psbase.Keys -join ', ')." } else { '' }
        throw "There is no policy '$Policy' in '$(Get-AccountFilePath)': create it with Set-ImapPolicy first.$known"
    }

    # An existing account keeps the spelling of its name
    $existingName = Find-AccountName $file $Name
    if ($existingName) { $Name = $existingName }
    else {
        $sameVariable = Find-PasswordVariableOwner $accounts.psbase.Keys $Name
        if ($sameVariable) {
            throw "Account '$Name' would share the password variable $(Get-PasswordVariableName $Name) with the account '$sameVariable', which would give one the password of the other: choose a name that differs in its letters or digits."
        }
    }
    $settings = [ordered]@{}
    if ($existingName) { foreach ($key in $accounts[$Name].psbase.Keys) { $settings[$key] = $accounts[$Name][$key] } }

    foreach ($key in $script:AccountSettingNames) {
        if (-not $PSBoundParameters.ContainsKey($key)) { continue }
        $value = if ($key -eq 'AllowWrite') { , $writeKinds } elseif ($key -eq 'Policy') { $policyName } else { $PSBoundParameters[$key] }
        # A switch kept only when on: -NoTls:$false removes it, as an empty value (or -AllowWrite None) removes a setting
        if ($value -is [switch]) { $value = if ($value) { $true } else { '' } }
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
    Write-AccountFile $defaultName $accounts $policies
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
