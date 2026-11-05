# Attachments and inline parts: the name a file gets, the size told before the fetch, and Save-ImapAttachment against the fake Gmail,
# since the BODYSTRUCTURE of smtp4dev leaves attachments out. The fake serves each part on its own, and keeps the
# commands it got, so the tests see what was fetched.

BeforeAll {
    . (Join-Path $PSScriptRoot 'FakeGmail.ps1')
    . (Join-Path $PSScriptRoot 'TestAccounts.ps1')
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1') -Force

    $variableNames = 'IMAP_CONFIG_DIR', 'IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS', 'IMAP_NO_TLS', 'IMAP_POLICY'
    $savedEnvironment = @{}
    foreach ($name in $variableNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
}

AfterAll {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
    Remove-Module ElektoImapPosh -ErrorAction SilentlyContinue
}

Describe 'The file of an attachment' {
    BeforeAll {
        function Get-FileName([string]$Name, [string]$ContentType) {
            InModuleScope ElektoImapPosh -Parameters @{ Name = $Name; ContentType = $ContentType } { param($Name, $ContentType) Get-AttachmentFileName $Name $ContentType }
        }
    }

    It 'is named <Expected> for <Case>' -TestCases @(
        @{ Case = 'a plain name'; Name = 'report.pdf'; Expected = 'report.pdf' }
        @{ Case = 'a path up the tree'; Name = '../../escaped.txt'; Expected = 'escaped.txt' }
        @{ Case = 'a Windows path'; Name = 'C:\Windows\System32\x.dll'; Expected = 'x.dll' }
        @{ Case = 'characters Windows refuses'; Name = 'a<b>c:d"e|f?g*.txt'; Expected = 'a_b_c_d_e_f_g_.txt' }
        @{ Case = 'dots and spaces at the end'; Name = 'invoice.exe. . '; Expected = 'invoice.exe' }
        @{ Case = 'a device name of Windows'; Name = 'CON.txt'; Expected = '_CON.txt' }
        @{ Case = 'another device name, in lower case'; Name = 'com1'; Expected = '_com1' }
        @{ Case = 'a name that only starts like a device'; Name = 'CONTRACT.pdf'; Expected = 'CONTRACT.pdf' }
        @{ Case = 'a character that reverses the text'; Name = "photo`u{202E}gpj.exe"; Expected = 'photo_gpj.exe' }
        @{ Case = 'a control character'; Name = "a`tb.txt"; Expected = 'a_b.txt' }
        @{ Case = 'no name, and a type'; Name = ''; ContentType = 'image/png'; Expected = 'attachment.png' }
        @{ Case = 'no name, and a type without an extension'; Name = ''; ContentType = 'application/x-unknown'; Expected = 'attachment' }
        @{ Case = 'no name, and no type'; Name = ''; Expected = 'attachment' }
        @{ Case = 'a name that is only dots'; Name = '..'; Expected = 'attachment' }
        @{ Case = 'a name that ends in a slash'; Name = 'folder/'; Expected = 'attachment' }
        @{ Case = 'a device name with a superscript digit'; Name = "COM`u{B9}.txt"; Expected = "_COM`u{B9}.txt" }
        @{ Case = 'another device name with a superscript digit'; Name = "lpt`u{B2}"; Expected = "_lpt`u{B2}" }
    ) {
        Get-FileName $Name $ContentType | Should -BeExactly $Expected
    }

    It 'numbers a name that comes again in the same message, keeping its extension' {
        InModuleScope ElektoImapPosh {
            $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($name in 'image.png', 'IMAGE.png', 'image.png', 'notes', 'notes', 'image (2).png') { Get-UniqueFileName $name $used }
        } | Should -Be 'image.png', 'IMAGE (2).png', 'image (3).png', 'notes', 'notes (2)', 'image (2) (2).png'
    }

    It 'cuts a long name to 200 bytes of UTF-8, keeping its extension, and not in the middle of a character' {
        Get-FileName (('x' * 300) + '.pdf') | Should -BeExactly (('x' * 196) + '.pdf')
        # Two bytes each, so 98 of them and the extension make 200 bytes
        Get-FileName (("`u{E9}" * 196) + '.pdf') | Should -BeExactly (("`u{E9}" * 98) + '.pdf')
        # The emoji after the 195th character would take four bytes more than room is left: it goes whole
        Get-FileName (('x' * 195) + "`u{1F600}" + ('y' * 100) + '.pdf') | Should -BeExactly (('x' * 195) + '.pdf')
    }

    # Cut after ".exe.", the name would end in a dot that Windows drops: "*.exe" must see the name Windows writes
    It 'trims the dots and spaces that a cut leaves at the end' {
        Get-FileName (('x' * 195) + '.exe.' + ('z' * 30)) | Should -BeExactly (('x' * 195) + '.exe')
    }

    It 'takes base64 as 3 bytes for 4 characters, and other encodings as they are, before the fetch' {
        InModuleScope ElektoImapPosh {
            Get-AttachmentSize ([PSCustomObject]@{ ContentTransferEncoding = 'BASE64'; Octets = 1000 })
            Get-AttachmentSize ([PSCustomObject]@{ ContentTransferEncoding = 'base64'; Octets = 1001 })
            Get-AttachmentSize ([PSCustomObject]@{ ContentTransferEncoding = '7BIT'; Octets = 1000 })
        } | Should -Be 750, 751, 1000
    }

    It 'writes a file decoded, and a message attached as it is' {
        $written = InModuleScope ElektoImapPosh {
            $file = [MimeKit.MimePart]::new('application', 'pdf')
            $file.Content = [MimeKit.MimeContent]::new([IO.MemoryStream]::new([Text.Encoding]::ASCII.GetBytes('%PDF-1.4')))
            $file.ContentTransferEncoding = 'Base64'
            $inner = [MimeKit.MimeMessage]::new()
            $inner.Subject = 'Forwarded'
            $inner.Body = [MimeKit.TextPart]::new('plain')
            $inner.Body.Text = 'The forwarded text.'
            $attached = [MimeKit.MessagePart]::new('rfc822')
            $attached.Message = $inner
            foreach ($entity in $file, $attached) {
                $stream = [IO.MemoryStream]::new()
                Write-AttachmentContent $entity $stream
                [Text.Encoding]::UTF8.GetString($stream.ToArray())
            }
        }

        $written[0] | Should -BeExactly '%PDF-1.4'
        $written[1] | Should -BeLike '*Subject: Forwarded*The forwarded text.*'
    }
}

Describe 'Save-ImapAttachment on Gmail' {
    BeforeAll {
        $now = [DateTimeOffset]::Now
        $client = 'mx.google.com; dmarc=pass header.from=client.example'
        $server = Start-FakeGmail @(
            @{ Uid = 10; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Report'; Date = $now.AddHours(-6); Size = 5000; AuthenticationResults = $client
                Attachments = @(@{ Name = 'report.pdf'; Type = 'application/pdf'; Data = '%PDF-1.4 report' }, @{ Name = 'photo.jpg'; Type = 'image/jpeg'; Data = 'JPEG photo' })
            }
            @{ Uid = 11; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Odd names'; Date = $now.AddHours(-5); Size = 5000; AuthenticationResults = $client
                Attachments = @(
                    @{ Name = '../../escaped.txt'; Type = 'text/plain'; Data = 'escaped' }
                    @{ Name = 'CON.txt'; Type = 'text/plain'; Data = 'device' }
                    @{ Name = 'invoice.exe.'; Type = 'application/pdf'; Data = 'MZ program' }
                    @{ Name = 'a<b>c?.txt'; Type = 'text/plain'; Data = 'odd' }
                    @{ Name = ''; Type = 'application/octet-stream'; Data = 'nameless' }
                )
            }
            @{ Uid = 12; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'stranger@other.example'; Subject = 'Unknown sender'; Date = $now.AddHours(-4); Size = 3000
                Attachments = @(@{ Name = 'notes.txt'; Type = 'text/plain'; Data = 'notes' })
            }
            @{ Uid = 13; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Big'; Date = $now.AddHours(-3); Size = 9000; AuthenticationResults = $client
                Attachments = @(@{ Name = 'big.pdf'; Type = 'application/pdf'; Data = '%PDF big'; Octets = 30000000 })
            }
            @{ Uid = 14; Folders = 'INBOX', '[Gmail]/All Mail', 'Finance/Bank'; Labels = '\Inbox', 'Finance/Bank'; From = 'Bank <alerts@bank.example>'; Subject = 'Statement'; Date = $now.AddHours(-2); Size = 3000; AuthenticationResults = 'mx.google.com; dmarc=pass header.from=bank.example'
                Attachments = @(@{ Name = 'statement.pdf'; Type = 'application/pdf'; Data = '%PDF statement' })
            }
            @{ Uid = 15; Folders = '[Gmail]/All Mail', '[Gmail]/Sent Mail'; Labels = @('\Sent'); From = 'Me <me@gmail.com>'; Subject = 'Mine'; Date = $now.AddHours(-1); Size = 3000
                Attachments = @(@{ Name = 'mine.pdf'; Type = 'application/pdf'; Data = '%PDF mine' })
            }
            # Prints pasted in Gmail, all named image.png, beside a file attached
            @{ Uid = 16; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Prints'; Date = $now.AddMinutes(-50); Size = 9000; AuthenticationResults = $client
                Attachments = @(
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG first'; Disposition = 'inline'; ContentId = 'ii_1' }
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG second'; Disposition = 'inline'; ContentId = 'ii_2' }
                    @{ Name = 'spec.pdf'; Type = 'application/pdf'; Data = '%PDF spec' }
                )
            }
            # A camera that sends its photo with no name and no disposition, only a Content-ID
            @{ Uid = 17; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'nvr@home.example'; Subject = 'Gate'; Date = $now.AddMinutes(-40); Size = 9000
                Attachments = @(@{ Name = ''; Type = 'image/jpeg'; Data = 'JPEG gate'; Disposition = 'none'; ContentId = 'snapshot' })
            }
            @{ Uid = 18; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Twice'; Date = $now.AddMinutes(-30); Size = 9000; AuthenticationResults = $client
                Attachments = @(@{ Name = 'report.pdf'; Type = 'application/pdf'; Data = '%PDF one' }, @{ Name = 'report.pdf'; Type = 'application/pdf'; Data = '%PDF two' })
            }
            # As Gmail forwards the photo of an NVR (JP's, 2026-11-05): the same file shown in the body and attached
            @{ Uid = 19; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Me <me@gmail.com>'; Subject = 'Fwd: NVR AI: Object Found'; Date = $now.AddMinutes(-20); Size = 9000
                Attachments = @(
                    @{ Name = 'snapshot0.jpg'; Type = 'image/jpeg'; Data = 'JPEG snapshot'; Disposition = 'inline'; ContentId = 'ii_1' }
                    @{ Name = 'snapshot0.jpg'; Type = 'image/jpeg'; Data = 'JPEG snapshot'; ContentId = 'aa30@gmail.com' }
                )
            }
            # A print of the same name as an attachment, but another file
            @{ Uid = 20; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Same name'; Date = $now.AddMinutes(-10); Size = 9000; AuthenticationResults = $client
                Attachments = @(
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG pasted in the body'; Disposition = 'inline'; ContentId = 'ii_2' }
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG attached' }
                )
            }
            # Another file of the same name and size, the case a match by name and size would take for a copy
            @{ Uid = 21; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Same size'; Date = $now.AddMinutes(-8); Size = 9000; AuthenticationResults = $client
                Attachments = @(
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG one'; Disposition = 'inline'; ContentId = 'ii_3' }
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG two' }
                )
            }
            # The logo of a signature, twice, as Outlook repeats it in a thread
            @{ Uid = 22; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Logos'; Date = $now.AddMinutes(-6); Size = 9000; AuthenticationResults = $client
                Attachments = @(
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG logo'; Disposition = 'inline'; ContentId = 'logo-1' }
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG logo'; Disposition = 'inline'; ContentId = 'logo-2' }
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG print'; Disposition = 'inline'; ContentId = 'print' }
                )
            }
        )
        $passwords = Set-TestAccount 'gmail-attachments' $server.Port -SavedEnvironment $savedEnvironment -Accounts @{ open = @{}; strict = @{ Policy = 'strict' }; one = @{ Policy = 'one' }; pdf = @{ Policy = 'pdf' }; prefixed = @{ Policy = 'prefixed' } } -Policies @{
            strict = @{
                DenyFolders                = @('Finance/*')
                AllowAttachmentsFrom       = @('*@client.example', 'me@gmail.com')
                DenyAttachmentTypes        = @('*.exe')
                AllowAttachmentTypes       = @('application/pdf', 'image/*', '*.txt')
                MaxAttachmentSize          = 10485760
                TrustAuthenticationResults = 'mx.google.com'
            }
            one    = @{ MaxMessages = 1 }
            pdf    = @{ AllowAttachmentTypes = @('*.pdf') }
            prefixed = @{ DenyAttachmentTypes = @('16-image*', 'spec.pdf') }
        }

        # A new directory of the test drive for each test, and the commands the server got since the test began
        function New-TestDirectory([string]$Name) { (New-Item -ItemType Directory -Path (Join-Path $TestDrive $Name) -Force).FullName }
        function Get-CommandSince([int]$Count) { @($server.State.Commands.ToArray() | Select-Object -Skip $Count) }
    }

    AfterAll {
        Stop-FakeGmail $server
        foreach ($name in $passwords) { [Environment]::SetEnvironmentVariable($name, $null) }
        $env:IMAP_CONFIG_DIR = $null
    }

    It 'saves the attachments of a message, decoded, fetching them and nothing else, and returns the files' {
        $directory = New-TestDirectory 'saved'
        $before = $server.State.Commands.Count
        $files = Save-ImapAttachment open -Folder All -Uid 10 -Path $directory

        $files.Name | Should -Be 'report.pdf', 'photo.jpg'
        $files[0] | Should -BeOfType [IO.FileInfo]
        [IO.File]::ReadAllText($files[0].FullName) | Should -BeExactly '%PDF-1.4 report'
        [IO.File]::ReadAllText($files[1].FullName) | Should -BeExactly 'JPEG photo'
        $files[0].Account | Should -Be 'open'
        $files[0].Folder | Should -Be '[Gmail]/All Mail'
        $files[0].Uid | Should -Be 10
        $files[0].Attachment | Should -Be 'report.pdf'
        $fetches = @(Get-CommandSince $before | Where-Object { $_ -like '* UID FETCH *BODY.PEEK`[[0-9]*' })
        $fetches.Count | Should -Be 2
        $fetches[0] | Should -BeLike '*BODY.PEEK`[2`]*'
        $fetches[1] | Should -BeLike '*BODY.PEEK`[3`]*'
        Get-CommandSince $before | Where-Object { $_ -like '*BODY.PEEK`[1*' -or $_ -like '*BODY.PEEK`[`]*' } | Should -BeNullOrEmpty -Because 'the text of the message is not fetched'
        @(Get-ChildItem -LiteralPath $directory -Force).Name | Sort-Object | Should -Be 'photo.jpg', 'report.pdf' -Because 'no temporary file is left'
    }

    It 'saves only the attachments named by -Name, by pattern or by name, as the message gives it or as the file gets it' {
        (Save-ImapAttachment open -Folder All -Uid 10 -Path (New-TestDirectory 'by-pattern') -Name *.pdf).Name | Should -Be 'report.pdf'
        (Save-ImapAttachment open -Folder All -Uid 10 -Path (New-TestDirectory 'by-name') -Name photo.jpg).Name | Should -Be 'photo.jpg'
        (Save-ImapAttachment open -Folder All -Uid 11 -Path (New-TestDirectory 'by-file-name') -Name _CON.txt).Name | Should -Be '_CON.txt'
    }

    It 'replaces a file that exists only with -Force' {
        $directory = New-TestDirectory 'replace'
        $existing = Join-Path $directory 'report.pdf'
        Set-Content -LiteralPath $existing -Value 'kept' -NoNewline

        $result = Save-ImapAttachment open -Folder All -Uid 10 -Path $directory -Name report.pdf -ErrorVariable errors -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AttachmentFileExists,*'
        Get-Content -LiteralPath $existing -Raw | Should -BeExactly 'kept'

        $null = Save-ImapAttachment open -Folder All -Uid 10 -Path $directory -Name report.pdf -Force
        Get-Content -LiteralPath $existing -Raw | Should -BeExactly '%PDF-1.4 report'
    }

    It 'saves under names that stay in the directory and that Windows takes' {
        $directory = New-TestDirectory 'odd/inner'
        $files = Save-ImapAttachment open -Folder All -Uid 11 -Path $directory

        $files.Name | Should -Be 'escaped.txt', '_CON.txt', 'invoice.exe', 'a_b_c_.txt', 'attachment.bin'
        $files.DirectoryName | Sort-Object -Unique | Should -Be $directory
        Test-Path -LiteralPath (Join-Path $TestDrive 'escaped.txt') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $directory 'invoice.exe')) | Should -BeExactly 'MZ program'
    }

    It 'saves nothing, and fetches no attachment, with -WhatIf' {
        $directory = New-TestDirectory 'what-if'
        $before = $server.State.Commands.Count
        $result = Save-ImapAttachment open -Folder All -Uid 10 -Path $directory -WhatIf

        $result | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $directory -Force).Count | Should -Be 0
        Get-CommandSince $before | Where-Object { $_ -like '*BODY.PEEK`[2*' -or $_ -like '*BODY.PEEK`[3*' } | Should -BeNullOrEmpty
    }

    It 'refuses a directory that does not exist' {
        { Save-ImapAttachment open -Folder All -Uid 10 -Path (Join-Path $TestDrive 'missing') } | Should -Throw 'There is no directory*'
    }

    It 'saves the attachments the policy lets be saved, by type and by the name of the file, and refuses the others, saying why' {
        $directory = New-TestDirectory 'strict'
        $files = Save-ImapAttachment strict -Folder All -Uid 10, 11 -Path $directory -ErrorVariable errors -ErrorAction SilentlyContinue

        $files.Name | Should -Be 'report.pdf', 'photo.jpg', 'escaped.txt', '_CON.txt', 'a_b_c_.txt'
        $errors.Count | Should -Be 2
        $errors.FullyQualifiedErrorId | ForEach-Object { $_ | Should -BeLike 'AttachmentWithheld,*' }
        "$($errors[0])" | Should -Be "The attachment 'invoice.exe.' of the message 11 in the folder '[Gmail]/All Mail' of tester was not saved: The attachment invoice.exe (application/pdf) matches '*.exe' in DenyAttachmentTypes of the policy 'strict'."
        # The type in lower case, though the server gave it in upper case, as Gmail does, for a part without parameters
        "$($errors[1])" | Should -BeLikeExactly "*was not saved: The attachment attachment.bin (application/octet-stream) matches nothing in AllowAttachmentTypes of the policy 'strict'."
        Test-Path -LiteralPath (Join-Path $directory 'invoice.exe') | Should -BeFalse
    }

    It 'refuses the attachments of a sender that is not authenticated, and of one too large, before fetching them' {
        $before = $server.State.Commands.Count
        $files = Save-ImapAttachment strict -Folder All -Uid 12, 13 -Path (New-TestDirectory 'refused') -ErrorVariable errors -ErrorAction SilentlyContinue

        $files | Should -BeNullOrEmpty
        $errors.Count | Should -Be 2
        "$($errors[0])" | Should -BeLike "*was not saved: The sender is not authenticated by mx.google.com*AllowAttachmentsFrom of the policy 'strict' passes only authenticated senders."
        "$($errors[1])" | Should -BeLike "*was not saved: The attachment big.pdf has up to 22500000 bytes, more than MaxAttachmentSize of the policy 'strict' (10485760)."
        Get-CommandSince $before | Where-Object { $_ -like '*BODY.PEEK`[2*' } | Should -BeNullOrEmpty
    }

    It 'refuses the attachments of a message the policy withholds, fetching none' {
        $before = $server.State.Commands.Count
        $files = Save-ImapAttachment strict -Folder Inbox -Uid 14 -Path (New-TestDirectory 'withheld') -ErrorVariable errors -ErrorAction SilentlyContinue

        $files | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'MessageWithheld,*'
        "$($errors[0])" | Should -Be "The attachments of the message 14 in the folder 'INBOX' of tester were not saved: It has the label 'Finance/Bank', and the folder 'Finance/Bank' is in DenyFolders of the policy 'strict'."
        Get-CommandSince $before | Where-Object { $_ -like '*BODY.PEEK`[2*' } | Should -BeNullOrEmpty
    }

    It 'saves the attachments of the user''s own messages, which have no Authentication-Results' {
        (Save-ImapAttachment strict -Folder Sent -Uid 15 -Path (New-TestDirectory 'own')).Name | Should -Be 'mine.pdf'
    }

    It 'handles no more messages than MaxMessages, saying how many it left out' {
        $files = Save-ImapAttachment one -Folder All -Uid 10, 15 -Path (New-TestDirectory 'one') -WarningVariable warnings -WarningAction SilentlyContinue

        $files.Uid | Sort-Object -Unique | Should -Be 10
        "$warnings" | Should -Be "The policy 'one' lets one command handle 1 message of tester: 1 more was left out, and their attachments not saved."
    }

    It 'takes the messages listed by Get-ImapMessage' {
        $listed = Get-ImapMessage open -Folder Sent
        $files = $listed | Save-ImapAttachment -Path (New-TestDirectory 'piped')

        $files.Name | Should -Be 'mine.pdf'
        $files.Folder | Should -Be '[Gmail]/Sent Mail'
    }

    It 'says in Read-ImapMessage which attachments the policy withholds, and the names of their files' {
        $attachments = (Read-ImapMessage strict -Folder All -Uid 11).Attachments

        $attachments.Count | Should -Be 5
        $attachments[0..3].Name | Should -Be '../../escaped.txt', 'CON.txt', 'invoice.exe.', 'a<b>c?.txt'
        $attachments[4].Name | Should -BeNullOrEmpty
        $attachments.FileName | Should -Be 'escaped.txt', '_CON.txt', 'invoice.exe', 'a_b_c_.txt', 'attachment.bin'
        @($attachments | Where-Object Withheld).FileName | Should -Be 'invoice.exe', 'attachment.bin'
        ($attachments | Where-Object FileName -EQ 'invoice.exe').Withheld | Should -BeLike "*matches '`*.exe' in DenyAttachmentTypes*"
    }

    It 'saves the parts shown in the body only with -Inline, numbering the names they repeat' {
        $without = Save-ImapAttachment open -Folder All -Uid 16 -Path (New-TestDirectory 'not-inline')
        $files = Save-ImapAttachment open -Folder All -Uid 16 -Path (New-TestDirectory 'inline') -Inline

        $without.Name | Should -Be 'spec.pdf'
        $files.Name | Should -Be 'spec.pdf', 'image.png', 'image (2).png'
        [IO.File]::ReadAllText($files[1].FullName) | Should -BeExactly 'PNG first'
        [IO.File]::ReadAllText($files[2].FullName) | Should -BeExactly 'PNG second'
        $files.Inline | Should -Be $false, $true, $true
        $files[2].Attachment | Should -Be 'image.png'
    }

    It 'saves once a file that a message both shows and attaches, as Gmail forwards carry it, also when run again' {
        $directory = New-TestDirectory 'forwarded'
        $output = Save-ImapAttachment open -Folder All -Uid 19 -Path $directory -Inline -ContentType image/* -Verbose 4>&1
        $again = Save-ImapAttachment open -Folder All -Uid 19 -Path $directory -Inline -ContentType image/* -ErrorVariable errors -ErrorAction SilentlyContinue
        $read = Read-ImapMessage open -Folder All -Uid 19

        $files = @($output | Where-Object { $_ -is [IO.FileInfo] })
        $files.Name | Should -Be 'snapshot0.jpg'
        $files.Inline | Should -BeFalse
        @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like "*is the same file as one saved before*" }).Count | Should -Be 1
        $again | Should -BeNullOrEmpty
        $errors.FullyQualifiedErrorId | Should -BeLike 'AttachmentFileExists,*'
        @(Get-ChildItem -LiteralPath $directory).Name | Should -Be 'snapshot0.jpg'
        # Listed both, since only their content tells them apart
        $read.Attachments.FileName | Should -Be 'snapshot0.jpg'
        $read.InlineParts.FileName | Should -Be 'snapshot0 (2).jpg'
    }

    It 'saves two files of the same name and size, and a logo repeated once' {
        $sameSize = Save-ImapAttachment open -Folder All -Uid 21 -Path (New-TestDirectory 'same-size') -Inline
        $logos = Save-ImapAttachment open -Folder All -Uid 22 -Path (New-TestDirectory 'logos') -Inline

        $sameSize.Name | Should -Be 'image.png', 'image (2).png'
        [IO.File]::ReadAllText($sameSize[0].FullName) | Should -BeExactly 'PNG two'
        [IO.File]::ReadAllText($sameSize[1].FullName) | Should -BeExactly 'PNG one'
        $logos.Name | Should -Be 'image.png', 'image (3).png'
        [IO.File]::ReadAllText($logos[1].FullName) | Should -BeExactly 'PNG print'
    }

    It 'holds the name written by -UniqueName, and the file''s own, to the policy' {
        $plain = Save-ImapAttachment prefixed -Folder All -Uid 16 -Path (New-TestDirectory 'prefixed-plain') -Inline -ErrorVariable plainErrors -ErrorAction SilentlyContinue
        $unique = Save-ImapAttachment prefixed -Folder All -Uid 16 -Path (New-TestDirectory 'prefixed-unique') -Inline -UniqueName -ErrorVariable uniqueErrors -ErrorAction SilentlyContinue

        $plain.Name | Should -Be 'image.png', 'image (2).png'
        "$($plainErrors[0])" | Should -BeLike "*'spec.pdf'*matches 'spec.pdf' in DenyAttachmentTypes*"
        $unique | Should -BeNullOrEmpty
        $uniqueErrors.Count | Should -Be 3
        "$($uniqueErrors[1])" | Should -BeLike "*The attachment 16-image.png (image/png) matches '16-image``*' in DenyAttachmentTypes*"
    }

    It 'gives an attachment its own name, and numbers an inline part of the same name that is another file' {
        $without = Save-ImapAttachment open -Folder All -Uid 20 -Path (New-TestDirectory 'same-name')
        $files = Save-ImapAttachment open -Folder All -Uid 20 -Path (New-TestDirectory 'same-name-inline') -Inline

        $without.Name | Should -Be 'image.png'
        [IO.File]::ReadAllText($without[0].FullName) | Should -BeExactly 'PNG attached'
        $files.Name | Should -Be 'image.png', 'image (2).png'
        [IO.File]::ReadAllText($files[1].FullName) | Should -BeExactly 'PNG pasted in the body'
    }

    It 'saves only the parts of the types of -ContentType' {
        (Save-ImapAttachment open -Folder All -Uid 16 -Path (New-TestDirectory 'images') -Inline -ContentType image/*).Name | Should -Be 'image.png', 'image (2).png'
        (Save-ImapAttachment open -Folder All -Uid 10 -Path (New-TestDirectory 'jpeg') -ContentType image/jpeg).Name | Should -Be 'photo.jpg'
    }

    It 'saves a photo with no name and no disposition, named by its type' {
        $files = Save-ImapAttachment open -Folder All -Uid 17 -Path (New-TestDirectory 'camera') -Inline -ContentType image/*

        $files.Name | Should -Be 'attachment.jpg'
        [IO.File]::ReadAllText($files[0].FullName) | Should -BeExactly 'JPEG gate'
    }

    It 'numbers the attachments of the same name in a message' {
        $files = Save-ImapAttachment open -Folder All -Uid 18 -Path (New-TestDirectory 'twice')

        $files.Name | Should -Be 'report.pdf', 'report (2).pdf'
        [IO.File]::ReadAllText($files[1].FullName) | Should -BeExactly '%PDF two'
    }

    It 'puts the UID of the message before the name of each file with -UniqueName' {
        $files = Save-ImapAttachment open -Folder All -Uid 16, 17 -Path (New-TestDirectory 'unique') -Inline -ContentType image/* -UniqueName

        $files.Name | Should -Be '16-image.png', '16-image (2).png', '17-attachment.jpg'
    }

    It 'holds the parts shown in the body to the rules of the policy on attachments' {
        $files = Save-ImapAttachment pdf -Folder All -Uid 16 -Path (New-TestDirectory 'pdf-only') -Inline -ErrorVariable errors -ErrorAction SilentlyContinue

        $files.Name | Should -Be 'spec.pdf'
        $errors.Count | Should -Be 2
        "$($errors[0])" | Should -Be "The inline part 'image.png' of the message 16 in the folder '[Gmail]/All Mail' of tester was not saved: The attachment image.png (image/png) matches nothing in AllowAttachmentTypes of the policy 'pdf'."
    }

    It 'lists in Read-ImapMessage the parts shown in the body apart from the attachments' {
        $result = Read-ImapMessage open -Folder All -Uid 16

        $result.Attachments.FileName | Should -Be 'spec.pdf'
        $result.InlineParts.FileName | Should -Be 'image.png', 'image (2).png'
        $result.InlineParts.ContentType | Should -Be 'image/png', 'image/png'
        $camera = (Read-ImapMessage open -Folder All -Uid 17).InlineParts
        $camera.FileName | Should -Be 'attachment.jpg'
        $camera.ContentType | Should -BeExactly 'image/jpeg'
    }
}
