# The connection: always encrypted unless -NoTls says otherwise, and Test-ImapAccount against a real IMAP
# server, smtp4dev, which requires a user and password here so that a wrong one can be told apart. The tests
# that need smtp4dev are skipped where it is not installed.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Smtp4dev.ps1')
    $smtp4devInstalled = Test-Smtp4devInstalled
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Smtp4dev.ps1')
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1') -Force

    $variableNames = 'IMAP_CONFIG_DIR', 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS', 'IMAP_PASS_LOCAL', 'IMAP_PASS_CLOSED'
    $savedEnvironment = @{}
    foreach ($name in $variableNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config'
}

AfterAll {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
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

    It 'is none at all with -NoTls, on any port' {
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
            $null = $powershell.AddScript({
                param($Manifest)
                Import-Module $Manifest
                Test-ImapAccount -NoTls
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
            $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config'
            foreach ($name in 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS') { [Environment]::SetEnvironmentVariable($name, $null) }
        }
    }
}

Describe 'Test-ImapAccount against smtp4dev' -Skip:(-not $smtp4devInstalled) {
    BeforeAll {
        $server = Start-Smtp4dev -LogDirectory (Join-Path $TestDrive 'smtp4dev') -ArgumentList '--authenticationrequired', '--user=tester=not-a-password'

        # "closed" points at a port where nothing listens
        New-Item -ItemType Directory -Path $env:IMAP_CONFIG_DIR -Force | Out-Null
        $accounts = @{
            Accounts = @{
                local  = @{ Server = '127.0.0.1'; Port = $server.ImapPort; User = 'tester' }
                closed = @{ Server = '127.0.0.1'; Port = (Get-FreeTcpPort); User = 'tester' }
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
    }

    It 'connects in plain text with -NoTls and authenticates' {
        $result = Test-ImapAccount local -NoTls

        $result.Account | Should -Be 'local'
        $result.Port | Should -Be $server.ImapPort
        $result.Security | Should -Be 'None'
        $result.SslProtocol | Should -Be 'None'
        $result.Capabilities | Should -Contain 'IMAP4rev1'
    }

    # Each failure is one error, also in -ErrorVariable and $Error (see Private/Errors.ps1)
    It 'refuses to go on in plain text without -NoTls' {
        $result = Test-ImapAccount local -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'ConnectionFailed,*'
        "$errors" | Should -BeLike '*(StartTls)*STARTTLS*'
    }

    It 'reports a password the server does not accept' {
        $env:IMAP_PASS_LOCAL = 'wrong-password'

        $result = Test-ImapAccount local -NoTls -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AuthenticationFailed,*'
        "$errors" | Should -BeLike '*did not accept the user tester*'
    }

    It 'reports an account that does not exist' {
        $result = Test-ImapAccount office -NoTls -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AccountNotFound,*'
    }

    It 'tests every account piped from Get-ImapAccount, reporting the one that fails' {
        $results = Get-ImapAccount | Test-ImapAccount -NoTls -ErrorVariable errors -ErrorAction SilentlyContinue

        @($results).Account | Should -Be 'local'
        $errors.Count | Should -Be 1
        "$errors" | Should -BeLike '*Could not connect to 127.0.0.1:*'
    }

    It 'uses the IMAP_* environment variables when there is no account' {
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'no-accounts'
        $env:IMAP_SERVER = '127.0.0.1'
        $env:IMAP_PORT = "$($server.ImapPort)"
        $env:IMAP_USER = 'tester'
        $env:IMAP_PASS = 'not-a-password'
        try {
            $result = Test-ImapAccount -NoTls

            $result.Account | Should -BeNullOrEmpty
            $result.User | Should -Be 'tester'
        } finally {
            $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config'
            foreach ($name in 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS') { [Environment]::SetEnvironmentVariable($name, $null) }
        }
    }
}
