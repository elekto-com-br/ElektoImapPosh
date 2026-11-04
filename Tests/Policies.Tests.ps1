# Policies: kept in accounts.json apart from the accounts, the commands that keep them, the account setting that
# names one (or IMAP_POLICY without accounts), and the policy in the settings a command reads with. The rules
# themselves are tested with the commands that read messages, which apply them.
# As in Accounts.Tests.ps1, the password stores are replaced by mocks or by IMAP_PASS_<ACCOUNT>.

BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1') -Force

    # An empty configuration folder and no variable of the module: a machine without accounts
    $variableNames = 'IMAP_CONFIG_DIR', 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS', 'IMAP_PASS_WORK', 'IMAP_PASS_HOME',
    'IMAP_NO_TLS', 'IMAP_SKIP_CERTIFICATE_CHECK', 'IMAP_ALLOW_WRITE', 'IMAP_POLICY'
    $savedEnvironment = @{}
    foreach ($name in $variableNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config'
    New-Item -ItemType Directory -Path $env:IMAP_CONFIG_DIR | Out-Null
    $accountsFile = Join-Path $env:IMAP_CONFIG_DIR 'accounts.json'

    function Clear-Environment {
        foreach ($name in $variableNames | Where-Object { $_ -ne 'IMAP_CONFIG_DIR' }) { [Environment]::SetEnvironmentVariable($name, $null) }
    }

    # Resolve-ImapConfiguration as a command calls it, with a stand-in for its $PSCmdlet that keeps the errors
    function Resolve-Configuration([string]$Account) {
        $cmdlet = [pscustomobject]@{ Errors = [System.Collections.Generic.List[object]]::new() }
        $cmdlet | Add-Member -MemberType ScriptMethod -Name WriteError -Value { param($record) $this.Errors.Add($record) }
        $settings = InModuleScope ElektoImapPosh -Parameters @{ Cmdlet = $cmdlet; Account = $Account } {
            param($Cmdlet, $Account)
            Resolve-ImapConfiguration $Cmdlet $Account
        }
        return @{ Settings = $settings; Errors = $cmdlet.Errors }
    }

    function Read-Json { Get-Content -Path $accountsFile -Raw | ConvertFrom-Json -AsHashtable }
}

AfterAll {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
    Remove-Module ElektoImapPosh -ErrorAction SilentlyContinue
}

Describe 'The policy commands' {
    BeforeEach {
        Remove-Item -Path $accountsFile -ErrorAction Ignore
        Clear-Environment
        Mock -ModuleName ElektoImapPosh Save-StoredPassword { }
        Mock -ModuleName ElektoImapPosh Read-StoredPassword { $null }
        Mock -ModuleName ElektoImapPosh Clear-StoredPassword { $true }
    }

    It 'keep a policy in accounts.json, its lists as lists and its sizes in bytes' {
        Set-ImapPolicy agent -TrustAuthenticationResults mx.google.com -DenyFolders Junk -DenyReadFrom '*@bank.example' -MaxMessages 200 -MaxMessageSize 25MB

        $text = Get-Content -Path $accountsFile -Raw
        $text | Should -Match '"DenyFolders": \[\s*"Junk"\s*\]'
        $policy = (Read-Json).Policies.agent
        @($policy.Keys) | Should -Be 'DenyFolders', 'DenyReadFrom', 'MaxMessages', 'MaxMessageSize', 'TrustAuthenticationResults'
        $policy.MaxMessageSize | Should -Be 26214400

        $listed = Get-ImapPolicy agent
        $listed.Name | Should -Be 'agent'
        $listed.DenyFolders | Should -Be 'Junk'
        $listed.DenyReadFrom | Should -Be '*@bank.example'
        $listed.MaxMessages | Should -Be 200
        $listed.TrustAuthenticationResults | Should -Be 'mx.google.com'
        $listed.AllowReadFrom | Should -BeNullOrEmpty
        $listed.MaxAgeDays | Should -BeNullOrEmpty
        $listed.Accounts | Should -BeNullOrEmpty
    }

    It 'change only the settings given, and remove those given empty or 0' {
        Set-ImapPolicy agent -MaxMessages 200 -MaxAgeDays 90 -DenyReadFrom '*@bank.example'

        Set-ImapPolicy AGENT -DenyFolders 'Finance/*', Junk -MaxAgeDays 0 -DenyReadFrom @()

        $policies = (Read-Json).Policies
        @($policies.Keys) | Should -Be 'agent'
        # In the order of the settings, not in that they were given
        @($policies.agent.Keys) | Should -Be 'DenyFolders', 'MaxMessages'
        $policies.agent.DenyFolders | Should -Be 'Finance/*', 'Junk'

        Set-ImapPolicy agent -DenyFolders '' -MaxMessages 0

        (Read-Json).Policies.agent.Count | Should -Be 0
    }

    It 'refuse -<Setting> <Value>, and change nothing' -TestCases @(
        @{ Setting = 'DenyReadFrom'; Value = 'bank.example'; Message = "*-DenyReadFrom must be a list of addresses or patterns*'bank.example' has no @*" }
        @{ Setting = 'AllowAttachmentsFrom'; Value = 'me@example.com', 'example.com'; Message = "*'example.com' has no @*" }
        @{ Setting = 'DenyAttachmentTypes'; Value = '.exe'; Message = "*-DenyAttachmentTypes must be a list of MIME types or file names, such as application/pdf, image/* or *.pdf, not '.exe'*" }
        @{ Setting = 'AllowAttachmentTypes'; Value = 'pdf'; Message = "*not 'pdf'*" }
        @{ Setting = 'DenyFolders'; Value = 'Junk', ''; Message = '*-DenyFolders must be a non-empty list of folder names or patterns, with no empty entries*' }
        @{ Setting = 'TrustAuthenticationResults'; Value = 'mx.google.com; dmarc=pass'; Message = '*-TrustAuthenticationResults must be the name of the receiving server*such as mx.google.com*' }
    ) {
        Set-ImapPolicy agent -MaxMessages 200
        $before = Get-Content -Path $accountsFile -Raw
        $parameters = @{ $Setting = $Value }

        { Set-ImapPolicy agent @parameters } | Should -Throw -ExpectedMessage $Message
        Get-Content -Path $accountsFile -Raw | Should -Be $before
    }

    It 'warn that the allow lists of senders pass no sender without TrustAuthenticationResults' {
        Set-ImapPolicy agent -AllowReadFrom '*@example.com' -AllowAttachmentsFrom '*@example.com' -WarningVariable warnings -WarningAction SilentlyContinue

        "$warnings" | Should -BeLike "Policy 'agent' has no TrustAuthenticationResults*no sender passes AllowReadFrom and AllowAttachmentsFrom.*"

        Set-ImapPolicy agent -TrustAuthenticationResults mx.google.com -WarningVariable warnings

        $warnings | Should -BeNullOrEmpty
    }

    It 'make an account follow a policy, spelled as the policy is, and none with -Policy ''''' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com" } }, "Policies": { "Agent": { "MaxMessages": 200 } } }'
        $env:IMAP_PASS_WORK = 'not-a-password'
        (Get-ImapAccount work).Policy | Should -BeNullOrEmpty

        Set-ImapAccount work -Policy agent

        (Read-Json).Accounts.work.Policy | Should -Be 'Agent'
        (Get-ImapAccount work).Policy | Should -Be 'Agent'
        (Get-ImapPolicy agent).Accounts | Should -Be 'work'
        $policy = (Resolve-Configuration work).Settings.Policy
        $policy.Name | Should -Be 'Agent'
        $policy.MaxMessages | Should -Be 200

        Set-ImapAccount work -Policy ''

        (Read-Json).Accounts.work.Keys | Should -Not -Contain 'Policy'
        (Get-ImapAccount work).Policy | Should -BeNullOrEmpty
        (Get-ImapPolicy agent).Accounts | Should -BeNullOrEmpty
        (Resolve-Configuration work).Settings.Policy | Should -BeNullOrEmpty
    }

    It 'refuse a policy that does not exist for an account, and change nothing' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com" } }, "Policies": { "agent": {} } }'
        $before = Get-Content -Path $accountsFile -Raw

        { Set-ImapAccount work -Policy agnet } | Should -Throw -ExpectedMessage "There is no policy 'agnet' in*create it with Set-ImapPolicy first. Policies: agent."
        Get-Content -Path $accountsFile -Raw | Should -Be $before
    }

    It 'keep the policies when accounts are created, changed and removed' {
        Set-ImapPolicy agent -MaxMessages 200
        Set-ImapAccount work -Server imap.example.com -User me@example.com -WarningAction SilentlyContinue
        Set-ImapAccount home -Server imap.example.net -User me@example.net -Policy agent -WarningAction SilentlyContinue
        Set-ImapAccount work -Port 143 -WarningAction SilentlyContinue
        Remove-ImapAccount home

        (Get-ImapPolicy).Name | Should -Be 'agent'
        (Get-ImapPolicy agent).MaxMessages | Should -Be 200
    }

    It 'remove the policies piped from Get-ImapPolicy, but not one an account follows' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com", "Policy": "test1" } }, "Policies": { "test1": {}, "test2": {}, "agent": {} } }'

        Get-ImapPolicy test* | Remove-ImapPolicy -ErrorVariable failures -ErrorAction SilentlyContinue

        (Get-ImapPolicy).Name | Should -Be 'test1', 'agent'
        $failures.Count | Should -Be 1
        $failures[0].FullyQualifiedErrorId | Should -BeLike 'PolicyInUse,*'
        "$($failures[0])" | Should -BeLike "The policy 'test1' is followed by the account work, which would refuse to read without it*Set-ImapAccount work -Policy ''*"
    }

    It 'warn, when removing the policy IMAP_POLICY names, that the commands will refuse to read without an account' {
        Set-ImapPolicy agent -MaxMessages 200
        $env:IMAP_POLICY = 'agent'

        Remove-ImapPolicy agent -WarningVariable warnings -WarningAction SilentlyContinue

        "$warnings" | Should -BeLike "*IMAP_POLICY still names the policy 'agent'*"
        Get-ImapPolicy | Should -BeNullOrEmpty
    }

    It 'report a policy that does not exist, but not a pattern that matches none' {
        Set-ImapPolicy agent -MaxMessages 200

        { Get-ImapPolicy other -ErrorAction Stop } | Should -Throw -ExpectedMessage "There is no policy 'other'."
        { Remove-ImapPolicy other -ErrorAction Stop } | Should -Throw -ExpectedMessage "There is no policy 'other'."
        Get-ImapPolicy o* -ErrorAction Stop | Should -BeNullOrEmpty
    }
}

Describe 'The policy a command reads with' {
    BeforeEach {
        Clear-Environment
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com", "Policy": "agent" }, "home": { "Server": "imap.example.net", "User": "me@example.net" } }, "Policies": { "agent": { "MaxMessages": 200 }, "other": {} } }'
        $env:IMAP_PASS_WORK = 'not-a-password'
        $env:IMAP_PASS_HOME = 'not-a-password'
    }

    It 'is that of the account, whatever IMAP_POLICY says' {
        $env:IMAP_POLICY = 'other'

        $work = Resolve-Configuration work
        $work.Errors | Should -BeNullOrEmpty
        $work.Settings.Policy.Name | Should -Be 'agent'
        $work.Settings.Policy.MaxMessages | Should -Be 200
        (Resolve-Configuration home).Settings.Policy | Should -BeNullOrEmpty
    }

    It 'is the one IMAP_POLICY names without accounts' {
        $env:IMAP_USER = 'me@example.com'
        $env:IMAP_PASS = 'not-a-password'

        (Resolve-Configuration).Settings.Policy | Should -BeNullOrEmpty

        $env:IMAP_POLICY = 'AGENT'

        $policy = (Resolve-Configuration).Settings.Policy
        $policy.Name | Should -Be 'agent'
        $policy.MaxMessages | Should -Be 200
    }

    # Read without it, the account would read what the policy withholds
    It 'stops a command when the policy <Case> does not exist' -TestCases @(
        @{ Case = 'of an account'; Account = 'work'; Hint = "*(named by the account 'work')*or give the account another policy (Set-ImapAccount work -Policy <name>, or '' for none)." }
        @{ Case = 'IMAP_POLICY names'; Account = ''; Hint = '*(named by the environment variable IMAP_POLICY)*or change IMAP_POLICY.' }
    ) {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com", "Policy": "gone" } } }'
        $env:IMAP_USER = 'me@example.com'
        $env:IMAP_PASS = 'not-a-password'
        $env:IMAP_POLICY = 'gone'

        $resolved = Resolve-Configuration $Account

        $resolved.Settings | Should -BeNullOrEmpty
        $resolved.Errors.Count | Should -Be 1
        $resolved.Errors[0].FullyQualifiedErrorId | Should -Be 'PolicyNotFound'
        "$($resolved.Errors[0])" | Should -BeLike "There is no policy 'gone'*so nothing is read: create it with Set-ImapPolicy*"
        "$($resolved.Errors[0])" | Should -BeLike $Hint

        # Never connecting: imap.example.com would be a ConnectionFailed
        $test = if ($Account) { @{ Account = $Account } } else { @{} }
        Test-ImapAccount @test -ErrorVariable failures -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $failures.Count | Should -Be 1
        $failures[0].FullyQualifiedErrorId | Should -BeLike 'PolicyNotFound,*'
        # The file is still read, so the account can be given another policy
        if ($Account) { (Get-ImapAccount work).Policy | Should -Be 'gone' }
    }
}

Describe 'Policies in the accounts file' {
    BeforeAll {
        Clear-Environment
    }

    It 'are read in any case, a single string as a list' {
        Set-Content -Path $accountsFile -Value '{ "accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com", "policy": "AGENT" } }, "POLICIES": { "Agent": { "maxmessages": 200, "DENYFOLDERS": "Junk" } } }'

        $policy = Get-ImapPolicy agent
        $policy.Name | Should -Be 'Agent'
        $policy.MaxMessages | Should -Be 200
        , $policy.DenyFolders | Should -BeOfType [string[]]
        $policy.DenyFolders | Should -Be 'Junk'
        $policy.Accounts | Should -Be 'work'
    }

    It 'are refused for <Case>' -TestCases @(
        @{ Case = 'two policies that differ only in case'; Message = "*'agent' and 'Agent'*differ only in case*"
            Policies = '{ "agent": {}, "Agent": {} }' }
        @{ Case = 'an invalid name'; Message = "*Invalid policy name '-agent'*"
            Policies = '{ "-agent": {} }' }
        @{ Case = 'an unknown setting'; Message = "*Unknown setting 'MaxMessage' in policy 'agent'*Settings: DenyFolders, AllowReadFrom*"
            Policies = '{ "agent": { "MaxMessage": 200 } }' }
        @{ Case = 'a setting twice'; Message = "*setting 'MaxMessages' is twice in policy 'agent'*"
            Policies = '{ "agent": { "MaxMessages": 200, "maxmessages": 100 } }' }
        @{ Case = 'a limit in a string'; Message = "*MaxMessages of policy 'agent'*must be a whole number above 0*"
            Policies = '{ "agent": { "MaxMessages": "200" } }' }
        @{ Case = 'a limit of 0'; Message = "*MaxAgeDays of policy 'agent'*must be a whole number above 0*"
            Policies = '{ "agent": { "MaxAgeDays": 0 } }' }
        @{ Case = 'a sender without @'; Message = "*DenyReadFrom of policy 'agent'*'bank.example' has no @*"
            Policies = '{ "agent": { "DenyReadFrom": ["*@example.com", "bank.example"] } }' }
        @{ Case = 'an empty list'; Message = "*AllowReadFrom of policy 'agent'*must be a non-empty list*"
            Policies = '{ "agent": { "AllowReadFrom": [] } }' }
        @{ Case = 'a server that is not a name'; Message = "*TrustAuthenticationResults of policy 'agent'*must be the name*"
            Policies = '{ "agent": { "TrustAuthenticationResults": true } }' }
        @{ Case = 'a policy that is not an object'; Message = "*Policy 'agent' in*must be a JSON object*"
            Policies = '{ "agent": ["Junk"] }' }
        @{ Case = 'Policies that are not an object'; Message = "*'Policies' in*must be a JSON object*"
            Policies = '[]' }
    ) {
        Set-Content -Path $accountsFile -Value "{ ""Policies"": $Policies }"

        { Get-ImapPolicy } | Should -Throw -ExpectedMessage $Message
    }

    It 'refuses an account whose Policy is not a name' {
        Set-Content -Path $accountsFile -Value '{ "Accounts": { "work": { "Server": "imap.example.com", "User": "me@example.com", "Policy": ["agent"] } } }'

        { Get-ImapAccount } | Should -Throw -ExpectedMessage "*Policy of account 'work'*must be a string*"
    }
}
