# Accounts and the IMAP_* environment variables: which settings a command connects with, the accounts file
# read ignoring case (as the rest of the module and the password stores are), and the account commands.
# The password stores are replaced by mocks or by IMAP_PASS_<ACCOUNT>, so no real one is read or written, but
# for the password files of Linux and macOS, under the test folder, to see a deletion that fails.

BeforeDiscovery {
    # Root deletes a file whatever the permissions of its folder
    $isRoot = -not $IsWindows -and (id -u) -eq '0'
}

BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1') -Force

    # An empty configuration folder and no variable of either module: a machine without accounts
    $variableNames = 'IMAP_CONFIG_DIR', 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS', 'IMAP_PASS_WORK',
    'IMAP_NO_TLS', 'IMAP_SKIP_CERTIFICATE_CHECK', 'IMAP_ALLOW_WRITE', 'IMAP_POLICY',
    'SMTP_SERVER', 'SMTP_PORT', 'SMTP_USER', 'SMTP_PASS'
    $savedEnvironment = @{}
    foreach ($name in $variableNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config'
    New-Item -ItemType Directory -Path $env:IMAP_CONFIG_DIR | Out-Null
    $accountsFile = Join-Path $env:IMAP_CONFIG_DIR 'accounts.json'

    # Resolve-ImapConfiguration as a command calls it, with a stand-in for its $PSCmdlet; the error it
    # reports is thrown here, for Should -Throw
    function Resolve-Configuration([string]$Account) {
        $cmdlet = [pscustomobject]@{ Errors = [System.Collections.Generic.List[object]]::new() }
        $cmdlet | Add-Member -MemberType ScriptMethod -Name WriteError -Value { param($record) $this.Errors.Add($record) }
        $settings = InModuleScope ElektoImapPosh -Parameters @{ Cmdlet = $cmdlet; Account = $Account } {
            param($Cmdlet, $Account)
            Resolve-ImapConfiguration $Cmdlet $Account
        }
        if ($cmdlet.Errors.Count -gt 0) { throw $cmdlet.Errors[0].Exception.Message }
        return $settings
    }
}

AfterAll {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
    Remove-Module ElektoImapPosh -ErrorAction SilentlyContinue
}

Describe 'Settings without accounts' {
    BeforeEach {
        Remove-Item -Path $accountsFile -ErrorAction Ignore
        foreach ($name in $variableNames | Where-Object { $_ -ne 'IMAP_CONFIG_DIR' }) { [Environment]::SetEnvironmentVariable($name, $null) }
    }

    It 'come from IMAP_USER and IMAP_PASS, with imap.gmail.com:993 by default' {
        $env:IMAP_USER = 'me@example.com'
        $env:IMAP_PASS = 'not-a-password'

        $settings = Resolve-Configuration
        $settings.Server | Should -Be 'imap.gmail.com'
        $settings.Port | Should -Be 993
        $settings.User | Should -Be 'me@example.com'
        $settings.Password | Should -Be 'not-a-password'
        $settings.Account | Should -BeNullOrEmpty
    }

    It 'take the server and the port from IMAP_SERVER and IMAP_PORT' {
        $env:IMAP_USER = 'me@example.com'
        $env:IMAP_PASS = 'not-a-password'
        $env:IMAP_SERVER = 'imap.example.com'
        $env:IMAP_PORT = '143'

        $settings = Resolve-Configuration
        $settings.Server | Should -Be 'imap.example.com'
        $settings.Port | Should -Be 143
    }

    It 'refuse an IMAP_PORT that is not a port' {
        $env:IMAP_USER = 'me@example.com'
        $env:IMAP_PASS = 'not-a-password'
        $env:IMAP_PORT = 'imaps'

        { Resolve-Configuration } | Should -Throw -ExpectedMessage '*IMAP_PORT must be a number*'
    }

    # The credentials of ElektoMailPosh are meant for sending, maybe from another mailbox
    It 'never come from the SMTP_* variables of ElektoMailPosh' {
        $env:SMTP_USER = 'robot@example.com'
        $env:SMTP_PASS = 'not-a-password'
        $env:SMTP_SERVER = 'smtp.example.com'

        { Resolve-Configuration } | Should -Throw -ExpectedMessage '*IMAP_USER and IMAP_PASS*'
    }

    # NoTls and SkipCertificateCheck make a connection less safe
    It 'have <Setting> off unless <Variable> says so' -TestCases @(
        @{ Setting = 'NoTls'; Variable = 'IMAP_NO_TLS' }
        @{ Setting = 'SkipCertificateCheck'; Variable = 'IMAP_SKIP_CERTIFICATE_CHECK' }
    ) {
        $env:IMAP_USER = 'me@example.com'
        $env:IMAP_PASS = 'not-a-password'

        (Resolve-Configuration).$Setting | Should -BeFalse
        foreach ($value in 'true', 'TRUE', '1') {
            [Environment]::SetEnvironmentVariable($Variable, $value)
            (Resolve-Configuration).$Setting | Should -BeTrue -Because "$Variable is '$value'"
        }
        foreach ($value in 'false', '0') {
            [Environment]::SetEnvironmentVariable($Variable, $value)
            (Resolve-Configuration).$Setting | Should -BeFalse -Because "$Variable is '$value'"
        }
    }

    It 'refuse a value of <Variable> other than true or false' -TestCases @(
        @{ Setting = 'NoTls'; Variable = 'IMAP_NO_TLS' }
        @{ Setting = 'SkipCertificateCheck'; Variable = 'IMAP_SKIP_CERTIFICATE_CHECK' }
    ) {
        $env:IMAP_USER = 'me@example.com'
        $env:IMAP_PASS = 'not-a-password'
        [Environment]::SetEnvironmentVariable($Variable, 'yes')

        { Resolve-Configuration } | Should -Throw -ExpectedMessage "*$Variable must be true or false*"
    }

    It 'allow the changes of the kinds IMAP_ALLOW_WRITE names, all with <Value>' -TestCases @(
        @{ Value = 'true' }, @{ Value = 'TRUE' }, @{ Value = '1' }, @{ Value = 'all' }
    ) {
        $env:IMAP_USER = 'me@example.com'
        $env:IMAP_PASS = 'not-a-password'

        (Resolve-Configuration).AllowWrite | Should -BeNullOrEmpty
        $env:IMAP_ALLOW_WRITE = $Value
        (Resolve-Configuration).AllowWrite | Should -Be 'All'
        foreach ($value in 'false', '0', 'None') {
            $env:IMAP_ALLOW_WRITE = $value
            (Resolve-Configuration).AllowWrite | Should -BeNullOrEmpty -Because "IMAP_ALLOW_WRITE is '$value'"
        }
        # Spelled and ordered as the module does
        $env:IMAP_ALLOW_WRITE = 'move, flags'
        (Resolve-Configuration).AllowWrite | Should -Be 'Flags', 'Move'
    }

    It "refuse an IMAP_ALLOW_WRITE of '<Value>'" -TestCases @(
        @{ Value = 'yes' }, @{ Value = 'Flags,Delete' }, @{ Value = 'Flags,' }, @{ Value = 'All,Move' }, @{ Value = 'None,Flags' }
    ) {
        $env:IMAP_USER = 'me@example.com'
        $env:IMAP_PASS = 'not-a-password'
        $env:IMAP_ALLOW_WRITE = $Value

        { Resolve-Configuration } | Should -Throw -ExpectedMessage '*IMAP_ALLOW_WRITE must be true, false or a list of Flags, Move, Labels, or All or None alone*'
    }

    It 'need both IMAP_USER and IMAP_PASS' {
        $env:IMAP_USER = 'me@example.com'
        $env:SMTP_PASS = 'not-a-password'

        { Resolve-Configuration } | Should -Throw -ExpectedMessage '*IMAP_USER and IMAP_PASS*'
    }
}

Describe 'Settings of an account' {
    BeforeAll {
        Set-Content -Path $accountsFile -Value '{ "Default": "work", "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com" }, "home": { "Server": "imap.example.net", "Port": 143, "User": "me@example.net" } } }'
    }

    BeforeEach {
        foreach ($name in $variableNames | Where-Object { $_ -ne 'IMAP_CONFIG_DIR' }) { [Environment]::SetEnvironmentVariable($name, $null) }
    }

    It 'are those of the default account, ignoring the IMAP_* variables' {
        $env:IMAP_SERVER = 'imap.other.example.com'
        $env:IMAP_USER = 'other@example.com'
        $env:IMAP_PASS = 'other-password'
        $env:IMAP_PASS_WORK = 'not-a-password'

        $settings = Resolve-Configuration
        $settings.Account | Should -Be 'work'
        $settings.Server | Should -Be 'imap.example.com'
        $settings.Port | Should -Be 993
        $settings.User | Should -Be 'me@example.com'
        $settings.Password | Should -Be 'not-a-password'
        $settings.PasswordSource | Should -Be 'Environment'
    }

    It 'are those of the account given, by its name in any case' {
        Mock -ModuleName ElektoImapPosh Read-StoredPassword { 'stored-password' } -ParameterFilter { $Account -eq 'home' }

        $settings = Resolve-Configuration HOME
        $settings.Account | Should -Be 'home'
        $settings.Port | Should -Be 143
        $settings.Password | Should -Be 'stored-password'
    }

    It 'have <Setting> off unless the account has it, whatever <Variable> says' -TestCases @(
        @{ Setting = 'NoTls'; Variable = 'IMAP_NO_TLS' }
        @{ Setting = 'SkipCertificateCheck'; Variable = 'IMAP_SKIP_CERTIFICATE_CHECK' }
    ) {
        $env:IMAP_PASS_WORK = 'not-a-password'
        [Environment]::SetEnvironmentVariable($Variable, 'true')

        (Resolve-Configuration work).$Setting | Should -BeFalse
    }

    It 'allow no changes to the mailbox unless the account does, whatever IMAP_ALLOW_WRITE says' {
        $env:IMAP_PASS_WORK = 'not-a-password'
        $env:IMAP_ALLOW_WRITE = 'true'

        (Resolve-Configuration work).AllowWrite | Should -BeNullOrEmpty
    }

    It 'are refused for an account without a password' {
        Mock -ModuleName ElektoImapPosh Read-StoredPassword { $null }

        { Resolve-Configuration work } | Should -Throw -ExpectedMessage "*'work' has no password*IMAP_PASS_WORK*"
    }

    It 'are refused for an account that does not exist' {
        { Resolve-Configuration office } | Should -Throw -ExpectedMessage "*no account 'office'*"
    }
}

Describe 'Passwords' {
    # Each module keeps its own, so reading can have an app password apart from the one for sending
    It 'are stored apart from those of ElektoMailPosh' {
        InModuleScope ElektoImapPosh { $script:CredentialTargetPrefix } | Should -Be 'ElektoImapPosh:'
        InModuleScope ElektoImapPosh { Get-PasswordVariableName 'my-work.box' } | Should -Be 'IMAP_PASS_MY_WORK_BOX'
    }
}

Describe 'The account commands' {
    BeforeEach {
        Remove-Item -Path $accountsFile -ErrorAction Ignore
        foreach ($name in $variableNames | Where-Object { $_ -ne 'IMAP_CONFIG_DIR' }) { [Environment]::SetEnvironmentVariable($name, $null) }
        Mock -ModuleName ElektoImapPosh Save-StoredPassword { }
        Mock -ModuleName ElektoImapPosh Read-StoredPassword { $null }
        Mock -ModuleName ElektoImapPosh Clear-StoredPassword { $true }
    }

    It 'keep the settings in accounts.json and the password in the store' {
        Set-ImapAccount -Name work -Server imap.example.com -User me@example.com -Password ([Net.NetworkCredential]::new('', 'not-a-password').SecurePassword) -Default

        $file = Get-Content -Path $accountsFile -Raw
        $file | Should -Not -BeLike '*not-a-password*'
        $json = $file | ConvertFrom-Json -AsHashtable
        $json.Default | Should -Be 'work'
        $json.Accounts.work.Server | Should -Be 'imap.example.com'
        $json.Accounts.work.User | Should -Be 'me@example.com'
        Should -Invoke -ModuleName ElektoImapPosh Save-StoredPassword -Times 1 -Exactly -ParameterFilter {
            $Account -eq 'work' -and $User -eq 'me@example.com' -and $Secret -eq 'not-a-password'
        }
    }

    It 'list the accounts, with the port by default and where the password comes from' {
        Set-Content -Path $accountsFile -Value '{ "Default": "work", "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com" }, "home": { "Server": "imap.example.net", "User": "me@example.net" } } }'
        $env:IMAP_PASS_WORK = 'not-a-password'

        $accounts = Get-ImapAccount | Sort-Object Name
        $accounts.Name | Should -Be 'home', 'work'
        $accounts.Default | Should -Be $false, $true
        $accounts.Port | Should -Be 993, 993
        $accounts.PasswordSource | Should -Be 'Missing', 'Environment'
    }

    It 'warn that the IMAP_* variables are ignored while an account is the default' {
        $env:IMAP_USER = 'me@example.com'
        $env:IMAP_PASS = 'not-a-password'

        Set-ImapAccount -Name work -Server imap.example.com -User me@example.com -Default -WarningVariable warnings -WarningAction SilentlyContinue

        # The other warning says that the account has no password
        ($warnings -join "`n") | Should -BeLike "*no longer read IMAP_USER, IMAP_PASS*"
    }

    It 'change only the settings given' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "Port": 143, "User": "me@example.com" } } }'
        $env:IMAP_PASS_WORK = 'not-a-password'

        Set-ImapAccount -Name work -Port 993

        $json = Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable
        $json.Accounts.work.Port | Should -Be 993
        $json.Accounts.work.Server | Should -Be 'imap.example.com'
        Should -Invoke -ModuleName ElektoImapPosh Save-StoredPassword -Times 0 -Exactly
    }

    It 'turn <Setting> on for an account given -<Setting>, and off with -<Setting>:$false' -TestCases @(
        @{ Setting = 'NoTls' }
        @{ Setting = 'SkipCertificateCheck' }
    ) {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com" } } }'
        $env:IMAP_PASS_WORK = 'not-a-password'
        (Get-ImapAccount work).$Setting | Should -BeFalse

        $on = @{ $Setting = $true }
        Set-ImapAccount -Name work @on

        (Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable).Accounts.work.$Setting | Should -BeTrue
        (Get-ImapAccount work).$Setting | Should -BeTrue
        (Resolve-Configuration work).$Setting | Should -BeTrue

        $off = @{ $Setting = $false }
        Set-ImapAccount -Name work @off

        (Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable).Accounts.work.Keys | Should -Not -Contain $Setting
        (Resolve-Configuration work).$Setting | Should -BeFalse
    }

    It 'allow the changes of the kinds given to -AllowWrite, and none with -AllowWrite None' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com" } } }'
        $env:IMAP_PASS_WORK = 'not-a-password'
        (Get-ImapAccount work).AllowWrite | Should -Be 'None'

        Set-ImapAccount -Name work -AllowWrite move, Flags

        (Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable).Accounts.work.AllowWrite | Should -Be 'Flags', 'Move'
        (Get-ImapAccount work).AllowWrite | Should -Be 'Flags', 'Move'
        (Resolve-Configuration work).AllowWrite | Should -Be 'Flags', 'Move'

        # A list in the file even of one, as All is
        Set-ImapAccount -Name work -AllowWrite All
        (Get-Content -Path $accountsFile -Raw) | Should -Match '"AllowWrite": \[\s*"All"\s*\]'
        (Get-ImapAccount work).AllowWrite | Should -Be 'All'
        (Resolve-Configuration work).AllowWrite | Should -Be 'All'

        Set-ImapAccount -Name work -AllowWrite None

        (Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable).Accounts.work.Keys | Should -Not -Contain 'AllowWrite'
        (Get-ImapAccount work).AllowWrite | Should -Be 'None'
        (Resolve-Configuration work).AllowWrite | Should -BeNullOrEmpty
    }

    It 'refuse <AllowWrite> with other kinds, and change nothing' -TestCases @(
        @{ AllowWrite = 'All' }, @{ AllowWrite = 'None' }
    ) {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com", "AllowWrite": ["Flags"] } } }'
        $before = Get-Content -Path $accountsFile -Raw

        { Set-ImapAccount -Name work -AllowWrite $AllowWrite, Move } | Should -Throw -ExpectedMessage '*-AllowWrite takes a list of Flags, Move, Labels, or All or None alone*'
        Get-Content -Path $accountsFile -Raw | Should -Be $before
    }

    It 'remove accounts piped from Get-ImapAccount, with their stored passwords' {
        Set-Content -Path $accountsFile -Value '{ "Default": "test1", "Accounts": { "test1": { "Server": "imap.example.com", "User": "a@example.com" }, "test2": { "Server": "imap.example.com", "User": "b@example.com" }, "work": { "Server": "imap.example.com", "User": "me@example.com" } } }'

        Get-ImapAccount test* | Remove-ImapAccount

        $json = Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable
        @($json.Accounts.Keys) | Should -Be 'work'
        $json.Default | Should -BeNullOrEmpty
        Should -Invoke -ModuleName ElektoImapPosh Clear-StoredPassword -Times 2 -Exactly
    }

    # In Turkish, "I" is not the capital of "i": -like missed "billing" for "BILL*", and for "BILLING"
    It 'find, complete and remove accounts by name or pattern alike in the Turkish culture' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "billing": { "Server": "imap.example.com", "User": "b@example.com" }, "work": { "Server": "imap.example.com", "User": "me@example.com" } } }'
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'tr-TR'
            $found = (Get-ImapAccount 'BILL*').Name
            $named = (Get-ImapAccount 'BILLING' -ErrorAction SilentlyContinue).Name
            $completed = (TabExpansion2 -inputScript 'Get-ImapMessage -Account BIL' -cursorColumn 28).CompletionMatches.CompletionText
            Remove-ImapAccount 'BILL*'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $culture
        }

        $found | Should -Be 'billing'
        $named | Should -Be 'billing'
        $completed | Should -Be 'billing'
        @((Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable).Accounts.Keys) | Should -Be 'work'
    }

    # Each command registers its parameters with the completer: one left out completes file names
    It 'completes the name of an account for -Account of every command that takes one' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "billing": { "Server": "imap.example.com", "User": "b@example.com" }, "work": { "Server": "imap.example.com", "User": "me@example.com" } } }'
        $commands = @(Get-Command -Module ElektoImapPosh | Where-Object { $_.Parameters.ContainsKey('Account') }).Name

        $commands.Count | Should -BeGreaterThan 6
        foreach ($command in $commands) {
            $line = "$command -Account bil"
            @((TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText) | Should -Be 'billing' -Because "-Account of $command should complete"
        }
        Remove-ImapAccount billing
        @((Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable).Accounts.Keys) | Should -Be 'work'
    }
}

Describe 'The configuration folder' {
    BeforeAll {
        $savedConfigDir = $env:IMAP_CONFIG_DIR
        $savedXdg = $env:XDG_CONFIG_HOME
        $env:IMAP_CONFIG_DIR = $null
    }

    AfterAll {
        $env:IMAP_CONFIG_DIR = $savedConfigDir
        $env:XDG_CONFIG_HOME = $savedXdg
    }

    It 'is ElektoImapPosh in %APPDATA% on Windows' -Skip:(-not $IsWindows) {
        InModuleScope ElektoImapPosh { Get-AccountDirectory } | Should -Be (Join-Path $env:APPDATA 'ElektoImapPosh')
    }

    # The same code for Linux and macOS, where .NET 8 and later give ~/Library/Application Support instead
    It 'is ElektoImapPosh in ~/.config on Linux and macOS, or in XDG_CONFIG_HOME' -Skip:$IsWindows {
        $env:XDG_CONFIG_HOME = $null
        InModuleScope ElektoImapPosh { Get-AccountDirectory } | Should -Be (Join-Path $HOME '.config/ElektoImapPosh')

        $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg'
        InModuleScope ElektoImapPosh { Get-AccountDirectory } | Should -Be (Join-Path $TestDrive 'xdg/ElektoImapPosh')
    }
}

Describe 'Keeping the accounts file whole' {
    BeforeEach {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com" } } }'
        $env:IMAP_PASS_WORK = 'not-a-password'
        Mock -ModuleName ElektoImapPosh Save-StoredPassword { }
        Mock -ModuleName ElektoImapPosh Read-StoredPassword { $null }
    }

    AfterEach {
        $env:IMAP_PASS_WORK = $null
    }

    # Taken as empty, Set-ImapAccount would write the new account over the others
    It 'stops a command when the file cannot be read, rather than take it as empty' {
        $lock = [IO.File]::Open($accountsFile, 'Open', 'ReadWrite', 'None')
        try {
            { Get-ImapAccount } | Should -Throw -ExpectedMessage "*Could not read the accounts file*"
            { Set-ImapAccount -Name home -Server imap.example.net -User me@example.net } | Should -Throw -ExpectedMessage "*Could not read the accounts file*"
        } finally {
            $lock.Dispose()
        }
        (Get-ImapAccount).Name | Should -Be 'work'
    }

    It 'leaves the previous file whole when writing fails halfway' {
        Mock -ModuleName ElektoImapPosh Set-Content { [IO.File]::WriteAllText($LiteralPath, '{ "Accounts": {'); throw 'The disk is full.' }

        { Set-ImapAccount -Name home -Server imap.example.net -User me@example.net -WarningAction SilentlyContinue } | Should -Throw -ExpectedMessage '*disk is full*'

        (Get-ImapAccount).Name | Should -Be 'work'
        @(Get-ChildItem -Path $env:IMAP_CONFIG_DIR -Filter '*.tmp') | Should -BeNullOrEmpty
    }

    It 'keeps an account whose password could not be deleted' {
        Mock -ModuleName ElektoImapPosh Clear-StoredPassword { throw 'Access to the password is denied.' }

        { Remove-ImapAccount work } | Should -Throw -ExpectedMessage '*denied*'

        (Get-ImapAccount).Name | Should -Be 'work'
    }
}

# The real password file, under the test folder (so not on Windows, where the store is the Credential Manager),
# in a folder where it cannot be deleted (so not as root)
Describe 'A password file that cannot be deleted' -Skip:($IsWindows -or $isRoot) {
    BeforeAll {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com" } } }'
        $env:IMAP_PASS_WORK = $null
    }

    It 'is reported, and its account kept' {
        Set-ImapAccount -Name work -Password ([Net.NetworkCredential]::new('', 'not-a-password').SecurePassword)
        $secrets = Join-Path $env:IMAP_CONFIG_DIR 'secrets'
        [IO.File]::SetUnixFileMode($secrets, 'UserRead, UserExecute')
        try {
            { Remove-ImapAccount work } | Should -Throw
        } finally {
            [IO.File]::SetUnixFileMode($secrets, 'UserRead, UserWrite, UserExecute')
        }

        (Get-ImapAccount).Name | Should -Be 'work'
        Join-Path $secrets 'work' | Should -Exist
        Remove-ImapAccount work
        Join-Path $secrets 'work' | Should -Not -Exist
    }
}

# The settings hold no password, but servers and users: a file the user made owner-only stays so
Describe 'The mode of the accounts file' -Skip:$IsWindows {
    It 'is kept when the file is written, and the new file has it before anything is written to it' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com" } } }'
        $ownerOnly = [IO.UnixFileMode]'UserRead, UserWrite'
        [IO.File]::SetUnixFileMode($accountsFile, $ownerOnly)
        $env:IMAP_PASS_WORK = 'not-a-password'
        # The mode of the new file when its settings are written to it
        $seen = @{}
        Mock -ModuleName ElektoImapPosh Set-Content {
            $seen.Mode = if (Test-Path -LiteralPath $LiteralPath) { [IO.File]::GetUnixFileMode($LiteralPath) } else { 'not created yet' }
            [IO.File]::WriteAllText($LiteralPath, "$Value")
        }
        try {
            Set-ImapAccount -Name work -Port 143
        } finally {
            $env:IMAP_PASS_WORK = $null
        }

        $seen.Mode | Should -Be $ownerOnly
        [IO.File]::GetUnixFileMode($accountsFile) | Should -Be $ownerOnly
        (Get-ImapAccount work).Port | Should -Be 143
    }
}

Describe 'The accounts file, read ignoring case' {
    BeforeAll {
        $env:IMAP_PASS_WORK = 'not-a-password'
    }

    It 'reads Default and Accounts in any case' {
        Set-Content -Path $accountsFile -Value '{ "default": "work", "accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com" } } }'

        $account = Get-ImapAccount
        $account.Name | Should -Be 'work'
        $account.Default | Should -BeTrue
    }

    It 'reads the settings in any case' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "server": "imap.example.com", "USER": "me@example.com", "port": 143, "notls": true, "SKIPCERTIFICATECHECK": true, "allowwrite": ["labels", "FLAGS"] } } }'

        $account = Get-ImapAccount work
        $account.Server | Should -Be 'imap.example.com'
        $account.User | Should -Be 'me@example.com'
        $account.Port | Should -Be 143
        $account.NoTls | Should -BeTrue
        $account.SkipCertificateCheck | Should -BeTrue
        $account.AllowWrite | Should -Be 'Flags', 'Labels'
    }

    # A string such as "false" would be true for PowerShell
    It 'refuses a <Setting> that is not true or false' -TestCases @(
        @{ Setting = 'NoTls' }
        @{ Setting = 'SkipCertificateCheck' }
    ) {
        Set-Content -Path $accountsFile -Value "{ ""Accounts"": { ""work"": { ""Server"": ""imap.example.com"", ""User"": ""me@example.com"", ""$Setting"": ""false"" } } }"

        { Get-ImapAccount } | Should -Throw -ExpectedMessage "*$Setting of account 'work'*must be true or false*"
    }

    It 'reads an AllowWrite of <Value> as <Expected>' -TestCases @(
        @{ Value = 'true'; Expected = 'All' }
        @{ Value = 'false'; Expected = 'None' }
        @{ Value = '[]'; Expected = 'None' }
        @{ Value = '"move"'; Expected = 'Move' }
    ) {
        Set-Content -Path $accountsFile -Value "{ ""Accounts"": { ""work"": { ""Server"": ""imap.example.com"", ""User"": ""me@example.com"", ""AllowWrite"": $Value } } }"

        (Get-ImapAccount work).AllowWrite | Should -Be $Expected
    }

    It 'refuses an AllowWrite of <Value>' -TestCases @(
        @{ Value = '"false"' }, @{ Value = '["Flags", "Delete"]' }, @{ Value = '["All", "Move"]' }, @{ Value = '1' }, @{ Value = '[true]' }, @{ Value = 'null' }
    ) {
        Set-Content -Path $accountsFile -Value "{ ""Accounts"": { ""work"": { ""Server"": ""imap.example.com"", ""User"": ""me@example.com"", ""AllowWrite"": $Value } } }"

        { Get-ImapAccount } | Should -Throw -ExpectedMessage "*AllowWrite of account 'work'*must be true, false or a list of Flags, Move, Labels, or All or None alone*"
    }

    It 'finds an account by its name in any case' {
        Set-Content -Path $accountsFile -Value '{ "Default": "WORK", "Accounts": { "Work": { "Server": "imap.example.com", "User": "me@example.com" } } }'

        (Get-ImapAccount wORK).Name | Should -Be 'Work'
        (Get-ImapAccount w*).Name | Should -Be 'Work'
        (Get-ImapAccount Work).Default | Should -BeTrue
    }

    It 'keeps the spelling of the name when an account is changed by another' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "Work": { "Server": "imap.example.com", "User": "me@example.com" } } }'

        Set-ImapAccount -Name WORK -Port 143

        $file = Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable
        @($file.Accounts.Keys) | Should -Be 'Work'
        $file.Accounts.Work.Port | Should -Be 143
    }

    It 'removes an account by its name in any case' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "Work": { "Server": "imap.example.com", "User": "me@example.com" } } }'
        Mock -ModuleName ElektoImapPosh Clear-StoredPassword { $false }

        # It warns, rightly, that IMAP_PASS_WORK still holds the password
        Remove-ImapAccount WORK -WarningAction SilentlyContinue

        $file = Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable
        $file.Accounts.Count | Should -Be 0
    }
}

Describe 'Names in the accounts file that would be the same' {
    It 'are refused for <Case>' -TestCases @(
        @{ Case = 'two accounts'; Message = "*'Work' and 'work'*differ only in case*"
            Json = '{ "Accounts": { "Work": { "Server": "a.example.com", "User": "a@example.com" }, "work": { "Server": "b.example.com", "User": "b@example.com" } } }' }
        @{ Case = 'two accounts with one password variable'; Message = "*'work.prod' and 'work-prod'*share the password variable IMAP_PASS_WORK_PROD*"
            Json = '{ "Accounts": { "work.prod": { "Server": "a.example.com", "User": "a@example.com" }, "work-prod": { "Server": "b.example.com", "User": "b@example.com" } } }' }
        @{ Case = 'a key'; Message = "*key 'Default' is twice*"
            Json = '{ "Default": "work", "default": "work", "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com" } } }' }
        @{ Case = 'a setting'; Message = "*setting 'Server' is twice*"
            Json = '{ "Accounts": { "work": { "Server": "a.example.com", "server": "b.example.com", "User": "me@example.com" } } }' }
    ) {
        Set-Content -Path $accountsFile -Value $Json

        { Get-ImapAccount } | Should -Throw -ExpectedMessage $Message
    }

    # IMAP_PASS_WORK_PROD would give the password of one to the server of the other
    It 'are refused for a new account that would share the password variable of another' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work.prod": { "Server": "a.example.com", "User": "a@example.com" } } }'

        { Set-ImapAccount -Name work-prod -Server b.example.com -User b@example.com } | Should -Throw -ExpectedMessage "*IMAP_PASS_WORK_PROD with the account 'work.prod'*"

        (Get-ImapAccount).Name | Should -Be 'work.prod'
    }
}
