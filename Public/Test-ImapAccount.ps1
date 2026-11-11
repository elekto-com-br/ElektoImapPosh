<#
.SYNOPSIS
Connects to the IMAP server of an account and authenticates, to check its settings and password.

.DESCRIPTION
The `Test-ImapAccount` function connects with the settings of an account (see Set-ImapAccount), or
of the default account, or else of the IMAP_* environment variables, and authenticates. It returns
what it found: how the connection was secured, whether the server's certificate was checked
(CertificateChecked, false for an account with -SkipCertificateCheck, and with -NoTls, where there
is none), the authentication mechanisms the server offers, and the capabilities it has after the
login. It reads no message.

When the account follows a policy with DenyFolders, it also lists the folders of the mailbox, and
warns of the entries that name none of them (a typo, a folder renamed since): such an entry withholds
nothing there. A special use that Gmail stands for by a label, such as Important, is no such entry.

The connection is always encrypted: TLS from the start on port 993, and STARTTLS on any other port,
which fails when the server does not offer it. The server's certificate must be valid. An account
set with -NoTls connects in plain text, and one set with -SkipCertificateCheck accepts any
certificate (see Set-ImapAccount); without accounts, IMAP_NO_TLS and IMAP_SKIP_CERTIFICATE_CHECK.

.PARAMETER Account
The account to test, one of those kept by Set-ImapAccount. If not provided, tests the default
account, if there is one, or else the IMAP_* environment variables. Also taken from the pipeline,
as the accounts listed by Get-ImapAccount: each one is tested in turn, and one that fails is
reported as an error without stopping the others.

.EXAMPLE
Test-ImapAccount work

Connects to the server of the account "work" and authenticates.

.EXAMPLE
Get-ImapAccount | Test-ImapAccount

Tests every account, reporting those that fail as errors.

.EXAMPLE
$env:IMAP_SERVER = '127.0.0.1'; $env:IMAP_PORT = 1143; $env:IMAP_NO_TLS = 'true'
$env:IMAP_USER = 'test'; $env:IMAP_PASS = 'test'
Test-ImapAccount

Tests a smtp4dev on the same machine, configured by environment variables, in plain text.
#>
Function Test-ImapAccount {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [Alias('Name')]
        [string]$Account
    )

    process {
        $settings = Resolve-ImapConfiguration $PSCmdlet $Account
        if (-not $settings) { return }

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $client = Connect-ImapServer $PSCmdlet $settings
        if (-not $client) { return }
        # Only a command that gets to its end logs out; stopped before it (by Ctrl+C, here or down the
        # pipeline, or by an error), it only closes the connection. $PSCmdlet.Stopping cannot tell: in this
        # finally block, after Ctrl+C down the pipeline, it is still false (tested).
        $ended = $false
        try {
            # Offered before the login: Gmail, for one, lists none after it
            $mechanisms = @($client.AuthenticationMechanisms | Sort-Object)
            if (Invoke-ImapLogin $PSCmdlet $client $settings) {
                $elapsed = $stopwatch.Elapsed
                # An entry of DenyFolders that names no folder withholds nothing, and nothing else tells: a policy knows no
                # mailbox. One listing, only for an account whose policy has such a list (some 0.4 s on Gmail, measured).
                $policy = $settings.Policy
                if ($policy -and $policy.DenyFolders) {
                    $session = @{ Client = $client; Settings = $settings }
                    if ($null -ne (Get-ImapFolderList $PSCmdlet $session)) {
                        $unmatched = Get-UnmatchedDenyFolder $session
                        if ($unmatched.Count) {
                            $entries = ($unmatched | ForEach-Object { "'$_'" }) -join ', '
                            $names = if ($unmatched.Count -eq 1) { "The entry $entries of DenyFolders of the policy '$($policy.Name)' names no folder of $($settings.User), so it withholds" } else { "The entries $entries of DenyFolders of the policy '$($policy.Name)' name no folder of $($settings.User), so they withhold" }
                            Write-Warning "$names nothing there. Get-ImapFolder lists the folders."
                        }
                    }
                }
                [PSCustomObject]@{
                    Account                  = $settings.Account
                    Server                   = $settings.Server
                    Port                     = $settings.Port
                    User                     = $settings.User
                    Security                 = "$(Get-SecureSocketOption $settings.Port -NoTls:$settings.NoTls)"
                    SslProtocol              = if ($client.IsSecure) { "$($client.SslProtocol)" } else { 'None' }
                    # Encrypted is not checked: with SkipCertificateCheck, nothing proved who answered (found in the
                    # review before the first release: the result was the same as for a certificate that validated)
                    CertificateChecked       = [bool]($client.IsSecure -and -not $settings.SkipCertificateCheck)
                    AuthenticationMechanisms = $mechanisms
                    Capabilities             = @("$($client.Capabilities)" -csplit ', ')
                    Elapsed                  = $elapsed
                }
            }
            $ended = $true
        } finally {
            Disconnect-ImapClient $client -Abort:(-not $ended)
        }
    }
}
