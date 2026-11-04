# Messages: the one check of a policy, on the metadata of each message; Get-ImapMessage against smtp4dev, for the
# search, the filters and the policies; and against a fake Gmail, for what only Gmail has (labels, threads, X-GM-RAW)
# and for attachments, which the BODYSTRUCTURE of smtp4dev leaves out. The tests that need smtp4dev are skipped where
# it is not installed.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Smtp4dev.ps1')
    $smtp4devInstalled = Test-Smtp4devInstalled
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Smtp4dev.ps1')
    . (Join-Path $PSScriptRoot 'FakeGmail.ps1')
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1') -Force

    $variableNames = 'IMAP_CONFIG_DIR', 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS', 'IMAP_NO_TLS', 'IMAP_POLICY'
    $savedEnvironment = @{}
    foreach ($name in $variableNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }

    # Writes an accounts file in a folder of its own, every account on the port given, with its password in the
    # environment; returns the names of the password variables, for AfterAll to remove
    function Set-TestAccount([string]$Folder, [int]$Port, [hashtable]$Accounts, [hashtable]$Policies = @{}) {
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive $Folder
        New-Item -ItemType Directory -Path $env:IMAP_CONFIG_DIR -Force | Out-Null
        $file = @{ Accounts = @{}; Policies = $Policies }
        foreach ($entry in $Accounts.GetEnumerator()) {
            $account = @{ Server = '127.0.0.1'; Port = $Port; User = 'tester'; NoTls = $true }
            foreach ($setting in $entry.Value.GetEnumerator()) { $account[$setting.Key] = $setting.Value }
            $file.Accounts[$entry.Key] = $account
            [Environment]::SetEnvironmentVariable("IMAP_PASS_$($entry.Key.ToUpperInvariant())", 'not-a-password')
        }
        Set-Content -Path (Join-Path $env:IMAP_CONFIG_DIR 'accounts.json') -Value ($file | ConvertTo-Json -Depth 5)
        return @($Accounts.Keys | ForEach-Object { "IMAP_PASS_$($_.ToUpperInvariant())" })
    }
}

AfterAll {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
    Remove-Module ElektoImapPosh -ErrorAction SilentlyContinue
}

# Get-WithheldReason on summaries made here, in a Gmail mailbox: the folder a message is read from, its labels, its
# date and size, its sender and the Authentication-Results headers on top of it
Describe 'What a policy withholds' {
    BeforeAll {
        function New-Folder([string]$FullName, [MailKit.FolderAttributes]$Attributes = 'HasNoChildren') {
            [PSCustomObject]@{ FullName = $FullName; Attributes = $Attributes }
        }
        $gmail = @(
            New-Folder 'INBOX' 'HasNoChildren, Inbox'
            New-Folder 'Sent'
            New-Folder 'Finance/Bank'
            New-Folder 'Finance/Cards'
            New-Folder 'Clients'
            New-Folder '[Gmail]/All Mail' 'HasNoChildren, All'
            New-Folder '[Gmail]/Sent Mail' 'HasNoChildren, Sent'
        )
        $pass = 'mx.google.com; dkim=pass header.i=@client.example; spf=pass smtp.mailfrom=client@client.example; dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=client.example'

        # A summary as Get-ImapMessageSummary fetches it; -From may have several addresses, and -AuthenticationResults
        # are the headers from the topmost down
        function New-Summary([string]$From = 'client@client.example', [string[]]$AuthenticationResults = @(), [string[]]$Labels, [long]$Size = 1000, [datetime]$Date = (Get-Date)) {
            $envelope = [MailKit.Envelope]::new()
            if ($From) { $envelope.From.AddRange([MimeKit.InternetAddressList]::Parse($From)) }
            $headers = [MimeKit.HeaderList]::new()
            foreach ($value in $AuthenticationResults) { $headers.Add('Authentication-Results', $value) }
            [PSCustomObject]@{ Envelope = $envelope; Headers = $headers; GMailLabels = $Labels; Size = $Size; InternalDate = [DateTimeOffset]$Date }
        }

        function Get-Reason([hashtable]$Policy, [string]$Folder = 'INBOX', $Summary = (New-Summary -AuthenticationResults $pass)) {
            $rules = if ($Policy) { @{ Name = 'agent' } + $Policy } else { $null }
            InModuleScope ElektoImapPosh -Parameters @{ Policy = $rules; Folders = $gmail; Folder = $Folder; Summary = $Summary } {
                param($Policy, $Folders, $Folder, $Summary)
                $session = @{ Settings = @{ Policy = $Policy }; Folders = $Folders }
                Get-WithheldReason $session ($Folders | Where-Object FullName -EQ $Folder) $Summary
            }
        }
        $trusted = @{ AllowReadFrom = @('*@client.example'); TrustAuthenticationResults = 'mx.google.com' }
    }

    It 'withholds nothing without a policy' {
        Get-Reason $null 'Finance/Bank' | Should -BeNullOrEmpty
    }

    It 'withholds the messages of a denied folder' {
        Get-Reason @{ DenyFolders = @('Finance/*') } 'Finance/Bank' | Should -Be "The folder 'Finance/Bank' is in DenyFolders of the policy 'agent'."
        Get-Reason @{ DenyFolders = @('Finance/*') } 'Clients' | Should -BeNullOrEmpty
    }

    It 'withholds a denied folder named by its special use' {
        Get-Reason @{ DenyFolders = @('Sent') } '[Gmail]/Sent Mail' | Should -Be "The folder '[Gmail]/Sent Mail' is in DenyFolders of the policy 'agent'."
        Get-Reason @{ DenyFolders = @('Sent') } 'Sent' | Should -BeNullOrEmpty -Because 'a label "Sent" of the user is not the sent folder'
    }

    # On Gmail, All Mail (where -Query searches) and the inbox hold the messages of every label
    It 'withholds a message read from another folder when one of its labels is a denied folder (<Label>)' -TestCases @(
        @{ Label = 'Finance/Bank'; Folder = 'Finance/Bank'; Deny = 'Finance/*' }
        @{ Label = 'finance/cards'; Folder = 'Finance/Cards'; Deny = 'Finance/*' }
        @{ Label = '\Inbox'; Folder = 'INBOX'; Deny = 'Inbox' }
        @{ Label = '\Sent'; Folder = '[Gmail]/Sent Mail'; Deny = 'Sent' }
    ) {
        $summary = New-Summary -AuthenticationResults $pass -Labels '\Important', $Label

        Get-Reason @{ DenyFolders = @($Deny) } '[Gmail]/All Mail' $summary | Should -Be "It has the label '$Label', and the folder '$Folder' is in DenyFolders of the policy 'agent'."
    }

    It 'lets through a message whose labels name no denied folder' {
        Get-Reason @{ DenyFolders = @('Finance/*') } '[Gmail]/All Mail' (New-Summary -Labels '\Inbox', 'Clients', 'Sent') | Should -BeNullOrEmpty
    }

    It 'withholds a message received before the days of MaxAgeDays' {
        $start = [datetime]::Today.AddDays(-90).ToString('yyyy-MM-dd')

        Get-Reason @{ MaxAgeDays = 90 } -Summary (New-Summary -Date (Get-Date).AddDays(-91)) | Should -Be "It was received before $start, and MaxAgeDays of the policy 'agent' is 90."
        Get-Reason @{ MaxAgeDays = 90 } -Summary (New-Summary -Date (Get-Date).AddDays(-89)) | Should -BeNullOrEmpty
    }

    It 'withholds a message larger than MaxMessageSize' {
        Get-Reason @{ MaxMessageSize = 1000 } -Summary (New-Summary -Size 1001) | Should -Be "It has 1001 bytes, more than MaxMessageSize of the policy 'agent' (1000)."
        Get-Reason @{ MaxMessageSize = 1000 } -Summary (New-Summary -Size 1000) | Should -BeNullOrEmpty
    }

    It 'withholds a sender of DenyReadFrom, as written and ignoring case, even if AllowReadFrom names it' {
        $summary = New-Summary 'Bank <ALERTS@Bank.Example>' -AuthenticationResults 'mx.google.com; dmarc=pass header.from=bank.example'

        Get-Reason @{ DenyReadFrom = @('*@bank.example') } -Summary $summary | Should -Be "The sender ALERTS@Bank.Example matches '*@bank.example' in DenyReadFrom of the policy 'agent'."
        Get-Reason @{ DenyReadFrom = @('*@bank.example'); AllowReadFrom = @('*@bank.example'); TrustAuthenticationResults = 'mx.google.com' } -Summary $summary |
            Should -BeLike '*in DenyReadFrom*'
        Get-Reason @{ DenyReadFrom = @('*@bank.example') } -Summary (New-Summary 'client@client.example, alerts@bank.example') | Should -BeLike '*alerts@bank.example matches*'
    }

    It 'lets an authenticated sender of AllowReadFrom through' {
        Get-Reason $trusted | Should -BeNullOrEmpty
    }

    It 'withholds every sender when AllowReadFrom has no TrustAuthenticationResults' {
        Get-Reason @{ AllowReadFrom = @('*@client.example') } | Should -Be "AllowReadFrom of the policy 'agent' passes only authenticated senders, and the policy has no TrustAuthenticationResults to authenticate them."
    }

    It 'takes the sender as not authenticated when <Case>' -TestCases @(
        @{ Case = 'there is no Authentication-Results'; From = 'client@client.example'; Results = @() }
        @{ Case = 'the topmost is from another server'; From = 'client@client.example'; Results = @('mx.other.example; dmarc=pass header.from=client.example') }
        @{ Case = 'the topmost has dmarc=fail, and a forged one below has pass'; From = 'client@client.example'; Results = @('mx.google.com; dmarc=fail header.from=client.example', 'mx.google.com; dmarc=pass header.from=client.example') }
        @{ Case = 'DMARC passed for another domain'; From = 'client@client.example'; Results = @('mx.google.com; dmarc=pass header.from=other.example') }
        @{ Case = 'only DKIM and SPF passed'; From = 'client@client.example'; Results = @('mx.google.com; dkim=pass header.i=@client.example; spf=pass smtp.mailfrom=client.example') }
        @{ Case = 'the From has two senders'; From = 'client@client.example, other@client.example'; Results = @('mx.google.com; dmarc=pass header.from=client.example') }
        @{ Case = 'the header cannot be read'; From = 'client@client.example'; Results = @('not ; a = header') }
    ) {
        $summary = New-Summary $From -AuthenticationResults $Results

        Get-Reason $trusted -Summary $summary | Should -Be "The sender is not authenticated by mx.google.com (no DMARC pass for the domain of the From), and AllowReadFrom of the policy 'agent' passes only authenticated senders."
    }

    It 'withholds an authenticated sender that AllowReadFrom does not name' {
        $summary = New-Summary 'friend@other.example' -AuthenticationResults 'mx.google.com; dmarc=pass header.from=other.example'

        Get-Reason $trusted -Summary $summary | Should -Be "The sender friend@other.example is not in AllowReadFrom of the policy 'agent'."
    }

    # The user's own messages have no Authentication-Results
    It 'takes the messages of the sent folder as authenticated, still matching AllowReadFrom' {
        $mine = @{ AllowReadFrom = @('me@gmail.com'); TrustAuthenticationResults = 'mx.google.com' }

        Get-Reason $mine '[Gmail]/Sent Mail' (New-Summary 'Me <me@gmail.com>') | Should -BeNullOrEmpty
        Get-Reason @{ AllowReadFrom = @('me@gmail.com') } '[Gmail]/Sent Mail' (New-Summary 'Me <me@gmail.com>') | Should -BeNullOrEmpty
        Get-Reason $mine '[Gmail]/All Mail' (New-Summary 'Me <me@gmail.com>' -Labels '\Sent') | Should -BeNullOrEmpty
        Get-Reason $mine '[Gmail]/Sent Mail' (New-Summary 'Other <other@gmail.com>') | Should -Be "The sender other@gmail.com is not in AllowReadFrom of the policy 'agent'."
    }

    It 'does not take a label "Sent" of the user as the sent folder' {
        $mine = @{ AllowReadFrom = @('me@gmail.com'); TrustAuthenticationResults = 'mx.google.com' }

        Get-Reason $mine 'Sent' (New-Summary 'Me <me@gmail.com>') | Should -BeLike 'The sender is not authenticated*'
        Get-Reason $mine '[Gmail]/All Mail' (New-Summary 'Me <me@gmail.com>' -Labels 'Sent') | Should -BeLike 'The sender is not authenticated*'
    }

    It 'withholds a message with no sender when AllowReadFrom is given' {
        Get-Reason @{ AllowReadFrom = @('me@gmail.com') } '[Gmail]/Sent Mail' (New-Summary '') | Should -Be "It has no sender, and AllowReadFrom of the policy 'agent' passes only the senders it names."
    }

    It 'refuses to apply a policy before the folders are listed, rather than withhold nothing' {
        {
            InModuleScope ElektoImapPosh {
                Get-WithheldReason @{ Settings = @{ Policy = @{ Name = 'agent'; DenyFolders = @('Inbox') } } } ([PSCustomObject]@{ FullName = 'INBOX' }) $null
            }
        } | Should -Throw '*must be listed*'
    }
}

Describe 'Get-ImapMessage against smtp4dev' -Skip:(-not $smtp4devInstalled) {
    BeforeAll {
        $server = Start-Smtp4dev -LogDirectory (Join-Path $TestDrive 'smtp4dev')
        $pass = 'mx.google.com; dmarc=pass header.from=client.example'
        Send-Smtp4devMessage $server 'Statement' -From 'Bank <alerts@bank.example>' -AuthenticationResults 'mx.google.com; dmarc=pass header.from=bank.example'
        Send-Smtp4devMessage $server 'Proposal' -From 'Client <client@client.example>' -AuthenticationResults $pass
        Send-Smtp4devMessage $server 'Forged' -From 'forger@client.example' -AuthenticationResults 'mx.google.com; dmarc=fail header.from=client.example', $pass
        Send-Smtp4devMessage $server 'Elsewhere' -From 'someone@client.example' -AuthenticationResults 'mx.other.example; dmarc=pass header.from=client.example'
        Send-Smtp4devMessage $server 'Big' -From 'client@client.example' -AuthenticationResults $pass -Padding 20000
        Send-Smtp4devMessage $server 'Hello' -From 'friend@other.example'
        $newestFirst = 'Hello', 'Big', 'Elsewhere', 'Forged', 'Proposal', 'Statement'

        # One message read, for -Unread: marked with MailKit itself, as another mail client would
        $client = [MailKit.Net.Imap.ImapClient]::new()
        try {
            $client.Connect('127.0.0.1', $server.ImapPort, [MailKit.Security.SecureSocketOptions]::None)
            $client.Authenticate('tester', 'not-a-password')
            $null = $client.Inbox.Open([MailKit.FolderAccess]::ReadWrite)
            $uid = $client.Inbox.Search([MailKit.Search.SearchQuery]::SubjectContains('Statement'))[0]
            $seen = [MailKit.StoreFlagsRequest]::new([MailKit.StoreAction]::Add, [MailKit.MessageFlags]::Seen)
            $null = $client.Inbox.Store($uid, [MailKit.IStoreFlagsRequest]$seen)
            $client.Disconnect($true)
        } finally {
            $client.Dispose()
        }

        # "closed" points at a port where nothing listens, and "lost" at a policy that is not there
        $policies = @{
            agent     = @{ AllowReadFrom = @('*@client.example', '*@bank.example'); DenyReadFrom = @('*@bank.example'); TrustAuthenticationResults = 'mx.google.com'; MaxMessageSize = 10000 }
            untrusted = @{ AllowReadFrom = @('*@client.example') }
            inbox     = @{ DenyFolders = @('Inbox') }
            few       = @{ MaxMessages = 3; MaxAgeDays = 30 }
        }
        $passwords = Set-TestAccount 'config' $server.ImapPort -Policies $policies -Accounts @{
            local     = @{}
            closed    = @{ Port = (Get-FreeTcpPort) }
            agent     = @{ Policy = 'agent' }
            untrusted = @{ Policy = 'untrusted' }
            inbox     = @{ Policy = 'inbox' }
            few       = @{ Policy = 'few' }
            lost      = @{ Policy = 'gone' }
        }

        function Get-OpenConnectionCount {
            @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections() |
                Where-Object { $_.RemoteEndPoint.Port -eq $server.ImapPort -and $_.State -eq 'Established' }).Count
        }
    }

    AfterAll {
        Stop-Smtp4dev $server
        foreach ($name in $passwords) { [Environment]::SetEnvironmentVariable($name, $null) }
        $env:IMAP_CONFIG_DIR = $null
    }

    It 'lists the messages of the inbox, the newest first, with their metadata' {
        $result = Get-ImapMessage local

        $result.Subject | Should -Be $newestFirst
        $result.Uid | Should -Be ($result.Uid | Sort-Object -Descending)
        $result[0].PSObject.TypeNames[0] | Should -Be 'ElektoImapPosh.Message'
        $statement = $result[-1]
        $statement.Account | Should -Be 'local'
        $statement.Folder | Should -Be 'INBOX'
        $statement.UidValidity | Should -BeGreaterThan 0
        $statement.Date | Should -BeOfType [datetime]
        ((Get-Date) - $statement.Date).TotalMinutes | Should -BeLessThan 10
        $statement.From | Should -Be 'Bank <alerts@bank.example>'
        $statement.To | Should -Be 'Tester <tester@example.com>'
        $statement.Cc.Count | Should -Be 0
        $statement.Size | Should -BeGreaterThan 100
        $statement.Flags.HasFlag([MailKit.MessageFlags]::Seen) | Should -BeTrue
        $result[0].Flags.HasFlag([MailKit.MessageFlags]::Seen) | Should -BeFalse
        $statement.HasAttachments | Should -BeFalse
        $statement.MessageId | Should -Not -BeNullOrEmpty
        $statement.ThreadId | Should -BeNullOrEmpty
        $statement.Labels | Should -BeNullOrEmpty
        @($result | Where-Object Withheld).Count | Should -Be 0
    }

    It 'returns the -First newest messages' {
        (Get-ImapMessage local -First 2).Subject | Should -Be 'Hello', 'Big'
    }

    It 'searches on the server: <Case>' -TestCases @(
        @{ Case = 'part of the sender, ignoring case'; Parameters = @{ From = 'CLIENT.example' }; Expected = 'Big', 'Elsewhere', 'Forged', 'Proposal' }
        @{ Case = 'part of the subject, ignoring case'; Parameters = @{ Subject = 'propos' }; Expected = @('Proposal') }
        @{ Case = 'sender and subject'; Parameters = @{ From = 'client.example'; Subject = 'big' }; Expected = @('Big') }
        @{ Case = 'received today'; Parameters = @{ Since = (Get-Date) }; Expected = 'Hello', 'Big', 'Elsewhere', 'Forged', 'Proposal', 'Statement' }
        @{ Case = 'received tomorrow'; Parameters = @{ Since = (Get-Date).AddDays(1) }; Expected = @() }
        @{ Case = 'unread'; Parameters = @{ Unread = $true }; Expected = 'Hello', 'Big', 'Elsewhere', 'Forged', 'Proposal' }
    ) {
        @((Get-ImapMessage local @Parameters).Subject) | Should -Be $Expected
    }

    It 'marks nothing as read' {
        $null = Get-ImapMessage local

        (Get-ImapFolder local Inbox).Unread | Should -Be 5
    }

    It 'takes accounts and folders from the pipeline, with one connection and one listing for each account' {
        $output = Get-ImapFolder local | Get-ImapMessage -Verbose 4>&1

        $verbose = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        @($verbose | Where-Object Message -Like 'Connecting to*').Count | Should -Be 1
        @($verbose | Where-Object Message -Like 'Listing the folders*').Count | Should -Be 1
        $messages = @($output | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] })
        $messages.Subject | Should -Be $newestFirst
        $messages.Folder | Sort-Object -Unique | Should -Be 'INBOX'
    }

    It 'reports a folder that does not exist' {
        $result = Get-ImapMessage local -Folder Trash -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'FolderNotFound,*'
    }

    It 'refuses -Query on a server without the Gmail extensions' {
        $result = Get-ImapMessage local -Query 'from:client.example' -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'QueryNotSupported,*'
    }

    It 'reads every account given, reporting the one that fails' {
        $result = Get-ImapMessage -Account closed, local -First 1 -ErrorVariable errors -ErrorAction SilentlyContinue

        $result.Account | Should -Be 'local'
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'ConnectionFailed,*'
    }

    It 'closes its connection when the pipeline stops it early, as Select-Object -First does' {
        $first = Get-ImapMessage local | Select-Object -First 1

        $first.Subject | Should -Be 'Hello'
        Get-OpenConnectionCount | Should -Be 0
    }

    It 'lists every message under a policy, saying why it withholds each' {
        $result = Get-ImapMessage agent
        $withheld = @{}
        foreach ($message in $result) { $withheld[$message.Subject] = $message.Withheld }

        $result.Subject | Should -Be $newestFirst
        $withheld.Proposal | Should -BeNullOrEmpty
        $withheld.Statement | Should -Be "The sender alerts@bank.example matches '*@bank.example' in DenyReadFrom of the policy 'agent'."
        $withheld.Big | Should -BeLike "It has * bytes, more than MaxMessageSize of the policy 'agent' (10000)."
        foreach ($subject in 'Forged', 'Elsewhere', 'Hello') {
            $withheld[$subject] | Should -BeLike 'The sender is not authenticated by mx.google.com*' -Because "the sender of '$subject' is not authenticated"
        }
    }

    It 'withholds every message when AllowReadFrom has no TrustAuthenticationResults' {
        $result = Get-ImapMessage untrusted

        $result.Count | Should -Be 6
        @($result | Where-Object Withheld -Like '*no TrustAuthenticationResults*').Count | Should -Be 6
    }

    It 'lists the messages of a denied folder, withholding them' {
        $result = Get-ImapMessage inbox

        $result.Count | Should -Be 6
        @($result | Where-Object Withheld -EQ "The folder 'INBOX' is in DenyFolders of the policy 'inbox'.").Count | Should -Be 6
    }

    It 'handles no more than MaxMessages in a command, over every folder, saying how many it left out' {
        $inbox = [PSCustomObject]@{ Account = 'few'; Folder = 'INBOX' }
        $result = $inbox, $inbox | Get-ImapMessage -WarningVariable warnings -WarningAction SilentlyContinue

        $result.Subject | Should -Be 'Hello', 'Big', 'Elsewhere'
        $warnings.Count | Should -Be 2
        "$($warnings[0])" | Should -Be "The policy 'few' lets one command handle 3 messages of tester: of those found in 'INBOX', 3 more were left out."
        "$($warnings[1])" | Should -BeLike "*of those found in 'INBOX', 6 more were left out."
    }

    It 'does not warn when -First asks for fewer than MaxMessages' {
        $result = Get-ImapMessage few -First 2 -WarningVariable warnings -WarningAction SilentlyContinue

        $result.Count | Should -Be 2
        $warnings.Count | Should -Be 0
    }

    It 'narrows an earlier -Since to the days of MaxAgeDays, saying so' {
        $start = [datetime]::Today.AddDays(-30).ToString('yyyy-MM-dd')
        $result = Get-ImapMessage few -Since 2020-01-01 -First 1 -WarningVariable warnings -WarningAction SilentlyContinue

        $result.Subject | Should -Be 'Hello'
        "$warnings" | Should -Be "The policy 'few' of tester allows only the last 30 days: messages received before $start were not searched."
    }

    It 'reads nothing from an account whose policy is not there, without connecting' {
        $result = Get-ImapMessage lost -ErrorVariable errors -ErrorAction SilentlyContinue -Verbose 4>&1

        @($result | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }) | Should -BeNullOrEmpty
        @($result | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like 'Connecting to*' }) | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'PolicyNotFound,*'
    }

    It 'uses the IMAP_* environment variables, and IMAP_POLICY, when there is no account' {
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'policies-only'
        New-Item -ItemType Directory -Path $env:IMAP_CONFIG_DIR -Force | Out-Null
        Set-Content -Path (Join-Path $env:IMAP_CONFIG_DIR 'accounts.json') -Value (@{ Policies = @{ inbox = @{ DenyFolders = @('Inbox') } } } | ConvertTo-Json -Depth 5)
        $env:IMAP_SERVER = '127.0.0.1'
        $env:IMAP_PORT = "$($server.ImapPort)"
        $env:IMAP_USER = 'tester'
        $env:IMAP_PASS = 'not-a-password'
        $env:IMAP_NO_TLS = 'true'
        try {
            $result = Get-ImapMessage -First 1
            $result.Account | Should -BeNullOrEmpty
            $result.Withheld | Should -BeNullOrEmpty

            $env:IMAP_POLICY = 'inbox'
            (Get-ImapMessage -First 1).Withheld | Should -BeLike "*DenyFolders of the policy 'inbox'."
        } finally {
            $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config'
            foreach ($name in 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS', 'IMAP_NO_TLS', 'IMAP_POLICY') { [Environment]::SetEnvironmentVariable($name, $null) }
        }
    }
}

# What only Gmail has, against a fake one: All Mail holds every message, and the inbox and each label hold some
Describe 'Get-ImapMessage on Gmail' {
    BeforeAll {
        $now = [DateTimeOffset]::Now
        $server = Start-FakeGmail @(
            @{ Uid = 1; Folders = 'INBOX', '[Gmail]/All Mail', 'Finance/Bank'; Labels = '\Inbox', 'Finance/Bank'; ThreadId = 111; From = 'Bank <alerts@bank.example>'; Subject = 'Statement'; Date = $now.AddHours(-4); Size = 5000; Attachment = 'statement.pdf'; AuthenticationResults = 'mx.google.com; dmarc=pass header.from=bank.example'; Raw = 'has:attachment', 'from:bank.example' }
            @{ Uid = 2; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = '\Inbox', '\Important'; ThreadId = 222; From = 'Client <client@client.example>'; Subject = 'Proposal'; Date = $now.AddHours(-3); Size = 3000; Seen = $true; AuthenticationResults = 'mx.google.com; dmarc=pass header.from=client.example' }
            @{ Uid = 3; Folders = '[Gmail]/All Mail', '[Gmail]/Sent Mail'; Labels = '\Sent'; ThreadId = 222; From = 'Me <me@gmail.com>'; Subject = 'Re: Proposal'; Date = $now.AddHours(-2); Size = 2000; Seen = $true; Raw = 'in:sent proposal' }
            @{ Uid = 4; Folders = '[Gmail]/All Mail', 'Sent'; Labels = @('Sent'); ThreadId = 444; From = 'Me <me@gmail.com>'; Subject = 'Labelled Sent'; Date = $now.AddHours(-1); Size = 1000 }
        )
        $passwords = Set-TestAccount 'gmail' $server.Port -Accounts @{ open = @{}; agent = @{ Policy = 'agent' }; recent = @{ Policy = 'recent' } } -Policies @{
            agent  = @{ DenyFolders = @('Finance/*'); AllowReadFrom = @('*@client.example', 'me@gmail.com'); TrustAuthenticationResults = 'mx.google.com' }
            recent = @{ MaxAgeDays = 30 }
        }

        # The SINCE of the last search the server got, as a date
        function Get-LastSince {
            $search = @($server.State.Commands.ToArray() | Where-Object { $_ -like '* UID SEARCH *' })[-1]
            if ($search -match 'SINCE (\S+)') { [datetime]::ParseExact($Matches[1], 'd-MMM-yyyy', [Globalization.CultureInfo]::InvariantCulture) }
        }
        $denied = "It has the label 'Finance/Bank', and the folder 'Finance/Bank' is in DenyFolders of the policy 'agent'."
    }

    AfterAll {
        Stop-FakeGmail $server
        foreach ($name in $passwords) { [Environment]::SetEnvironmentVariable($name, $null) }
        $env:IMAP_CONFIG_DIR = $null
    }

    It 'searches All Mail with -Query, as Gmail searches' {
        $result = Get-ImapMessage open -Query 'in:sent proposal'

        $result.Subject | Should -Be 'Re: Proposal'
        $result.Folder | Should -Be '[Gmail]/All Mail'
        $commands = $server.State.Commands.ToArray()
        $commands | Where-Object { $_ -like '* EXAMINE "`[Gmail`]/All Mail"' } | Should -Not -BeNullOrEmpty
        $commands | Where-Object { $_ -like '* UID SEARCH *X-GM-RAW "in:sent proposal"*' } | Should -Not -BeNullOrEmpty
    }

    It 'returns the thread and labels of each message, and whether it has attachments' {
        $result = Get-ImapMessage open -Folder All

        $result.Subject | Should -Be 'Labelled Sent', 'Re: Proposal', 'Proposal', 'Statement'
        $result.ThreadId | Should -Be 444, 222, 222, 111
        $result[3].Labels | Should -Be '\Inbox', 'Finance/Bank'
        $result[2].Labels | Should -Be '\Inbox', '\Important'
        $result[0].Labels | Should -Be 'Sent'
        $result.HasAttachments | Should -Be $false, $false, $false, $true
        $result[2].Flags.HasFlag([MailKit.MessageFlags]::Seen) | Should -BeTrue
        @($result | Where-Object Withheld).Count | Should -Be 0
    }

    It 'withholds a message whose label is a denied folder, from whatever folder it is read' {
        (Get-ImapMessage agent -Query 'has:attachment').Withheld | Should -Be $denied
        (Get-ImapMessage agent | Where-Object Subject -EQ 'Statement').Withheld | Should -Be $denied
        (Get-ImapMessage agent -Folder All | Where-Object Subject -EQ 'Statement').Withheld | Should -Be $denied
        (Get-ImapMessage agent -Folder 'Finance/Bank').Withheld | Should -Be "The folder 'Finance/Bank' is in DenyFolders of the policy 'agent'."
    }

    It 'takes a folder from the pipeline by its exact name, so a label "Sent" stays that label' {
        $result = [PSCustomObject]@{ Account = 'agent'; Folder = 'Sent' } | Get-ImapMessage

        $result.Subject | Should -Be 'Labelled Sent'
        $result.Folder | Should -Be 'Sent'
    }

    It 'narrows every search to the days of MaxAgeDays, -Since included' {
        $start = [datetime]::Today.AddDays(-30)

        $null = Get-ImapMessage recent
        Get-LastSince | Should -Be $start
        $null = Get-ImapMessage recent -Since 2020-01-01 -WarningAction SilentlyContinue
        Get-LastSince | Should -Be $start
        $null = Get-ImapMessage recent -Since ([datetime]::Today.AddDays(-2))
        Get-LastSince | Should -Be ([datetime]::Today.AddDays(-2))
        $null = Get-ImapMessage open
        Get-LastSince | Should -BeNullOrEmpty
    }

    It 'takes the messages of the sent folder as the user''s own, but not those of a label "Sent"' {
        (Get-ImapMessage agent -Folder Sent).Subject | Should -Be 'Re: Proposal'
        (Get-ImapMessage agent -Folder Sent).Withheld | Should -BeNullOrEmpty
        $all = Get-ImapMessage agent -Folder All
        ($all | Where-Object Subject -EQ 'Re: Proposal').Withheld | Should -BeNullOrEmpty
        ($all | Where-Object Subject -EQ 'Labelled Sent').Withheld | Should -BeLike 'The sender is not authenticated*'
        ($all | Where-Object Subject -EQ 'Proposal').Withheld | Should -BeNullOrEmpty
    }
}
