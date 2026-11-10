# The connection to the IMAP server, always encrypted: TLS from the start on port 993 (IMAPS), and STARTTLS,
# required, on any other port. MailKit's Auto is never used: with a server that offers no STARTTLS it goes on
# in plain text, password included. Only an account with NoTls (or IMAP_NO_TLS), meant for test servers such
# as smtp4dev, connects that way. The server's certificate is checked as MailKit does (a trusted issuer, the
# name of the server); only an account with SkipCertificateCheck (or IMAP_SKIP_CERTIFICATE_CHECK), for servers
# with a certificate of their own, accepts any. Both are settings of the account rather than switches of each
# command, since they are of its server: a pipeline of commands would otherwise repeat them in each one.
# Failures are reported as Errors.ps1 says, so the operations of MailKit run by their Async methods, through
# Wait-ImapTask.

# How long the LOGOUT at the end may wait for the server: a courtesy, after which the connection is closed all
# the same (MailKit would wait two minutes)
$script:LogoutTimeout = [TimeSpan]::FromSeconds(2)

# Waits for the task of an Async method of MailKit and returns $null when it succeeded, or else the message
# of its exception, without throwing it. The wait goes in short steps, so that Ctrl+C stops the command at
# once, where a synchronous call would hold PowerShell until the server answers; the command's finally block
# then disposes of the client, which ends the task. With -Timeout, it stops waiting after that long, and the
# caller disposes of the client. Every caller takes a text for a failure and nothing for success, so a failure is
# never nothing: neither a task that is missing, as when the method that should give it threw (see
# Test-ImapConnection), nor an exception whose message is empty, as MailKit gives a login refused with a response code
# and no text after it (NO [AUTHENTICATIONFAILED], measured: the login was taken for accepted, and the commands went on
# without one; found in the review before the first release).
function Wait-ImapTask([System.Threading.Tasks.Task]$Task, [TimeSpan]$Timeout = [System.Threading.Timeout]::InfiniteTimeSpan) {
    if ($null -eq $Task) { return 'The operation could not be started.' }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ([System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($Task), 200) -lt 0) {
        if ($Timeout -ge [TimeSpan]::Zero -and $stopwatch.Elapsed -ge $Timeout) { return "No answer in $($Timeout.TotalSeconds) seconds." }
    }
    if ($Task.IsFaulted) {
        $exception = $Task.Exception.InnerException
        if (-not [string]::IsNullOrWhiteSpace($exception.Message)) { return $exception.Message }
        return "The operation failed, and gave no reason ($($exception.GetType().Name))."
    }
    if ($Task.IsCanceled) { return 'The operation was canceled.' }
    return $null
}

# The check of the server's certificate that SkipCertificateCheck puts in place of MailKit's: it accepts any.
# MailKit calls it on another thread, where a script block has no runspace to run in, so it is a delegate
# compiled from an expression tree (no C# to compile, unlike Add-Type).
$script:AcceptAnyCertificate = [System.Linq.Expressions.Expression]::Lambda(
    [System.Net.Security.RemoteCertificateValidationCallback],
    [System.Linq.Expressions.Expression]::Constant($true),
    [System.Linq.Expressions.ParameterExpression[]]@(
        [System.Linq.Expressions.Expression]::Parameter([object], 'sender')
        [System.Linq.Expressions.Expression]::Parameter([System.Security.Cryptography.X509Certificates.X509Certificate], 'certificate')
        [System.Linq.Expressions.Expression]::Parameter([System.Security.Cryptography.X509Certificates.X509Chain], 'chain')
        [System.Linq.Expressions.Expression]::Parameter([System.Net.Security.SslPolicyErrors], 'errors'))
).Compile()

# How to secure a connection to the port given
function Get-SecureSocketOption([int]$Port, [switch]$NoTls) {
    if ($NoTls) { return [MailKit.Security.SecureSocketOptions]::None }
    if ($Port -eq 993) { return [MailKit.Security.SecureSocketOptions]::SslOnConnect }
    return [MailKit.Security.SecureSocketOptions]::StartTls
}

# An ImapClient connected, and not yet authenticated, to the server of the settings (as Resolve-ImapConfiguration
# returns them), or $null when it could not connect. With SkipCertificateCheck in the settings, the server's
# certificate is accepted without being checked.
function Connect-ImapServer($Cmdlet, $Settings) {
    $options = Get-SecureSocketOption $Settings.Port -NoTls:$Settings.NoTls
    $client = [MailKit.Net.Imap.ImapClient]::new()
    if ($Settings.SkipCertificateCheck) { $client.ServerCertificateValidationCallback = $script:AcceptAnyCertificate }
    $connected = $false
    try {
        Write-Verbose "Connecting to $($Settings.Server):$($Settings.Port) ($options$(if ($Settings.SkipCertificateCheck) { ', any certificate' }))..."
        $task = $client.ConnectAsync($Settings.Server, $Settings.Port, $options)
        $failure = Wait-ImapTask $task
        if ($failure) {
            # No hint at SkipCertificateCheck, which the README names with its caveat (decided with JP, 2026-11-10): the
            # module cannot tell a server with a certificate of its own from something that answers in the place of a
            # public server (a proxy that inspects the traffic, the portal of a hotel), and an agent acts on what an
            # error says. The hint came after any failure of the handshake too, where no certificate was ever seen and
            # the setting changed nothing but leave the account without the check (found in the review before the
            # first release).
            Write-ImapError $Cmdlet "Could not connect to $($Settings.Server):$($Settings.Port) ($options): $($failure.TrimEnd())" 'ConnectionFailed' ConnectionError $Settings.Server
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
function Connect-ImapClient($Cmdlet, $Settings) {
    $client = Connect-ImapServer $Cmdlet $Settings
    if (-not $client) { return $null }
    $authenticated = $false
    $answered = $false
    try {
        $authenticated = Invoke-ImapLogin $Cmdlet $client $Settings
        $answered = $true
        if ($authenticated) { return $client }
        return $null
    } finally {
        # Refused, it logs out; stopped during the login (by Ctrl+C), it only closes the connection
        if (-not $authenticated) { Disconnect-ImapClient $client -Abort:(-not $answered) }
    }
}

# Logs out, as a courtesy to the server, for LogoutTimeout at most, and closes the connection whatever happens:
# when the server does not answer, and when Ctrl+C cuts the wait short. With -Abort (a command stopped by
# Ctrl+C or a terminating error, where the server may be the reason), it only closes the connection.
function Disconnect-ImapClient($Client, [switch]$Abort) {
    try {
        if ($Abort -or -not $Client.IsConnected) { return }
        # The token ends MailKit's wait for the answer; the timeout of Wait-ImapTask, a little longer, stops
        # this one even if MailKit misses the token
        $cancel = [System.Threading.CancellationTokenSource]::new($script:LogoutTimeout)
        try {
            $failure = Wait-ImapTask ($Client.DisconnectAsync($true, $cancel.Token)) -Timeout ($script:LogoutTimeout + [TimeSpan]::FromSeconds(1))
            if ($failure) { Write-Verbose "Logging out: $failure" }
        } finally {
            $cancel.Dispose()
        }
    } finally {
        $Client.Dispose()
    }
}

# The connection of a command to an account, opened when the command first needs it and kept in $Sessions,
# a hashtable of the command, until it ends: its end block logs out with Close-ImapSession, and its clean
# block disposes of what is left after Ctrl+C or a terminating error. Returns the settings and the client,
# or $null after reporting why not, only the first time for each account. '' is the default account, or
# else the IMAP_* environment variables. The session is kept under the name of the account too, so that ''
# and the name of the default account share it: one connection, and one count of what the command handled
# (MaxMessages), whichever way the account is named.
function Get-ImapSession($Cmdlet, [hashtable]$Sessions, [string]$Account) {
    if ($Sessions.ContainsKey($Account)) { return $Sessions[$Account] }
    $Sessions[$Account] = $null
    $settings = Resolve-ImapConfiguration $Cmdlet $Account
    if (-not $settings) { return $null }
    $name = [string]$settings.Account
    if ($name -ne $Account -and $Sessions.ContainsKey($name)) {
        $Sessions[$Account] = $Sessions[$name]
        return $Sessions[$Account]
    }
    $Sessions[$name] = $null
    $client = Connect-ImapClient $Cmdlet $settings
    if (-not $client) { return $null }
    $Sessions[$Account] = $Sessions[$name] = @{ Settings = $settings; Client = $client }
    return $Sessions[$Account]
}

# Whether the connection of a session is still there; if not, reports it once for the session (ConnectionLost), and
# the account is given up for the rest of the command: whatever is left to do in it is left out, with no error of its
# own, as the commands skip an account that could not connect. Reconnecting would cost a login (2.1 s on Gmail,
# measured) and could go round in a loop with a server that keeps dropping (decided with JP, 2026-11-10). The
# operation that met the drop reports its own failure first, so a connection lost is two errors: what was being done,
# and that the rest was left out.
# Called before the operations of MailKit that check the connection before they give a task, OpenAsync and
# GetFoldersAsync: they throw (ServiceNotConnectedException), which ends only their statement, so the folder was taken
# for open and the listing for empty, and every message left gave errors that named false causes (UidValidityChanged,
# FolderNotFound; 495 errors for 250 messages, found in the review before the first release). Also before each
# operation of a loop that would otherwise fail once for each folder or attachment left.
function Test-ImapConnection($Cmdlet, $Session) {
    $client = $Session.Client
    if ($client.IsConnected -and $client.IsAuthenticated) { return $true }
    if (-not $Session.Lost) {
        $Session.Lost = $true
        $settings = $Session.Settings
        Write-ImapError $Cmdlet "The connection to $($settings.Server) was lost, so what was left to do in the mailbox of $($settings.User) was left out." 'ConnectionLost' ConnectionError $settings.Server
    }
    return $false
}

# Closes the connections of a command: logging out, from its end block, or with -Abort, from its clean
# block, only disposing of them, since the server may be the reason it stopped. The keys are account names,
# and a key hides a property of the same name: an account called "Values" would hide .Values. A session kept
# under two names is closed once.
function Close-ImapSession([hashtable]$Sessions, [switch]$Abort) {
    if (-not $Sessions) { return }
    $closed = [System.Collections.Generic.List[object]]::new()
    foreach ($session in @($Sessions.psbase.Values)) {
        if (-not $session -or $closed.Contains($session)) { continue }
        $closed.Add($session)
        Disconnect-ImapClient $session.Client -Abort:$Abort
    }
    $Sessions.Clear()
}
