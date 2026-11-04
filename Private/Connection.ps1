# The connection to the IMAP server, always encrypted: TLS from the start on port 993 (IMAPS), and STARTTLS,
# required, on any other port. MailKit's Auto is never used: with a server that offers no STARTTLS it goes on
# in plain text, password included. Only -NoTls, meant for test servers such as smtp4dev, connects that way.
# Failures are reported as Errors.ps1 says, so the operations of MailKit run by their Async methods, through
# Wait-ImapTask.

# Waits for the task of an Async method of MailKit and returns $null when it succeeded, or else the message
# of its exception, without throwing it. The wait goes in short steps, so that Ctrl+C stops the command at
# once, where a synchronous call would hold PowerShell until the server answers; the command's finally block
# then disposes of the client, which ends the task.
function Wait-ImapTask([System.Threading.Tasks.Task]$Task) {
    while ([System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($Task), 200) -lt 0) { }
    if ($Task.IsFaulted) { return $Task.Exception.InnerException.Message }
    if ($Task.IsCanceled) { return 'The operation was canceled.' }
    return $null
}

# How to secure a connection to the port given
function Get-SecureSocketOption([int]$Port, [switch]$NoTls) {
    if ($NoTls) { return [MailKit.Security.SecureSocketOptions]::None }
    if ($Port -eq 993) { return [MailKit.Security.SecureSocketOptions]::SslOnConnect }
    return [MailKit.Security.SecureSocketOptions]::StartTls
}

# An ImapClient connected, and not yet authenticated, to the server of the settings (as Resolve-ImapConfiguration
# returns them), or $null when it could not connect
function Connect-ImapServer($Cmdlet, $Settings, [switch]$NoTls) {
    $options = Get-SecureSocketOption $Settings.Port -NoTls:$NoTls
    $client = [MailKit.Net.Imap.ImapClient]::new()
    $connected = $false
    try {
        Write-Verbose "Connecting to $($Settings.Server):$($Settings.Port) ($options)..."
        $failure = Wait-ImapTask ($client.ConnectAsync($Settings.Server, $Settings.Port, $options))
        if ($failure) {
            Write-ImapError $Cmdlet "Could not connect to $($Settings.Server):$($Settings.Port) ($options): $failure" 'ConnectionFailed' ConnectionError $Settings.Server
            return $null
        }
        $connected = $true
        return $client
    } finally {
        # Also when Ctrl+C stops the wait
        if (-not $connected) { $client.Dispose() }
    }
}

# Authenticates the client with the user and password of the settings; $false when the server refused them.
# MailKit picks the best mechanism the server offers for a password (PLAIN with Gmail; never XOAUTH2 or
# OAUTHBEARER, which take a token), and the LOGIN command when it offers none.
function Invoke-ImapLogin($Cmdlet, $Client, $Settings) {
    Write-Verbose "Authenticating as $($Settings.User)..."
    $failure = Wait-ImapTask ($Client.AuthenticateAsync($Settings.User, $Settings.Password))
    if ($failure) {
        Write-ImapError $Cmdlet "$($Settings.Server) did not accept the user $($Settings.User): $failure (Gmail and Google Workspace need an app password.)" 'AuthenticationFailed' AuthenticationError $Settings.User
        return $false
    }
    return $true
}

# An ImapClient connected and authenticated, or $null after reporting why not. The commands that read
# disconnect it with Disconnect-ImapClient in a finally block.
function Connect-ImapClient($Cmdlet, $Settings, [switch]$NoTls) {
    $client = Connect-ImapServer $Cmdlet $Settings -NoTls:$NoTls
    if (-not $client) { return $null }
    $authenticated = $false
    try {
        $authenticated = Invoke-ImapLogin $Cmdlet $client $Settings
        if ($authenticated) { return $client }
        return $null
    } finally {
        if (-not $authenticated) { Disconnect-ImapClient $client }
    }
}

# Logs out, as a courtesy to the server, and closes the connection all the same when that fails
function Disconnect-ImapClient($Client) {
    if ($Client.IsConnected) {
        $failure = Wait-ImapTask ($Client.DisconnectAsync($true))
        if ($failure) { Write-Verbose "Disconnecting: $failure" }
    }
    $Client.Dispose()
}

# The connection of a command to an account, opened when the command first needs it and kept in $Sessions,
# a hashtable of the command, until it ends: its end block logs out with Close-ImapSession, and its clean
# block disposes of what is left after Ctrl+C or a terminating error. Returns the settings and the client,
# or $null after reporting why not, only the first time for each account. '' is the default account, or
# else the IMAP_* environment variables.
function Get-ImapSession($Cmdlet, [hashtable]$Sessions, [string]$Account, [switch]$NoTls) {
    if ($Sessions.ContainsKey($Account)) { return $Sessions[$Account] }
    $Sessions[$Account] = $null
    $settings = Resolve-ImapConfiguration $Cmdlet $Account
    if (-not $settings) { return $null }
    $client = Connect-ImapClient $Cmdlet $settings -NoTls:$NoTls
    if (-not $client) { return $null }
    $Sessions[$Account] = @{ Settings = $settings; Client = $client }
    return $Sessions[$Account]
}

# Closes the connections of a command: logging out, from its end block, or with -Abort, from its clean
# block, only disposing of them, since the server may be the reason it stopped
function Close-ImapSession([hashtable]$Sessions, [switch]$Abort) {
    if (-not $Sessions) { return }
    foreach ($session in @($Sessions.Values)) {
        if (-not $session) { continue }
        if ($Abort) { $session.Client.Dispose() } else { Disconnect-ImapClient $session.Client }
    }
    $Sessions.Clear()
}
