# Folders: the special uses that name them in any language, the accounts a command reads from, and
# Get-ImapFolder against smtp4dev, whose IMAP server has an INBOX and a Sent folder it does not mark as such.
# The tests that need smtp4dev are skipped where it is not installed.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Smtp4dev.ps1')
    $smtp4devInstalled = Test-Smtp4devInstalled
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Smtp4dev.ps1')
    . (Join-Path $PSScriptRoot 'FakeGmail.ps1')
    . (Join-Path $PSScriptRoot 'TestAccounts.ps1')
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1') -Force

    $variableNames = 'IMAP_CONFIG_DIR', 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS', 'IMAP_NO_TLS', 'IMAP_PASS_LOCAL', 'IMAP_PASS_CLOSED', 'IMAP_PASS_WRITER'
    $savedEnvironment = @{}
    foreach ($name in $variableNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "env:$name" -ErrorAction Ignore
    }

    # Runs a script in the module with the session of an account, as a command would, and closes it after;
    # the script gets the stand-in for the command's $PSCmdlet, which keeps the errors, and the session
    function Invoke-InSession([string]$Account, [scriptblock]$Script) {
        $cmdlet = [pscustomobject]@{ Errors = [System.Collections.Generic.List[object]]::new() }
        $cmdlet | Add-Member -MemberType ScriptMethod -Name WriteError -Value { param($record) $this.Errors.Add($record) }
        $result = InModuleScope ElektoImapPosh -Parameters @{ Cmdlet = $cmdlet; Account = $Account; Script = "$Script" } {
            param($Cmdlet, $Account, $Script)
            $sessions = @{}
            try {
                $session = Get-ImapSession $Cmdlet $sessions $Account
                # Made again here, so that it runs in the module, where its private functions are
                & ([scriptblock]::Create($Script)) $Cmdlet $session
            } finally {
                Close-ImapSession $sessions
            }
        }
        [pscustomobject]@{ Result = $result; Errors = $cmdlet.Errors }
    }
}

AfterAll {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        Set-Item -LiteralPath "env:$($entry.Key)" -Value $entry.Value
    }
    Remove-Module ElektoImapPosh -ErrorAction SilentlyContinue
}

Describe 'Special uses' {
    BeforeAll {
        # The folders of a Gmail mailbox in Portuguese, as MailKit lists them, and a label "Sent" of the user
        function New-Folder([string]$FullName, [MailKit.FolderAttributes]$Attributes = 'HasNoChildren') {
            [PSCustomObject]@{ FullName = $FullName; Attributes = $Attributes }
        }
        $gmail = @(
            New-Folder 'INBOX' 'HasNoChildren, Inbox'
            New-Folder 'Sent'
            New-Folder 'Work' 'HasChildren'
            New-Folder 'Work/Clients'
            New-Folder '[Gmail]/E-mails enviados' 'HasNoChildren, Sent'
            New-Folder '[Gmail]/Lixeira' 'HasNoChildren, Trash'
            New-Folder '[Gmail]/Todos os e-mails' 'HasNoChildren, All'
        )

        function Select-Folder([string]$Name, $Folders = $gmail, [switch]$Literal) {
            InModuleScope ElektoImapPosh -Parameters @{ Folders = $Folders; Name = $Name; Literal = $Literal } {
                param($Folders, $Name, $Literal)
                (Select-ImapFolder $Folders $Name -Literal:$Literal).FullName
            }
        }
    }

    It 'is <Expected> for <FullName>' -TestCases @(
        @{ FullName = 'INBOX'; Attributes = 'Inbox'; Expected = 'Inbox' }
        @{ FullName = 'Inbox'; Attributes = 'None'; Expected = 'Inbox' }
        @{ FullName = '[Gmail]/E-mails enviados'; Attributes = 'HasNoChildren, Sent'; Expected = 'Sent' }
        @{ FullName = '[Gmail]/Todos os e-mails'; Attributes = 'All'; Expected = 'All' }
        @{ FullName = 'Work'; Attributes = 'HasChildren'; Expected = $null }
    ) {
        $folder = New-Folder $FullName $Attributes
        InModuleScope ElektoImapPosh -Parameters @{ Folder = $folder } { param($Folder) Get-SpecialUse $Folder } | Should -Be $Expected
    }

    It 'finds the folder the server marks with a special use, before one named so' {
        Select-Folder 'Sent' | Should -Be '[Gmail]/E-mails enviados'
        Select-Folder 'trash' | Should -Be '[Gmail]/Lixeira'
    }

    It 'finds a folder by any of the special uses the server marks it with' {
        $marked = @(New-Folder '[Gmail]/Todos os e-mails' 'HasNoChildren, All, Archive'; New-Folder 'Archive')

        Select-Folder 'Archive' $marked | Should -Be '[Gmail]/Todos os e-mails'
        Select-Folder 'All' $marked | Should -Be '[Gmail]/Todos os e-mails'
    }

    It 'finds the folder named as a special use when the server marks none' {
        $plain = $gmail | Where-Object FullName -NotLike '`[Gmail`]*'

        Select-Folder 'Sent' $plain | Should -Be 'Sent'
        Select-Folder 'Trash' $plain | Should -BeNullOrEmpty
    }

    It 'finds a folder by its full name, ignoring case, brackets included' {
        Select-Folder 'work/clients' | Should -Be 'Work/Clients'
        Select-Folder '[Gmail]/Lixeira' | Should -Be '[Gmail]/Lixeira'
    }

    It 'finds the folders that match a wildcard pattern' {
        Select-Folder 'Work*' | Should -Be 'Work', 'Work/Clients'
        Select-Folder '*e-mails*' | Should -Be '[Gmail]/E-mails enviados', '[Gmail]/Todos os e-mails'
        Select-Folder 'Nothing*' | Should -BeNullOrEmpty
    }

    # In Turkish, "I" is not the capital of "i": -like missed "INBOX" for "inbox*" (measured)
    It 'finds the folders that match a pattern alike in the Turkish culture' {
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'tr-TR'
            $inbox = Select-Folder 'inbox*'
            $clients = Select-Folder '*/CLIENTS'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $culture
        }

        $inbox | Should -Be 'INBOX'
        $clients | Should -Be 'Work/Clients'
    }

    # macOS writes names decomposed (NFD): a pattern with a wildcard before an accented letter missed such a folder
    It 'finds a folder whose name comes decomposed by a pattern written composed, and the other way round' {
        $reports = @(New-Folder "Relato`u{301}rios/2026"; New-Folder "Relat`u{F3}rios/2025"; New-Folder 'Relatorios')

        @(Select-Folder "*Relat`u{F3}rios/*" $reports).Count | Should -Be 2
        @(Select-Folder "*Relato`u{301}rios/*" $reports).Count | Should -Be 2
        $found = @(Select-Folder "*Relat`u{F3}rios/2026" $reports)
        $found.Count | Should -Be 1
        [string]::Equals($found[0], "Relato`u{301}rios/2026", [StringComparison]::Ordinal) | Should -BeTrue -Because 'the folder keeps the name the server gives it'
    }

    It 'completes the special uses alike in the Turkish culture' {
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'tr-TR'
            $completed = (TabExpansion2 -inputScript 'Get-ImapFolder -Folder i' -cursorColumn 24).CompletionMatches.CompletionText
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $culture
        }

        $completed | Should -Be 'Inbox', 'Important'
    }

    # Each command registers its parameters with the completer: one left out completes file names
    It 'completes the special uses for -Folder of every command that takes one' {
        $commands = @(Get-Command -Module ElektoImapPosh | Where-Object { $_.Parameters.ContainsKey('Folder') }).Name

        $commands.Count | Should -BeGreaterThan 4
        foreach ($command in $commands) {
            $line = "$command -Folder Se"
            @((TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText) | Should -Be 'Sent' -Because "-Folder of $command should complete"
        }
    }

    # As a name from the pipeline is taken: the full name of a folder the server listed
    It 'takes a name as the exact full name of a folder with -Literal, neither a special use nor a pattern' {
        Select-Folder 'Sent' -Literal | Should -Be 'Sent'
        Select-Folder '[Gmail]/Lixeira' -Literal | Should -Be '[Gmail]/Lixeira'
        Select-Folder 'Work*' -Literal | Should -BeNullOrEmpty
        Select-Folder 'sent' -Literal | Should -BeNullOrEmpty
    }

    # Each message of a pipeline comes with the name of its folder, and a mailbox may have hundreds of labels: the folder
    # is found once for each name. Compared with itself on few folders, so that a slow machine does not fail it. The one
    # search of the name comes before the measure: on a slow runner it took 40 ms of 1000 folders, which made the ratio
    # fail (5.4 on the CI of 9f9418d), while the messages that follow it, what this measures, take no longer.
    It 'finds the folder of messages from the pipeline in a time that does not grow with the number of folders' {
        $milliseconds = InModuleScope ElektoImapPosh {
            foreach ($count in 10, 1000) {
                $folders = @(foreach ($i in 1..$count) { [PSCustomObject]@{ FullName = "Label $i"; Attributes = [MailKit.FolderAttributes]'None' } })
                $session = @{ Settings = @{ User = 'me@gmail.com' }; Folders = $folders }
                $null = Find-ImapFolder $null $session "Label $count" -Literal
                (Measure-Command { foreach ($i in 1..1000) { $null = Find-ImapFolder $null $session "Label $count" -Literal } }).TotalMilliseconds
            }
        }

        $milliseconds[1] | Should -BeLessThan ($milliseconds[0] * 5) -Because "with 1000 folders ($($milliseconds[1]) ms) the search should take about as long as with 10 ($($milliseconds[0]) ms)"
    }

    It 'leaves out the folders that cannot hold messages' {
        InModuleScope ElektoImapPosh {
            Test-SelectableFolder ([PSCustomObject]@{ FullName = '[Gmail]'; Attributes = [MailKit.FolderAttributes]'HasChildren, NoSelect' })
        } | Should -BeFalse
        InModuleScope ElektoImapPosh -Parameters @{ Folder = $gmail[0] } { param($Folder) Test-SelectableFolder $Folder } | Should -BeTrue
    }
}

# What every command that changes the mailbox asks first, whatever it changes: EXAMINE covers only the folder opened
Describe 'The permission to change the mailbox' {
    It 'is <Expected> for <Kind> in <Case>' -TestCases @(
        @{ Case = 'an account that allows no changes'; Kind = 'Flags'; Account = 'work'; AllowWrite = @(); Expected = $false; Hint = "Changes of the kind Flags are not allowed in the mailbox of me@example.com, so*Set-ImapAccount work -AllowWrite Flags." }
        @{ Case = 'the IMAP_* variables without IMAP_ALLOW_WRITE'; Kind = 'Move'; Account = $null; AllowWrite = @(); Expected = $false; Hint = 'IMAP_ALLOW_WRITE=Move.' }
        @{ Case = 'an account that allows other kinds'; Kind = 'Move'; Account = 'work'; AllowWrite = @('Flags', 'Labels'); Expected = $false; Hint = '(it allows Flags, Labels)*Set-ImapAccount work -AllowWrite Flags, Move, Labels.' }
        @{ Case = 'the IMAP_* variables with other kinds'; Kind = 'Labels'; Account = $null; AllowWrite = @('Move'); Expected = $false; Hint = 'IMAP_ALLOW_WRITE=Move,Labels.' }
        @{ Case = 'an account that allows that kind'; Kind = 'Move'; Account = 'work'; AllowWrite = @('Flags', 'Move'); Expected = $true; Hint = $null }
        @{ Case = 'an account that allows all'; Kind = 'Labels'; Account = 'work'; AllowWrite = @('All'); Expected = $true; Hint = $null }
    ) {
        $cmdlet = [pscustomobject]@{ Errors = [System.Collections.Generic.List[object]]::new() }
        $cmdlet | Add-Member -MemberType ScriptMethod -Name WriteError -Value { param($record) $this.Errors.Add($record) }
        $settings = @{ Account = $Account; User = 'me@example.com'; AllowWrite = $AllowWrite }

        $allowed = InModuleScope ElektoImapPosh -Parameters @{ Cmdlet = $cmdlet; Session = @{ Settings = $settings }; Kind = $Kind } {
            param($Cmdlet, $Session, $Kind)
            Test-ImapWriteAllowed $Cmdlet $Session $Kind 'Clients/2026'
        }

        $allowed | Should -Be $Expected
        if ($Expected) {
            $cmdlet.Errors.Count | Should -Be 0
        } else {
            $cmdlet.Errors.Count | Should -Be 1
            $cmdlet.Errors[0].FullyQualifiedErrorId | Should -Be 'WriteNotAllowed'
            "$($cmdlet.Errors[0])" | Should -BeLike "*'Clients/2026' was left as it is*"
            "$($cmdlet.Errors[0])" | Should -BeLike "*$Hint"
        }
    }
}

Describe 'Closing the connections of a command' {
    # '' and the name of the default account share their session
    It 'closes a session kept under two names once' {
        $disposals = InModuleScope ElektoImapPosh {
            $client = [PSCustomObject]@{ IsConnected = $false; Disposals = 0 }
            $client | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposals++ }
            $session = @{ Client = $client }
            Close-ImapSession @{ '' = $session; work = $session }
            $client.Disposals
        }

        $disposals | Should -Be 1
    }

    # The keys are account names, and a key hides a property of the same name
    It 'closes every connection, even with an account named Values (abort: <Abort>)' -TestCases @(
        @{ Abort = $false }
        @{ Abort = $true }
    ) {
        $disposed = InModuleScope ElektoImapPosh -Parameters @{ Abort = $Abort } {
            param($Abort)
            $client = [PSCustomObject]@{ IsConnected = $false; Disposed = $false }
            $client | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
            # "Values" failed to connect, "work" did
            $sessions = @{ Values = $null; work = @{ Client = $client } }
            Close-ImapSession $sessions -Abort:$Abort
            $client.Disposed
        }

        $disposed | Should -BeTrue
    }
}

Describe 'The accounts a command reads from' {
    BeforeAll {
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'names'
        New-Item -ItemType Directory -Path $env:IMAP_CONFIG_DIR -Force | Out-Null
        $accounts = @{ Accounts = [ordered]@{ work = @{ Server = 's'; User = 'u' }; personal = @{ Server = 's'; User = 'u' }; test1 = @{ Server = 's'; User = 'u' }; billing = @{ Server = 's'; User = 'u' } } }
        Set-Content -Path (Join-Path $env:IMAP_CONFIG_DIR 'accounts.json') -Value ($accounts | ConvertTo-Json -Depth 5)

        function Resolve-Name([string[]]$Account) {
            InModuleScope ElektoImapPosh -Parameters @{ Account = $Account } { param($Account) Resolve-ImapAccountName $Account }
        }
    }

    AfterAll {
        $env:IMAP_CONFIG_DIR = $null
    }

    It 'expands wildcards, once each account, ignoring case' {
        Resolve-Name 'w*', 'personal', 'WORK' | Should -Be 'work', 'personal'
        Resolve-Name '*' | Should -Be 'work', 'personal', 'test1', 'billing'
    }

    # In Turkish, "I" is not the capital of "i": -like missed "billing" for "BILL*"
    It 'expands wildcards alike in the Turkish culture' {
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'tr-TR'
            $names = Resolve-Name 'BILL*'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $culture
        }

        $names | Should -Be 'billing'
    }

    It 'gives names without wildcards as they are, even when there is no such account' {
        Resolve-Name 'office' | Should -Be 'office'
    }

    It 'gives nothing for a pattern that matches no account' {
        Resolve-Name 'none*' | Should -BeNullOrEmpty
    }

    It 'stands for the default account, or the IMAP_* variables, without -Account' {
        Resolve-Name | Should -BeExactly ''
    }
}

# The command over a Gmail mailbox that the session and the listing, mocked, serve: a label "Sent" of the user
# beside the sent folder, and the folders in the pipeline from one Get-ImapFolder to another
Describe 'Get-ImapFolder on a Gmail mailbox' {
    BeforeAll {
        function New-Folder([string]$FullName, [MailKit.FolderAttributes]$Attributes, [int]$Count) {
            $folder = [PSCustomObject]@{ FullName = $FullName; Attributes = $Attributes; Count = $Count; Unread = 0 }
            $folder | Add-Member -MemberType ScriptMethod -Name StatusAsync -Value { [System.Threading.Tasks.Task]::CompletedTask }
            $folder
        }
        $mailbox = @(
            New-Folder 'INBOX' 'HasNoChildren, Inbox' 10
            New-Folder 'Sent' 'HasNoChildren' 2
            New-Folder '[Gmail]/E-mails enviados' 'HasNoChildren, Sent' 30
            New-Folder '[Gmail]/Todos os e-mails' 'HasNoChildren, All' 50
        )
        # A client still connected, of a server that gives the counts with the listing, as Gmail does
        $client = [PSCustomObject]@{ IsConnected = $true; IsAuthenticated = $true; Capabilities = [MailKit.Net.Imap.ImapCapabilities]::ListStatus }
        Mock -ModuleName ElektoImapPosh Get-ImapSession { @{ Settings = @{ Account = 'gmail'; User = 'me@gmail.com' }; Client = $client } }
        Mock -ModuleName ElektoImapPosh Get-ImapFolderList { , $mailbox }
        Mock -ModuleName ElektoImapPosh Close-ImapSession { }
    }

    It 'takes -Folder Sent typed as the sent folder' {
        (Get-ImapFolder gmail -Folder Sent).Folder | Should -Be '[Gmail]/E-mails enviados'
    }

    # To a wildcard pattern "[Gmail]" is one of five letters: "[Gmail]/*" listed nothing, and a typo was no error
    It 'takes the brackets of a pattern as written, and reports a bracketed name with a typo' {
        (Get-ImapFolder gmail -Folder '[Gmail]/*').Folder | Should -Be '[Gmail]/E-mails enviados', '[Gmail]/Todos os e-mails'
        (Get-ImapFolder gmail -Folder '[Gmail]/Todos*').Folder | Should -Be '[Gmail]/Todos os e-mails'
        (Get-ImapFolder gmail -Folder '`[Gmail`]/*').Folder | Should -Be '[Gmail]/E-mails enviados', '[Gmail]/Todos os e-mails' -Because 'the brackets escaped, the way around it before, still work'

        $result = Get-ImapFolder gmail -Folder '[Gmail]/Lixeiraa' -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'FolderNotFound,*'
    }

    It 'takes a folder from the pipeline by its exact name, so a label "Sent" stays that label' {
        $result = [PSCustomObject]@{ Account = 'gmail'; Folder = 'Sent' } | Get-ImapFolder

        $result.Folder | Should -Be 'Sent'
        $result.Count | Should -Be 2
    }

    It 'gives the same folders when piped to itself' {
        (Get-ImapFolder gmail | Get-ImapFolder).Folder | Should -Be $mailbox.FullName
    }

    It 'reports a folder from the pipeline that is no longer there' {
        $result = [PSCustomObject]@{ Account = 'gmail'; Folder = 'Old label' } | Get-ImapFolder -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'FolderNotFound,*'
    }
}

# The counts of the folders: from a server with LIST-STATUS, in the listing; from one without it, asked of each folder
# shown. MailKit asked them of "[Gmail]" too, which Gmail lists \Noselect to a plain LIST and which refuses them, and
# the whole listing failed.
Describe 'The counts of the folders, on Gmail' {
    BeforeAll {
        $now = [DateTimeOffset]::Now
        $messages = @(
            @{ Uid = 1; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'New'; Date = $now.AddHours(-2); Size = 1000 }
            @{ Uid = 2; Folders = 'INBOX', '[Gmail]/All Mail', 'Finance'; Labels = '\Inbox', 'Finance'; From = 'Bank <alerts@bank.example>'; Subject = 'Read'; Date = $now.AddHours(-1); Size = 1000; Seen = $true }
        )
        $plain = Start-FakeGmail $messages
        $listStatus = Start-FakeGmail $messages -Capabilities 'IMAP4rev1 X-GM-EXT-1 SPECIAL-USE CHILDREN LIST-STATUS'
        $passwords = Set-TestAccount 'counts' $plain.Port -SavedEnvironment $savedEnvironment -Accounts @{ plain = @{}; liststatus = @{ Port = $listStatus.Port } }
        $selectable = 'INBOX', '[Gmail]/All Mail', '[Gmail]/Sent Mail', '[Gmail]/Trash', '[Gmail]/Important', 'Finance', 'Finance/Bank', 'Sent'

        # The STATUS commands a server got, apart from a LIST
        function Get-StatusCommand($Server) { @($Server.State.Commands.ToArray() | Where-Object { $_ -cmatch '^\S+ STATUS ' }) }
    }

    AfterAll {
        Stop-FakeGmail $plain
        Stop-FakeGmail $listStatus
        foreach ($name in $passwords) { Remove-Item -LiteralPath "env:$name" -ErrorAction Ignore }
        $env:IMAP_CONFIG_DIR = $null
    }

    AfterEach {
        $plain.State.DropOn = $plain.State.RefuseOn = $null
        $plain.State.Commands.Clear()
    }

    It 'takes them from the listing of a server with LIST-STATUS, in one command' {
        $result = Get-ImapFolder liststatus -ErrorVariable errors

        $result.Folder | Should -Be $selectable
        ($result | Where-Object Folder -EQ 'INBOX').Count | Should -Be 2
        ($result | Where-Object Folder -EQ 'INBOX').Unread | Should -Be 1
        ($result | Where-Object Folder -EQ 'Finance').Count | Should -Be 1
        $errors | Should -BeNullOrEmpty
        @($listStatus.State.Commands.ToArray() | Where-Object { $_ -clike '* LIST *RETURN (STATUS (*' }) | Should -Not -BeNullOrEmpty
        Get-StatusCommand $listStatus | Should -BeNullOrEmpty
    }

    It 'asks them of each folder shown, from a server without LIST-STATUS, and never of a folder that holds no messages' {
        $result = Get-ImapFolder plain -ErrorVariable errors

        $result.Folder | Should -Be $selectable
        ($result | Where-Object Folder -EQ 'INBOX').Count | Should -Be 2
        ($result | Where-Object Folder -EQ 'INBOX').Unread | Should -Be 1
        ($result | Where-Object Folder -EQ 'Finance').Count | Should -Be 1
        $errors | Should -BeNullOrEmpty
        $statuses = Get-StatusCommand $plain
        $statuses.Count | Should -Be $selectable.Count
        $statuses | Where-Object { $_ -clike '* STATUS "`[Gmail`]" *' } | Should -BeNullOrEmpty
    }

    It 'reports a folder that does not give them, and shows the others' {
        $plain.State.RefuseOn = '^\S+ STATUS "?Finance"? \('

        $result = Get-ImapFolder plain -ErrorVariable errors -ErrorAction SilentlyContinue

        $result.Folder | Should -Be ($selectable | Where-Object { $_ -ne 'Finance' })
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -Be 'FolderStatusFailed,Get-ImapFolder'
    }

    # Once, and not once for each folder left
    It 'reports a connection lost while it asks them, once' {
        $plain.State.DropOn = '^\S+ STATUS "?Finance"? \('

        $result = Get-ImapFolder plain -ErrorVariable errors -ErrorAction SilentlyContinue

        $result.Folder | Should -Be ($selectable | Select-Object -First 5)
        @($errors.FullyQualifiedErrorId) | Should -Be 'FolderStatusFailed,Get-ImapFolder', 'ConnectionLost,Get-ImapFolder'
    }
}

Describe 'Folders against smtp4dev' -Skip:(-not $smtp4devInstalled) {
    BeforeAll {
        $server = Start-Smtp4dev -LogDirectory (Join-Path $TestDrive 'smtp4dev') -ArgumentList '--authenticationrequired', '--user=tester=not-a-password'
        $login = [Net.NetworkCredential]::new('tester', 'not-a-password')
        Send-Smtp4devMessage $server 'First' $login
        Send-Smtp4devMessage $server 'Second' $login

        # "closed" points at a port where nothing listens
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config'
        New-Item -ItemType Directory -Path $env:IMAP_CONFIG_DIR -Force | Out-Null
        $accounts = @{
            Accounts = @{
                local  = @{ Server = '127.0.0.1'; Port = $server.ImapPort; User = 'tester'; NoTls = $true }
                closed = @{ Server = '127.0.0.1'; Port = (Get-FreeTcpPort); User = 'tester'; NoTls = $true }
                writer = @{ Server = '127.0.0.1'; Port = $server.ImapPort; User = 'tester'; NoTls = $true; AllowWrite = @('Flags') }
            }
        }
        Set-Content -Path (Join-Path $env:IMAP_CONFIG_DIR 'accounts.json') -Value ($accounts | ConvertTo-Json -Depth 5)
        $env:IMAP_PASS_LOCAL = 'not-a-password'
        $env:IMAP_PASS_CLOSED = 'not-a-password'
        $env:IMAP_PASS_WRITER = 'not-a-password'

        # The connections open to the IMAP server of smtp4dev, on the side of the client
        function Get-OpenConnectionCount {
            @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections() |
                Where-Object { $_.RemoteEndPoint.Port -eq $server.ImapPort -and $_.State -eq 'Established' }).Count
        }
    }

    AfterAll {
        Stop-Smtp4dev $server
        $env:IMAP_CONFIG_DIR = $null
    }

    It 'lists the folders of an account, with their counts' {
        $result = Get-ImapFolder local

        $result.Folder | Should -Be 'INBOX', 'Sent'
        $result[0].PSObject.TypeNames[0] | Should -Be 'ElektoImapPosh.Folder'
        $result[0].Account | Should -Be 'local'
        $result[0].SpecialUse | Should -Be 'Inbox'
        $result[0].Count | Should -Be 2
        $result[0].Unread | Should -Be 2
        $result[1].SpecialUse | Should -BeNullOrEmpty
        $result[1].Count | Should -Be 0
    }

    It 'shows only the folders named by -Folder, each once' {
        $result = Get-ImapFolder local -Folder Inbox, sent, 'In*', INBOX

        $result.Folder | Should -Be 'INBOX', 'Sent'
        $result[0].Count | Should -Be 2
    }

    It 'reports a folder that does not exist, but not a pattern that matches none' {
        $result = Get-ImapFolder local -Folder Trash, 'X*' -ErrorVariable errors -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'FolderNotFound,*'
    }

    It 'reads every account a pattern matches, reporting the one that fails' {
        $result = Get-ImapFolder -Account * -Folder Inbox -ErrorVariable errors -ErrorAction SilentlyContinue

        @($result).Account | Sort-Object | Should -Be 'local', 'writer'
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'ConnectionFailed,*'
    }

    It 'takes accounts and folders from the pipeline, with one connection and one listing for each account' {
        $output = Get-ImapFolder local | Get-ImapFolder -Verbose 4>&1

        $verbose = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        @($verbose | Where-Object Message -Like 'Connecting to*').Count | Should -Be 1
        @($verbose | Where-Object Message -Like 'Listing the folders*').Count | Should -Be 1
        ($output | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }).Folder | Should -Be 'INBOX', 'Sent'
    }

    # The end block, which logs out, does not run then (nor after Ctrl+C): the clean block closes the connection.
    # Checked at once, without waiting: a client left open would soon be closed by the garbage collector.
    It 'closes its connection when the pipeline stops it early, as Select-Object -First does' {
        $first = Get-ImapFolder local | Select-Object -First 1

        $first.Folder | Should -Be 'INBOX'
        Get-OpenConnectionCount | Should -Be 0
    }

    # Read-only by EXAMINE, which the server enforces for the messages of the folder: reading never changes them
    It 'opens a folder read-only, and a message read stays unread' {
        $run = Invoke-InSession local {
            param($Cmdlet, $Session)
            $inbox = $Session.Client.Inbox
            $opened = Open-ImapFolder $Cmdlet $Session $inbox
            @{ Opened = $opened; Access = "$($inbox.Access)"; Failure = Wait-ImapTask ($inbox.GetMessageAsync(0, [System.Threading.CancellationToken]::None, $null)) }
        }

        $run.Result.Opened | Should -BeTrue
        $run.Result.Access | Should -Be 'ReadOnly'
        $run.Result.Failure | Should -BeNullOrEmpty
        (Get-ImapFolder local Inbox).Unread | Should -Be 2
    }

    It 'refuses to open a folder for writing in an account that does not allow changes' {
        $run = Invoke-InSession local {
            param($Cmdlet, $Session)
            @{ Opened = Open-ImapFolder $Cmdlet $Session $Session.Client.Inbox -ForWrite Flags; IsOpen = $Session.Client.Inbox.IsOpen }
        }

        $run.Result.Opened | Should -BeFalse
        $run.Result.IsOpen | Should -BeFalse
        $run.Errors.Count | Should -Be 1
        $run.Errors[0].FullyQualifiedErrorId | Should -Be 'WriteNotAllowed'
        "$($run.Errors[0])" | Should -BeLike '*Set-ImapAccount local -AllowWrite Flags.'
    }

    It 'refuses to open a folder for a change of a kind the account does not allow' {
        $run = Invoke-InSession writer {
            param($Cmdlet, $Session)
            @{ Opened = Open-ImapFolder $Cmdlet $Session $Session.Client.Inbox -ForWrite Move; IsOpen = $Session.Client.Inbox.IsOpen }
        }

        $run.Result.Opened | Should -BeFalse
        $run.Result.IsOpen | Should -BeFalse
        $run.Errors[0].FullyQualifiedErrorId | Should -Be 'WriteNotAllowed'
        "$($run.Errors[0])" | Should -BeLike '*(it allows Flags)*Set-ImapAccount writer -AllowWrite Flags, Move.'
    }

    It 'opens a folder for writing in an account that allows that kind of change' {
        $run = Invoke-InSession writer {
            param($Cmdlet, $Session)
            @{ Opened = Open-ImapFolder $Cmdlet $Session $Session.Client.Inbox -ForWrite Flags; Access = "$($Session.Client.Inbox.Access)" }
        }

        $run.Result.Opened | Should -BeTrue
        $run.Result.Access | Should -Be 'ReadWrite'
        $run.Errors.Count | Should -Be 0
    }

    # Even in an account that allows changes, a folder opened to be read cannot be changed
    It 'cannot mark a message as read in a folder opened read-only' {
        $run = Invoke-InSession writer {
            param($Cmdlet, $Session)
            $inbox = $Session.Client.Inbox
            $null = Open-ImapFolder $Cmdlet $Session $inbox
            $seen = [MailKit.StoreFlagsRequest]::new([MailKit.StoreAction]::Add, [MailKit.MessageFlags]::Seen)
            Wait-ImapTask ($inbox.StoreAsync([int]0, [MailKit.IStoreFlagsRequest]$seen, [System.Threading.CancellationToken]::None))
        }

        $run.Result | Should -BeLike '*not currently open in read-write mode*'
        (Get-ImapFolder local Inbox).Unread | Should -Be 2
    }

    It 'uses the IMAP_* environment variables when there is no account' {
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'no-accounts'
        $env:IMAP_SERVER = '127.0.0.1'
        $env:IMAP_PORT = "$($server.ImapPort)"
        $env:IMAP_USER = 'tester'
        $env:IMAP_PASS = 'not-a-password'
        $env:IMAP_NO_TLS = 'true'
        try {
            $result = Get-ImapFolder -Folder Inbox

            $result.Account | Should -BeNullOrEmpty
            $result.Count | Should -Be 2
        } finally {
            $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config'
            foreach ($name in 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS', 'IMAP_NO_TLS') { Remove-Item -LiteralPath "env:$name" -ErrorAction Ignore }
        }
    }
}

# So the tests above would see a message marked as read, one is, with a server of its own: smtp4dev adds
# flags, but ignores taking them away, so the message stays read
Describe 'Marking as read against smtp4dev' -Skip:(-not $smtp4devInstalled) {
    BeforeAll {
        $server = Start-Smtp4dev -LogDirectory (Join-Path $TestDrive 'smtp4dev-seen')
        Send-Smtp4devMessage $server 'To be read'
        $env:IMAP_CONFIG_DIR = Join-Path $TestDrive 'config-seen'
        New-Item -ItemType Directory -Path $env:IMAP_CONFIG_DIR -Force | Out-Null
        $accounts = @{ Accounts = @{ writer = @{ Server = '127.0.0.1'; Port = $server.ImapPort; User = 'tester'; NoTls = $true; AllowWrite = $true } } }
        Set-Content -Path (Join-Path $env:IMAP_CONFIG_DIR 'accounts.json') -Value ($accounts | ConvertTo-Json -Depth 5)
        $env:IMAP_PASS_WRITER = 'not-a-password'
    }

    AfterAll {
        Stop-Smtp4dev $server
        $env:IMAP_CONFIG_DIR = $null
    }

    It 'can mark a message as read in a folder opened for writing, and the count shows it' {
        (Get-ImapFolder writer Inbox).Unread | Should -Be 1

        $run = Invoke-InSession writer {
            param($Cmdlet, $Session)
            $inbox = $Session.Client.Inbox
            $null = Open-ImapFolder $Cmdlet $Session $inbox -ForWrite Flags
            $seen = [MailKit.StoreFlagsRequest]::new([MailKit.StoreAction]::Add, [MailKit.MessageFlags]::Seen)
            Wait-ImapTask ($inbox.StoreAsync([int]0, [MailKit.IStoreFlagsRequest]$seen, [System.Threading.CancellationToken]::None))
        }

        $run.Result | Should -BeNullOrEmpty
        (Get-ImapFolder writer Inbox).Unread | Should -Be 0
    }
}
