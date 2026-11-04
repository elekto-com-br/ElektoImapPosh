# Starts and stops smtp4dev (https://github.com/rnwood/smtp4dev), a fake mail server with an IMAP server, for
# the tests that need a real one. The tests that use it are skipped where it is not installed (a global .NET
# tool: dotnet tool install -g Rnwood.Smtp4dev). It runs in memory, on free ports of the loopback only, without
# reading the user's settings, and is stopped with its process tree. Its IMAP server has no TLS: the tests
# connect with -NoTls.

function Test-Smtp4devInstalled {
    return [bool](Get-Command smtp4dev -CommandType Application -ErrorAction Ignore)
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

# Starts smtp4dev and waits until its IMAP server takes connections. Returns the process and the ports.
# The arguments given are added to those that keep it in memory and on the loopback.
function Start-Smtp4dev([string]$LogDirectory, [string[]]$ArgumentList = @()) {
    $command = Get-Command smtp4dev -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $server = [pscustomobject]@{ Process = $null; SmtpPort = Get-FreeTcpPort; ImapPort = Get-FreeTcpPort; WebPort = Get-FreeTcpPort }
    $arguments = @(
        '--nousersettings', '--allowremoteconnections-', '--bindaddress=127.0.0.1', '--db=', '--tlsmode=None',
        "--smtpport=$($server.SmtpPort)", "--imapport=$($server.ImapPort)", '--pop3port=', "--urls=http://127.0.0.1:$($server.WebPort)"
    ) + $ArgumentList
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $server.Process = Start-Process -FilePath $command.Source -ArgumentList $arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $LogDirectory 'smtp4dev.out.log') -RedirectStandardError (Join-Path $LogDirectory 'smtp4dev.err.log')

    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while ($true) {
        if ($server.Process.HasExited) { throw "smtp4dev exited with code $($server.Process.ExitCode); its output is in $LogDirectory." }
        $probe = [Net.Sockets.TcpClient]::new()
        try {
            $probe.Connect([Net.IPAddress]::Loopback, $server.ImapPort)
            return $server
        } catch [Net.Sockets.SocketException] {
            if ([DateTime]::UtcNow -gt $deadline) {
                Stop-Smtp4dev $server
                throw "smtp4dev did not open its IMAP port in 60 seconds; its output is in $LogDirectory."
            }
            Start-Sleep -Milliseconds 250
        } finally {
            $probe.Dispose()
        }
    }
}

# Stops smtp4dev and what it started (on Windows, the .cmd of the tool starts the server as a child)
function Stop-Smtp4dev($Server) {
    if ($Server.Process -and -not $Server.Process.HasExited) {
        $Server.Process.Kill($true)
        $Server.Process.WaitForExit(10000) | Out-Null
    }
}
