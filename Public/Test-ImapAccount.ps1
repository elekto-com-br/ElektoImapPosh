<#
.SYNOPSIS
Connects to the IMAP server of an account and authenticates, to check its settings and password.

.DESCRIPTION
The `Test-ImapAccount` function connects with the settings of an account (see Set-ImapAccount), or
of the default account, or else of the IMAP_* environment variables, and authenticates. It returns
what it found: how the connection was secured, the authentication mechanisms the server offers, and
the capabilities it has after the login. It reads nothing from the mailbox.

The connection is always encrypted: TLS from the start on port 993, and STARTTLS on any other port,
which fails when the server does not offer it. Only -NoTls connects in plain text.

.PARAMETER Account
The account to test, one of those kept by Set-ImapAccount. If not provided, tests the default
account, if there is one, or else the IMAP_* environment variables. Also taken from the pipeline,
as the accounts listed by Get-ImapAccount: each one is tested in turn, and one that fails is
reported as an error without stopping the others.

.PARAMETER NoTls
Connects in plain text, without TLS: the password and everything read cross the network
unencrypted. Meant for test servers on the same machine that have no TLS, such as smtp4dev.
Always use TLS with a real mailbox, and be responsible.

.EXAMPLE
Test-ImapAccount work

Connects to the server of the account "work" and authenticates.

.EXAMPLE
Get-ImapAccount | Test-ImapAccount

Tests every account, reporting those that fail as errors.

.EXAMPLE
$env:IMAP_SERVER = '127.0.0.1'; $env:IMAP_PORT = 1143; $env:IMAP_USER = 'test'; $env:IMAP_PASS = 'test'
Test-ImapAccount -NoTls

Tests a smtp4dev on the same machine, configured by environment variables, in plain text.
#>
Function Test-ImapAccount {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [Alias('Name')]
        [string]$Account,

        [switch]$NoTls
    )

    process {
        $settings = Resolve-ImapConfiguration $PSCmdlet $Account
        if (-not $settings) { return }

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $client = Connect-ImapServer $PSCmdlet $settings -NoTls:$NoTls
        if (-not $client) { return }
        try {
            # Offered before the login: Gmail, for one, lists none after it
            $mechanisms = @($client.AuthenticationMechanisms | Sort-Object)
            if (-not (Invoke-ImapLogin $PSCmdlet $client $settings)) { return }

            [PSCustomObject]@{
                Account                  = $settings.Account
                Server                   = $settings.Server
                Port                     = $settings.Port
                User                     = $settings.User
                Security                 = "$(Get-SecureSocketOption $settings.Port -NoTls:$NoTls)"
                SslProtocol              = if ($client.IsSecure) { "$($client.SslProtocol)" } else { 'None' }
                AuthenticationMechanisms = $mechanisms
                Capabilities             = @("$($client.Capabilities)" -split ', ')
                Elapsed                  = $stopwatch.Elapsed
            }
        } finally {
            Disconnect-ImapClient $client
        }
    }
}
