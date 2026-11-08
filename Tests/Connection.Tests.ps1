# The connection: always encrypted unless the account's NoTls says otherwise, and Test-ImapAccount against a real IMAP
# server, smtp4dev, which requires a user and password here so that a wrong one can be told apart. The tests
# that need smtp4dev are skipped where it is not installed.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Smtp4dev.ps1')
    $smtp4devInstalled = Test-Smtp4devInstalled
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Smtp4dev.ps1')
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1') -Force

    $variableNames = 'IMAP_CONFIG_DIR', 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS', 'IMAP_NO_TLS', 'IMAP_SKIP_CERTIFICATE_CHECK',
    'IMAP_PASS_LOCAL', 'IMAP_PASS_CLOSED', 'IMAP_PASS_ENCRYPTED', 'IMAP_PASS_STARTTLS', 'IMAP_PASS_CHECKED', 'IMAP_PASS_IMPLICIT'
    $savedEnvironment = @{}
    foreach ($name in $variableNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "env:$name" -ErrorAction Ignore
    }
    $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config'

    # An IMAP server just enough for MailKit to log in, in a runspace of its own, which stays silent at the
    # command named by -Hang (LOGIN or LOGOUT): a server that does not answer. State says what it received,
    # and when the connection was closed.
    function Start-FakeImapServer([ValidateSet('LOGIN', 'LOGOUT')][string]$Hang) {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $state = [hashtable]::Synchronized(@{ Commands = [Collections.Concurrent.ConcurrentQueue[string]]::new(); Closed = $false; Client = $null })
        $runspace = [powershell]::Create().AddScript({
            param($Listener, $State, $Hang)
            try {
                $client = $Listener.AcceptTcpClient()
                $State.Client = $client
                $stream = $client.GetStream()
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII)
                $writer = [IO.StreamWriter]::new($stream, [Text.Encoding]::ASCII)
                $writer.NewLine = "`r`n"
                $writer.AutoFlush = $true
                $writer.WriteLine('* OK [CAPABILITY IMAP4rev1] Fake server ready')
                while ($null -ne ($line = $reader.ReadLine())) {
                    $tag, $command, $arguments = $line -split ' ', 3
                    $command = $command.ToUpperInvariant()
                    $State.Commands.Enqueue($command)
                    if ($command -eq $Hang) { continue }
                    switch ($command) {
                        'CAPABILITY' { $writer.WriteLine('* CAPABILITY IMAP4rev1') }
                        'LIST' { $writer.WriteLine($(if ($arguments -match 'INBOX') { '* LIST (\HasNoChildren) "/" INBOX' } else { '* LIST (\Noselect) "/" ""' })) }
                        'LOGOUT' { $writer.WriteLine('* BYE Fake server logging out') }
                    }
                    $writer.WriteLine("$tag OK $command completed")
                }
            } catch {
                # The listener or the connection closed by Stop-FakeImapServer
            } finally {
                $State.Closed = $true
            }
        }).AddArgument($listener).AddArgument($state).AddArgument($Hang)
        $null = $runspace.BeginInvoke()
        [pscustomobject]@{ Port = $listener.LocalEndpoint.Port; Listener = $listener; Runspace = $runspace; State = $state }
    }

    function Stop-FakeImapServer($Server) {
        $Server.Listener.Stop()
        if ($Server.State.Client) { $Server.State.Client.Dispose() }
        $null = $Server.Runspace.BeginStop($null, $null)
        $Server.Runspace.Dispose()
    }

    # Waits a little for something that should happen soon, such as the connection closed
    function Wait-Until([scriptblock]$Condition, [double]$Seconds = 2) {
        $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
        while (-not (& $Condition) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        return [bool](& $Condition)
    }

    # Test-ImapAccount in a runspace of its own, with the IMAP_* variables pointing at the port given. With
    # -ThenWait, a command down the pipeline takes its result slowly, saying so in State.Output.
    function Start-TestImapAccount([int]$Port, [hashtable]$State, [switch]$ThenWait) {
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'no-accounts'
        $env:IMAP_SERVER = '127.0.0.1'
        $env:IMAP_PORT = "$Port"
        $env:IMAP_USER = 'tester'
        $env:IMAP_PASS = 'not-a-password'
        $env:IMAP_NO_TLS = 'true'
        $runspace = [powershell]::Create()
        $null = $runspace.AddScript({
            param($Manifest, $State, $ThenWait)
            Import-Module $Manifest
            if ($ThenWait) { Test-ImapAccount | ForEach-Object { $State.Output = $true; Start-Sleep -Seconds 30 } }
            else { Test-ImapAccount }
        }).AddArgument((Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1')).AddArgument($State).AddArgument([bool]$ThenWait)
        [pscustomobject]@{ Runspace = $runspace; Result = $runspace.BeginInvoke() }
    }

    function Reset-ImapVariables {
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config'
        foreach ($name in 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS', 'IMAP_NO_TLS', 'IMAP_SKIP_CERTIFICATE_CHECK') { Remove-Item -LiteralPath "env:$name" -ErrorAction Ignore }
    }
}

AfterAll {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        Set-Item -LiteralPath "env:$($entry.Key)" -Value $entry.Value
    }
    Remove-Module ElektoImapPosh -ErrorAction SilentlyContinue
}

Describe 'How the connection is secured' {
    # MailKit's Auto would go on in plain text with a server that offers no STARTTLS
    It 'is <Expected> for port <Port>' -TestCases @(
        @{ Port = 993; Expected = 'SslOnConnect' }
        @{ Port = 143; Expected = 'StartTls' }
        @{ Port = 1143; Expected = 'StartTls' }
    ) {
        InModuleScope ElektoImapPosh -Parameters @{ Port = $Port } { param($Port) "$(Get-SecureSocketOption $Port)" } | Should -Be $Expected
    }

    It 'is none at all with NoTls, on any port' {
        InModuleScope ElektoImapPosh { "$(Get-SecureSocketOption 993 -NoTls)" } | Should -Be 'None'
    }
}

Describe 'Waiting for the server' {
    # A synchronous call of MailKit would hold PowerShell until the server answered, or for its timeout of two minutes
    It 'stops at once on Ctrl+C, even when the server never answers' {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $powershell = [powershell]::Create()
        try {
            # It takes the connection and never sends the greeting, so the connection waits for it
            $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'no-accounts'
            $env:IMAP_SERVER = '127.0.0.1'
            $env:IMAP_PORT = "$($listener.LocalEndpoint.Port)"
            $env:IMAP_USER = 'tester'
            $env:IMAP_PASS = 'not-a-password'
            $env:IMAP_NO_TLS = 'true'
            $null = $powershell.AddScript({
                param($Manifest)
                Import-Module $Manifest
                Test-ImapAccount
            }).AddArgument((Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1'))
            $null = $powershell.BeginInvoke()
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not $listener.Pending() -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $listener.Pending() | Should -BeTrue -Because 'Test-ImapAccount should be connecting by now'

            # What Ctrl+C does
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $powershell.Stop()

            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 2
        } finally {
            $powershell.Dispose()
            $listener.Stop()
            Reset-ImapVariables
        }
    }

    # While the login waits, MailKit takes no other command, so no LOGOUT goes out: only the connection is closed
    It 'stops at once on Ctrl+C during the login, and closes the connection without logging out' {
        $server = Start-FakeImapServer -Hang LOGIN
        $command = Start-TestImapAccount $server.Port
        try {
            Wait-Until { $server.State.Commands -contains 'LOGIN' } 30 | Should -BeTrue -Because 'Test-ImapAccount should be logging in by now'

            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $command.Runspace.Stop()

            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 1
            Wait-Until { $server.State.Closed } | Should -BeTrue -Because 'the connection should be closed'
            $server.State.Commands | Should -Not -Contain 'LOGOUT'
        } finally {
            $command.Runspace.Dispose()
            Stop-FakeImapServer $server
            Reset-ImapVariables
        }
    }

    # Stopped with the client idle, the command has no reason to wait for the server: it only closes the connection
    It 'closes the connection without logging out on Ctrl+C after the login, while the pipeline takes its result' {
        $server = Start-FakeImapServer -Hang LOGOUT
        $command = Start-TestImapAccount $server.Port $server.State -ThenWait
        try {
            Wait-Until { $server.State.Output } 30 | Should -BeTrue -Because 'Test-ImapAccount should have written its result by now'

            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $command.Runspace.Stop()

            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 1
            Wait-Until { $server.State.Closed } | Should -BeTrue -Because 'the connection should be closed'
            $server.State.Commands | Should -Not -Contain 'LOGOUT'
        } finally {
            $command.Runspace.Dispose()
            Stop-FakeImapServer $server
            Reset-ImapVariables
        }
    }

    # The logout is in a finally block, and Ctrl+C there must not leave the connection open
    It 'stops at once on Ctrl+C while logging out, and closes the connection' {
        $server = Start-FakeImapServer -Hang LOGOUT
        $command = Start-TestImapAccount $server.Port
        try {
            Wait-Until { $server.State.Commands -contains 'LOGOUT' } 30 | Should -BeTrue -Because 'Test-ImapAccount should be logging out by now'

            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $command.Runspace.Stop()

            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 1
            Wait-Until { $server.State.Closed } | Should -BeTrue -Because 'the connection should be closed'
        } finally {
            $command.Runspace.Dispose()
            Stop-FakeImapServer $server
            Reset-ImapVariables
        }
    }

    # MailKit would wait two minutes for the answer
    It 'gives up a logout the server does not answer after a few seconds, and closes the connection' {
        $server = Start-FakeImapServer -Hang LOGOUT
        $command = Start-TestImapAccount $server.Port
        try {
            $command.Result.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(10)) | Should -BeTrue -Because 'the logout should be given up after 2 seconds'

            $result = $command.Runspace.EndInvoke($command.Result)
            $result.User | Should -Be 'tester'
            $server.State.Commands | Should -Contain 'LOGOUT'
            Wait-Until { $server.State.Closed } | Should -BeTrue -Because 'the connection should be closed'
        } finally {
            $command.Runspace.Dispose()
            Stop-FakeImapServer $server
            Reset-ImapVariables
        }
    }
}

Describe 'Test-ImapAccount against smtp4dev' -Skip:(-not $smtp4devInstalled) {
    BeforeAll {
        $server = Start-Smtp4dev -LogDirectory (Join-Path $TestDrive 'smtp4dev') -ArgumentList '--authenticationrequired', '--user=tester=not-a-password'

        # "closed" points at a port where nothing listens, and "encrypted" is the server of "local" without NoTls
        New-Item -ItemType Directory -Path $env:IMAP_CONFIG_DIR -Force | Out-Null
        $accounts = @{
            Accounts = @{
                local     = @{ Server = '127.0.0.1'; Port = $server.ImapPort; User = 'tester'; NoTls = $true }
                closed    = @{ Server = '127.0.0.1'; Port = (Get-FreeTcpPort); User = 'tester'; NoTls = $true }
                encrypted = @{ Server = '127.0.0.1'; Port = $server.ImapPort; User = 'tester' }
            }
        }
        Set-Content -Path (Join-Path $env:IMAP_CONFIG_DIR 'accounts.json') -Value ($accounts | ConvertTo-Json -Depth 5)
    }

    AfterAll {
        Stop-Smtp4dev $server
    }

    BeforeEach {
        $env:IMAP_PASS_LOCAL = 'not-a-password'
        $env:IMAP_PASS_CLOSED = 'not-a-password'
        $env:IMAP_PASS_ENCRYPTED = 'not-a-password'
    }

    It 'connects in plain text to an account with NoTls, and authenticates' {
        $result = Test-ImapAccount local

        $result.Account | Should -Be 'local'
        $result.Port | Should -Be $server.ImapPort
        $result.Security | Should -Be 'None'
        $result.SslProtocol | Should -Be 'None'
        $result.Capabilities | Should -Contain 'IMAP4rev1'
    }

    # Each failure is one error, also in -ErrorVariable and $Error (see Private/Errors.ps1)
    It 'refuses to go on in plain text with an account without NoTls' {
        $result = Test-ImapAccount encrypted -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'ConnectionFailed,*'
        "$errors" | Should -BeLike '*(StartTls)*STARTTLS*'
    }

    It 'reports a password the server does not accept' {
        $env:IMAP_PASS_LOCAL = 'wrong-password'

        $result = Test-ImapAccount local -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AuthenticationFailed,*'
        "$errors" | Should -BeLike '*did not accept the user tester*'
    }

    It 'reports an account that does not exist' {
        $result = Test-ImapAccount office -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AccountNotFound,*'
    }

    It 'tests every account piped from Get-ImapAccount, reporting those that fail' {
        $results = Get-ImapAccount | Test-ImapAccount -ErrorVariable errors -ErrorAction SilentlyContinue

        @($results).Account | Should -Be 'local'
        $errors.Count | Should -Be 2
        foreach ($item in $errors) { "$item" | Should -BeLike '*Could not connect to 127.0.0.1:*' }
    }

    It 'uses the IMAP_* environment variables when there is no account' {
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'no-accounts'
        $env:IMAP_SERVER = '127.0.0.1'
        $env:IMAP_PORT = "$($server.ImapPort)"
        $env:IMAP_USER = 'tester'
        $env:IMAP_PASS = 'not-a-password'
        $env:IMAP_NO_TLS = 'true'
        try {
            $result = Test-ImapAccount

            $result.Account | Should -BeNullOrEmpty
            $result.User | Should -Be 'tester'
            $result.Security | Should -Be 'None'
        } finally {
            Reset-ImapVariables
        }
    }
}

# Encrypted connections, which smtp4dev has not on IMAP: a proxy in front of it puts TLS, with a self-signed
# certificate that only SkipCertificateCheck accepts
Describe 'Encrypted connections, through a TLS proxy in front of smtp4dev' -Skip:(-not $smtp4devInstalled) {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TlsProxy.ps1')
        $server = Start-Smtp4dev -LogDirectory (Join-Path $TestDrive 'smtp4dev-tls') -ArgumentList '--authenticationrequired', '--user=tester=not-a-password'
        $startTls = [ElektoImapPoshTests.TlsProxy]::new($server.ImapPort, $true, 0)
        # Implicit TLS is for port 993 only, which an ordinary user cannot open on Linux and macOS
        $implicit = try { [ElektoImapPoshTests.TlsProxy]::new($server.ImapPort, $false, 993) } catch { $null }

        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config-tls'
        New-Item -ItemType Directory -Path $env:IMAP_CONFIG_DIR -Force | Out-Null
        # "checked" is the server of "starttls", checking its certificate
        $accounts = @{
            Accounts = @{
                starttls = @{ Server = '127.0.0.1'; Port = $startTls.Port; User = 'tester'; SkipCertificateCheck = $true }
                checked  = @{ Server = '127.0.0.1'; Port = $startTls.Port; User = 'tester' }
                implicit = @{ Server = '127.0.0.1'; Port = 993; User = 'tester'; SkipCertificateCheck = $true }
            }
        }
        Set-Content -Path (Join-Path $env:IMAP_CONFIG_DIR 'accounts.json') -Value ($accounts | ConvertTo-Json -Depth 5)
        $env:IMAP_PASS_STARTTLS = 'not-a-password'
        $env:IMAP_PASS_CHECKED = 'not-a-password'
        $env:IMAP_PASS_IMPLICIT = 'not-a-password'
    }

    AfterAll {
        $startTls.Dispose()
        if ($implicit) { $implicit.Dispose() }
        Stop-Smtp4dev $server
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config'
    }

    It 'connects by STARTTLS and authenticates, accepting the certificate for an account with SkipCertificateCheck' {
        $result = Test-ImapAccount starttls

        $result.Security | Should -Be 'StartTls'
        $result.SslProtocol | Should -BeIn 'Tls12', 'Tls13'
        $result.User | Should -Be 'tester'
        $startTls.Handshakes | Should -BeGreaterThan 0
    }

    It 'refuses a certificate that does not validate, for an account without SkipCertificateCheck' {
        $result = Test-ImapAccount checked -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'ConnectionFailed,*'
        "$errors" | Should -BeLike '*certificate*Set-ImapAccount checked -SkipCertificateCheck accepts it.)'
    }

    It 'lists folders over TLS, SkipCertificateCheck going through the connection of the command' {
        (Get-ImapFolder starttls Inbox).Folder | Should -Be 'INBOX'
    }

    It 'accepts the certificate with IMAP_SKIP_CERTIFICATE_CHECK when there is no account, and refuses it without' {
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'no-accounts'
        $env:IMAP_SERVER = '127.0.0.1'
        $env:IMAP_PORT = "$($startTls.Port)"
        $env:IMAP_USER = 'tester'
        $env:IMAP_PASS = 'not-a-password'
        try {
            $result = Test-ImapAccount -ErrorVariable errors -ErrorAction SilentlyContinue

            $result | Should -BeNullOrEmpty
            "$errors" | Should -BeLike '*IMAP_SKIP_CERTIFICATE_CHECK=true accepts it.)'

            $env:IMAP_SKIP_CERTIFICATE_CHECK = 'true'
            $result = Test-ImapAccount

            $result.Security | Should -Be 'StartTls'
            $result.SslProtocol | Should -BeIn 'Tls12', 'Tls13'
        } finally {
            Reset-ImapVariables
            $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config-tls'
        }
    }

    It 'connects with TLS from the start on port 993' {
        if (-not $implicit) {
            Set-ItResult -Skipped -Because 'port 993 of the loopback cannot be opened here (by an ordinary user on Linux and macOS, or in use)'
            return
        }

        $result = Test-ImapAccount implicit

        $result.Security | Should -Be 'SslOnConnect'
        $result.SslProtocol | Should -BeIn 'Tls12', 'Tls13'
        $implicit.Handshakes | Should -BeGreaterThan 0
    }
}
