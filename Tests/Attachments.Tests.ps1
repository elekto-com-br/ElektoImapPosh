# Attachments and inline parts: the name a file gets, the size told before the fetch, and Save-ImapAttachment against the fake Gmail,
# since the BODYSTRUCTURE of smtp4dev leaves attachments out. The fake serves each part on its own, and keeps the
# commands it got, so the tests see what was fetched.

BeforeDiscovery {
    # Root writes in a directory whatever its permissions
    $isRoot = -not $IsWindows -and (id -u) -eq '0'
}

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
        @{ Case = 'a device name followed by spaces, which Windows 10 reads as the device'; Name = 'NUL .txt'; Expected = '_NUL .txt' }
        @{ Case = 'the console of Windows'; Name = 'conin$'; Expected = '_conin$' }
        @{ Case = 'the console of Windows, with an extension'; Name = 'CONOUT$.log'; Expected = '_CONOUT$.log' }
        @{ Case = 'a device name with a digit of another script'; Name = "COM`u{663}.txt"; Expected = "_COM`u{663}.txt" }
        @{ Case = 'a name written decomposed, as macOS writes names'; Name = "relato`u{301}rio.pdf"; Expected = "relat`u{F3}rio.pdf" }
        @{ Case = 'a lone surrogate'; Name = 'x' + [char]0xD800 + 'y.pdf'; Expected = 'x_y.pdf' }
        @{ Case = 'a control character of the C1 set (CSI)'; Name = "a`u{9B}b.txt"; Expected = 'a_b.txt' }
        @{ Case = 'the Arabic letter mark, which also turns the text'; Name = "a`u{61C}b.txt"; Expected = 'a_b.txt' }
        @{ Case = 'the short name Windows gives a long one'; Name = 'REPORT~1.PDF'; Expected = 'REPORT_1.PDF' }
        @{ Case = 'another short name, without an extension'; Name = 'progr~12'; Expected = 'progr_12' }
        @{ Case = 'a tilde in a name no short name has'; Name = 'report~1.docx'; Expected = 'report~1.docx' }
        @{ Case = 'the lock file of an Office document'; Name = '~$budget.xlsx'; Expected = '~$budget.xlsx' }
    ) {
        $fileName = Get-FileName $Name $ContentType
        # -ceq takes a name and its decomposed form for equal: compared character for character
        [string]::Equals($fileName, $Expected, [StringComparison]::Ordinal) | Should -BeTrue -Because "'$fileName' should be '$Expected'"
    }

    # In Turkish, "I" is not the capital of "i": a device name in small letters is a device name all the same
    It 'tells a device name alike in the Turkish culture' {
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'tr-TR'
            $fileName = Get-FileName 'conin$'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $culture
        }

        $fileName | Should -BeExactly '_conin$'
    }

    It 'numbers a name that comes again in the same message, keeping its extension' {
        InModuleScope ElektoImapPosh {
            $used = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($name in 'image.png', 'IMAGE.png', 'image.png', 'notes', 'notes', 'image (2).png', '.env', '.env') { Get-UniqueFileName $name $used }
        } | Should -Be 'image.png', 'IMAGE (2).png', 'image (3).png', 'notes', 'notes (2)', 'image (2) (2).png', '.env', '.env (2)'
    }

    # macOS writes names decomposed (NFD), and takes a name and its decomposed form for one file: with -Force, the
    # second would replace the first
    It 'numbers a name written decomposed as the same name written composed' {
        $names = InModuleScope ElektoImapPosh {
            $used = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($name in "relat`u{F3}rio.pdf", "relato`u{301}rio.pdf") { Get-UniqueFileName (Get-AttachmentFileName $name 'application/pdf') $used }
        }

        [string]::Equals($names[1], "relat`u{F3}rio (2).pdf", [StringComparison]::Ordinal) | Should -BeTrue -Because "'$($names[1])' should be numbered"
    }

    # A sender writes the names: repeated thousands of times, or thousands of characters long, they must not take the
    # square of that. Compared with itself on the same work in smaller pieces, so that a slow machine does not fail it.
    It 'numbers a name repeated many times in a time that grows with the number of copies only' {
        $milliseconds = InModuleScope ElektoImapPosh {
            foreach ($run in @{ Copies = 100; Times = 20 }, @{ Copies = 2000; Times = 1 }) {
                (Measure-Command {
                        foreach ($time in 1..$run.Times) {
                            $used = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
                            foreach ($copy in 1..$run.Copies) { $null = Get-UniqueFileName 'image.png' $used }
                        }
                    }).TotalMilliseconds
            }
        }

        $milliseconds[1] | Should -BeLessThan ($milliseconds[0] * 5) -Because "2000 copies once ($($milliseconds[1]) ms) should take about as long as 100 copies 20 times ($($milliseconds[0]) ms)"
    }

    It 'cuts a long name in a time that grows with its length only' {
        $milliseconds = InModuleScope ElektoImapPosh {
            foreach ($run in @{ Length = 1000; Times = 50 }, @{ Length = 50000; Times = 1 }) {
                $name = ('x' * $run.Length) + '.pdf'
                (Measure-Command { foreach ($time in 1..$run.Times) { $null = Get-AttachmentFileName $name 'application/pdf' } }).TotalMilliseconds
            }
        }

        $milliseconds[1] | Should -BeLessThan ($milliseconds[0] * 5) -Because "a name of 50000 characters once ($($milliseconds[1]) ms) should take about as long as one of 1000 characters 50 times ($($milliseconds[0]) ms)"
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
        $messages = @(
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
            # A file whose name starts with a dot, hidden on Linux
            @{ Uid = 23; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Dot file'; Date = $now.AddMinutes(-4); Size = 9000; AuthenticationResults = $client
                Attachments = @(@{ Name = '.env.local'; Type = 'text/plain'; Data = 'KEY=value' })
            }
            # The logo of a signature, twice, as Outlook repeats it in a thread
            @{ Uid = 22; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Logos'; Date = $now.AddMinutes(-6); Size = 9000; AuthenticationResults = $client
                Attachments = @(
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG logo'; Disposition = 'inline'; ContentId = 'logo-1' }
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG logo'; Disposition = 'inline'; ContentId = 'logo-2' }
                    @{ Name = 'image.png'; Type = 'image/png'; Data = 'PNG print'; Disposition = 'inline'; ContentId = 'print' }
                )
            }
            # The same name written composed and decomposed (NFD, as macOS writes names), two files
            @{ Uid = 24; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Accents'; Date = $now.AddMinutes(-3); Size = 9000; AuthenticationResults = $client
                Attachments = @(@{ Name = "relat`u{F3}rio.pdf"; Type = 'application/pdf'; Data = '%PDF composed' }, @{ Name = "relato`u{301}rio.pdf"; Type = 'application/pdf'; Data = '%PDF decomposed' })
            }
            # A message attached as mail carries it, in 7bit with its CRLF, and a part of that type that is no message
            @{ Uid = 25; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Forwarded as an attachment'; Date = $now.AddMinutes(-2); Size = 9000; AuthenticationResults = $client
                Attachments = @(
                    @{ Name = 'original.eml'; Type = 'message/rfc822'; Encoding = '7bit'; Data = "From: Someone <someone@client.example>`r`nSubject: Original`r`n`r`nThe original text.`r`n" }
                    @{ Name = 'mislabeled.eml'; Type = 'message/rfc822'; Encoding = '7bit'; Data = "%PDF-1.4`r`n%%EOF" }
                )
            }
            # Names Windows reads its own way: a short name (8.3), which may stand for another file
            @{ Uid = 26; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Short name'; Date = $now.AddMinutes(-1); Size = 9000; AuthenticationResults = $client
                Attachments = @(@{ Name = 'REPORT~1.PDF'; Type = 'application/pdf'; Data = '%PDF short' })
            }
            # An attachment the structure of the message tells smaller than it is
            @{ Uid = 27; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Understated'; Date = $now.AddSeconds(-50); Size = 9000; AuthenticationResults = $client
                Attachments = @(@{ Name = 'small.pdf'; Type = 'application/pdf'; Data = '%PDF ' + ('x' * 2000); Octets = 100 })
            }
            # A name in capitals, for patterns in small letters under the Turkish culture
            @{ Uid = 28; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Invoice'; Date = $now.AddSeconds(-40); Size = 9000; AuthenticationResults = $client
                Attachments = @(@{ Name = 'INVOICE.ZIP'; Type = 'application/zip'; Data = 'PK invoice' })
            }
            # A name with an escape sequence, which clears the screen of a terminal that shows it
            @{ Uid = 29; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Escape'; Date = $now.AddSeconds(-30); Size = 9000; AuthenticationResults = $client
                Attachments = @(@{ Name = "report`e[2J.exe"; Type = 'application/octet-stream'; Data = 'MZ program' })
            }
            # A message whose whole body is the message it forwards, attached: its part is the root, with no number
            @{ Uid = 30; Folders = 'INBOX', '[Gmail]/All Mail'; Labels = @('\Inbox'); From = 'Client <client@client.example>'; Subject = 'Only a message'; Date = $now.AddSeconds(-20); Size = 9000; AuthenticationResults = $client
                Whole = @{ Name = 'forwarded.eml'; Type = 'message/rfc822'; Encoding = '7bit'; Data = "From: Someone <someone@client.example>`r`nSubject: Inside`r`n`r`nThe text inside.`r`n" }
            }
        )
        $server = Start-FakeGmail $messages
        # Another server, where the account "elsewhere" finds the same user, folder, UIDVALIDITY and UID 10
        $elsewhere = Start-FakeGmail @($messages | Where-Object { $_.Uid -eq 10 })
        $passwords = Set-TestAccount 'gmail-attachments' $server.Port -SavedEnvironment $savedEnvironment -Accounts @{ open = @{}; strict = @{ Policy = 'strict' }; one = @{ Policy = 'one' }; pdf = @{ Policy = 'pdf' }; prefixed = @{ Policy = 'prefixed' }; exact = @{ Policy = 'exact' }; named = @{ Policy = 'named' }; accents = @{ Policy = 'accents' }; small = @{ Policy = 'small' }; zip = @{ Policy = 'zip' }; elsewhere = @{ Port = $elsewhere.Port; Policy = 'pdf' } } -Policies @{
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
            exact    = @{ DenyAttachmentTypes = @('report.pdf') }
            named    = @{ AllowAttachmentTypes = @('report.pdf') }
            # A pattern written decomposed, with a wildcard before it: -like would not match the composed name
            accents  = @{ DenyAttachmentTypes = @("*relato`u{301}rio*") }
            small    = @{ MaxAttachmentSize = 1000 }
            zip      = @{ DenyAttachmentTypes = @('*.zip') }
        }

        # A new directory of the test drive for each test, and the commands the server got since the test began
        function New-TestDirectory([string]$Name) { (New-Item -ItemType Directory -Path (Join-Path $TestDrive $Name) -Force).FullName }
        function Get-CommandSince([int]$Count) { @($server.State.Commands.ToArray() | Select-Object -Skip $Count) }

        # The write of the module held until the gate opens: all of it, or with after only the end of its task, the file
        # written and renamed already; started gives the task the command waits for, once it is held. In C#, since the
        # task runs on threads where a script block has no runspace
        if (-not ('ElektoImapPoshTests.HeldSave' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading.Tasks;

namespace ElektoImapPoshTests
{
    public static class HeldSave
    {
        // Wraps the write of the module: (content, temporary, path, overwrite, commit) => task
        public static Func<MemoryStream, string, string, bool, TaskCompletionSource<bool>, Task> Hold(
            Func<MemoryStream, string, string, bool, TaskCompletionSource<bool>, Task> save, Task gate, TaskCompletionSource<Task> started, bool after)
        {
            return (content, temporary, path, overwrite, commit) =>
            {
                if (!after)
                {
                    Task held = gate.ContinueWith(_ => save(content, temporary, path, overwrite, commit)).Unwrap();
                    started.TrySetResult(held);
                    return held;
                }
                Task saved = save(content, temporary, path, overwrite, commit);
                Task end = saved.ContinueWith(_ => gate).Unwrap();
                saved.ContinueWith(_ => started.TrySetResult(end));
                return end;
            };
        }
    }
}
'@
        }

        # Save-ImapAttachment in a runspace of its own, which Ctrl+C stops (BeginStop), saving report.pdf of the message 10
        # with -Force, its write held until Gate opens (HeldSave)
        function Start-HeldSave([string]$Directory, [switch]$After) {
            $held = [pscustomobject]@{
                PowerShell = [powershell]::Create()
                Gate       = [System.Threading.Tasks.TaskCompletionSource[object]]::new()
                Started    = [System.Threading.Tasks.TaskCompletionSource[System.Threading.Tasks.Task]]::new()
            }
            $null = $held.PowerShell.AddScript({
                    param($Manifest, $Gate, $Started, $After, $Directory)
                    Import-Module $Manifest
                    & (Get-Module ElektoImapPosh) { param($Gate, $Started, $After) $script:SaveFileTask = [ElektoImapPoshTests.HeldSave]::Hold($script:SaveFileTask, $Gate, $Started, $After) } $Gate $Started $After
                    Save-ImapAttachment open -Folder All -Uid 10 -Path $Directory -Name report.pdf -Force
                }).AddArgument((Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1')).AddArgument($held.Gate.Task).AddArgument($held.Started).AddArgument([bool]$After).AddArgument($Directory)
            $null = $held.PowerShell.BeginInvoke()
            return $held
        }
    }

    AfterAll {
        Stop-FakeGmail $server
        Stop-FakeGmail $elsewhere
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

    It 'refuses a directory in the place of a file, -Force or not, before fetching the attachment' {
        $directory = New-TestDirectory 'directory-in-place'
        $null = New-Item -ItemType Directory -Path (Join-Path $directory 'report.pdf')
        $before = $server.State.Commands.Count
        $files = Save-ImapAttachment open -Folder All -Uid 10 -Path $directory -Name report.pdf -Force -ErrorVariable errors -ErrorAction SilentlyContinue

        $files | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AttachmentFileExists,*'
        "$($errors[0])" | Should -BeLike "'*report.pdf' is a directory, so the part 'report.pdf' of the message 10 in the folder * was not saved."
        Get-CommandSince $before | Where-Object { $_ -like '*BODY.PEEK`[2*' } | Should -BeNullOrEmpty
    }

    # A file another program keeps open, on Windows, or a directory that cannot be written, elsewhere
    It 'reports a file it could not write once, and does not return the file that was there' -Skip:$isRoot {
        $directory = New-TestDirectory 'cannot-write'
        $existing = Join-Path $directory 'report.pdf'
        Set-Content -LiteralPath $existing -Value 'kept' -NoNewline
        $lock = $null
        if ($IsWindows) { $lock = [IO.File]::Open($existing, 'Open', 'Read', 'None') }
        else { [IO.File]::SetUnixFileMode($directory, 'UserRead, UserExecute') }
        try {
            $files = Save-ImapAttachment open -Folder All -Uid 10 -Path $directory -Name report.pdf -Force -ErrorVariable errors -ErrorAction SilentlyContinue
        } finally {
            if ($lock) { $lock.Dispose() } else { [IO.File]::SetUnixFileMode($directory, 'UserRead, UserWrite, UserExecute') }
        }

        $files | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AttachmentWriteFailed,*'
        "$($errors[0])" | Should -BeLike "Could not write '*report.pdf', so the part 'report.pdf' of the message 10 in the folder * was not saved: ?*"
        Get-Content -LiteralPath $existing -Raw | Should -BeExactly 'kept'
        @(Get-ChildItem -LiteralPath $directory -Force).Name | Should -Be 'report.pdf' -Because 'no temporary file is left'
    }

    # Message 19 carries the same file attached and shown in the body. Where the attachment's file is open in another
    # program, on Windows, the copy shown is saved under its own name; where the directory cannot be written, it is
    # reported too. Neither is skipped as a file saved before
    It 'counts as saved only the files it wrote, so a copy of one it could not write is saved, or reported' -Skip:$isRoot {
        $directory = New-TestDirectory 'copy-of-unwritten'
        $existing = Join-Path $directory 'snapshot0.jpg'
        Set-Content -LiteralPath $existing -Value 'kept' -NoNewline
        $lock = $null
        if ($IsWindows) { $lock = [IO.File]::Open($existing, 'Open', 'Read', 'None') }
        else { [IO.File]::SetUnixFileMode($directory, 'UserRead, UserExecute') }
        try {
            $files = Save-ImapAttachment open -Folder All -Uid 19 -Path $directory -Inline -Force -ErrorVariable errors -ErrorAction SilentlyContinue
        } finally {
            if ($lock) { $lock.Dispose() } else { [IO.File]::SetUnixFileMode($directory, 'UserRead, UserWrite, UserExecute') }
        }

        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AttachmentWriteFailed,*'
        "$($errors[0])" | Should -BeLike "Could not write '*snapshot0.jpg', so the part 'snapshot0.jpg' *"
        if ($IsWindows) {
            $errors.Count | Should -Be 1
            $files.Name | Should -Be 'snapshot0 (2).jpg'
            [IO.File]::ReadAllText($files[0].FullName) | Should -BeExactly 'JPEG snapshot'
        } else {
            $files | Should -BeNullOrEmpty
            $errors.Count | Should -Be 2
            "$($errors[1])" | Should -BeLike "Could not write '*snapshot0 (2).jpg', *"
        }
        Get-Content -LiteralPath $existing -Raw | Should -BeExactly 'kept'
    }

    # A file another program keeps open with no sharing, on Windows, or one its owner cannot read, elsewhere
    It 'refuses a file that exists with one error, also when it cannot read the file' -Skip:$isRoot {
        $directory = New-TestDirectory 'cannot-read'
        $existing = Join-Path $directory 'report.pdf'
        Set-Content -LiteralPath $existing -Value 'kept' -NoNewline
        $lock = $null
        if ($IsWindows) { $lock = [IO.File]::Open($existing, 'Open', 'Read', 'None') }
        else { [IO.File]::SetUnixFileMode($existing, 'None') }
        try {
            $files = Save-ImapAttachment open -Folder All -Uid 10 -Path $directory -Name report.pdf -ErrorVariable errors -ErrorAction SilentlyContinue
        } finally {
            if ($lock) { $lock.Dispose() } else { [IO.File]::SetUnixFileMode($existing, 'UserRead, UserWrite') }
        }

        $files | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AttachmentFileExists,*'
        Get-Content -LiteralPath $existing -Raw | Should -BeExactly 'kept'
    }

    # Ctrl+C stops the wait for the task that writes a file, not the task, which went on and replaced the file there
    # after the command had ended (Copilot on #13). The write is held until the command is stopped, as a slow disk holds it
    It 'stops at once on Ctrl+C while writing a file, without saving it later or replacing the file there' {
        $directory = New-TestDirectory 'stopped-while-writing'
        $existing = Join-Path $directory 'report.pdf'
        Set-Content -LiteralPath $existing -Value 'kept' -NoNewline
        $held = Start-HeldSave $directory
        try {
            $held.Started.Task.Wait(30000) | Should -BeTrue -Because 'the command should be writing the file by now'

            # What Ctrl+C does; then the write goes on
            $stopping = $held.PowerShell.BeginStop($null, $null)
            $stopped = $stopping.AsyncWaitHandle.WaitOne(2000)
            $held.Gate.SetResult($null)
            $written = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($held.Started.Task.Result), 10000)

            $stopped | Should -BeTrue -Because 'Ctrl+C should not wait for the file being written'
            $written | Should -Be 0 -Because 'the write should have ended'
            Get-Content -LiteralPath $existing -Raw | Should -BeExactly 'kept'
            @(Get-ChildItem -LiteralPath $directory -Force).Name | Should -Be 'report.pdf' -Because 'no temporary file is left'
        } finally {
            $null = $held.Gate.TrySetResult($null)
            $held.PowerShell.Dispose()
        }
    }

    # Stopped once the task renames the file, the command waits for the task, so that nothing changes in the directory
    # after it ends. The end of the task is held, the file written and renamed already
    It 'waits on Ctrl+C for the task that already renames a file, and ends after it' {
        $directory = New-TestDirectory 'stopped-while-renaming'
        $held = Start-HeldSave $directory -After
        try {
            $held.Started.Task.Wait(30000) | Should -BeTrue -Because 'the command should have written the file by now'

            $stopping = $held.PowerShell.BeginStop($null, $null)
            $waited = -not $stopping.AsyncWaitHandle.WaitOne(1000)
            $held.Gate.SetResult($null)
            $stopped = $stopping.AsyncWaitHandle.WaitOne(10000)

            $waited | Should -BeTrue -Because 'the command should wait for the task that renames the file'
            $stopped | Should -BeTrue -Because 'the command should end once the task does'
            [IO.File]::ReadAllText((Join-Path $directory 'report.pdf')) | Should -BeExactly '%PDF-1.4 report'
            @(Get-ChildItem -LiteralPath $directory -Force).Name | Should -Be 'report.pdf' -Because 'no temporary file is left'
        } finally {
            $null = $held.Gate.TrySetResult($null)
            $held.PowerShell.Dispose()
        }
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
        $again = Save-ImapAttachment open -Folder All -Uid 19 -Path $directory -Inline -ContentType image/* -ErrorVariable errors -ErrorAction SilentlyContinue -WarningVariable warnings -WarningAction SilentlyContinue
        $read = Read-ImapMessage open -Folder All -Uid 19

        $files = @($output | Where-Object { $_ -is [IO.FileInfo] })
        $files.Name | Should -Be 'snapshot0.jpg'
        $files.Inline | Should -BeFalse
        @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like "*is the same file as '*snapshot0.jpg', saved from it, and was not saved again." }).Count | Should -Be 1
        $again | Should -BeNullOrEmpty
        $errors.FullyQualifiedErrorId | Should -BeLike 'AttachmentFileExists,*'
        # Running again, the file there may have come from another message: said aloud
        "$warnings" | Should -BeLike "The part 'snapshot0.jpg' of the message 19 * was not saved: it is the same file as '*snapshot0.jpg', which was already in the directory."
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

    It 'returns a saved file whose name starts with a dot, which Linux hides' {
        $files = Save-ImapAttachment open -Folder All -Uid 23 -Path (New-TestDirectory 'dot')

        $files.Name | Should -Be '.env.local'
        [IO.File]::ReadAllText($files[0].FullName) | Should -BeExactly 'KEY=value'
    }

    # The fake numbers each message alike in every folder, as UIDs of two folders may coincide
    It 'never replaces a file it saved from another message, -Force or not' {
        $twice = [PSCustomObject]@{ Account = 'open'; Folder = 'INBOX'; Uid = 10 }, [PSCustomObject]@{ Account = 'open'; Folder = '[Gmail]/All Mail'; Uid = 10 }
        $files = $twice | Save-ImapAttachment -Path (New-TestDirectory 'collision') -Name report.pdf -UniqueName -Force -ErrorVariable errors -ErrorAction SilentlyContinue

        $files.Name | Should -Be '10-report.pdf'
        $files.Folder | Should -Be 'INBOX'
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AttachmentFileExists,*'
        "$($errors[0])" | Should -BeLike "*was saved by this command from another message*a -Path of their own."
    }

    # Message 18 carries two files named report.pdf: the second is written as "report (2).pdf"
    It 'holds the name of the file to the policy, and the numbered name written too' {
        $denied = Save-ImapAttachment exact -Folder All -Uid 18 -Path (New-TestDirectory 'numbered-denied') -ErrorVariable deniedErrors -ErrorAction SilentlyContinue
        $named = Save-ImapAttachment named -Folder All -Uid 18 -Path (New-TestDirectory 'numbered-named') -ErrorVariable namedErrors -ErrorAction SilentlyContinue

        $denied | Should -BeNullOrEmpty
        $deniedErrors.Count | Should -Be 2
        "$($deniedErrors[1])" | Should -BeLike "*was not saved: The attachment report.pdf (application/pdf) matches 'report.pdf' in DenyAttachmentTypes of the policy 'exact'."
        @((Read-ImapMessage exact -Folder All -Uid 18).Attachments | Where-Object Withheld).Count | Should -Be 2
        $named.Name | Should -Be 'report.pdf'
        $namedErrors.Count | Should -Be 1
        "$($namedErrors[0])" | Should -BeLike "*was not saved: The attachment report (2).pdf (application/pdf) matches nothing in AllowAttachmentTypes of the policy 'named'."
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

    It 'saves a name written composed and decomposed as two files of one name, the second numbered' {
        $files = Save-ImapAttachment open -Folder All -Uid 24 -Path (New-TestDirectory 'accents')

        $files.Count | Should -Be 2
        [string]::Equals($files[0].Name, "relat`u{F3}rio.pdf", [StringComparison]::Ordinal) | Should -BeTrue -Because "'$($files[0].Name)' should be composed"
        [string]::Equals($files[1].Name, "relat`u{F3}rio (2).pdf", [StringComparison]::Ordinal) | Should -BeTrue -Because "'$($files[1].Name)' should be composed, and numbered"
        [IO.File]::ReadAllText($files[1].FullName) | Should -BeExactly '%PDF decomposed'
    }

    # A pattern with a wildcard before the accents: -like matches a decomposed text to it only when it is decomposed too
    It 'finds by -Name the files of a name, either written composed or decomposed' {
        $files = Save-ImapAttachment open -Folder All -Uid 24 -Path (New-TestDirectory 'accents-named') -Name "*relato`u{301}rio*"

        $files.Count | Should -Be 2
    }

    # The second "relatorio.pdf" is saved as "relatorio (2).pdf", which the pattern does not name: only the name the
    # message gives finds it, so that name is composed too, as the pattern is. A pattern without wildcards, or with
    # only a star at its end, would find it even so: WildcardPattern then compares the whole text by culture, which
    # takes the two forms for one, and any other pattern character by character (Copilot on #13)
    It 'finds by -Name the name a message gives decomposed, also when its file is numbered' {
        $files = Save-ImapAttachment open -Folder All -Uid 24 -Path (New-TestDirectory 'accents-given') -Name "*relat`u{F3}rio.pdf"

        $files.Count | Should -Be 2
        [IO.File]::ReadAllText($files[1].FullName) | Should -BeExactly '%PDF decomposed'
    }

    It 'shows a name that carries an escape sequence without it, in its messages' {
        $files = Save-ImapAttachment strict -Folder All -Uid 29 -Path (New-TestDirectory 'escape') -ErrorVariable errors -ErrorAction SilentlyContinue

        $files | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].ToString().Contains([char]27) | Should -BeFalse -Because 'an escape sequence would drive the terminal'
        $errors[0].ToString().Contains("The attachment 'report?[2J.exe' of the message 29") | Should -BeTrue -Because "the message is: $($errors[0])"
    }

    It 'holds names to the patterns of the policy, either written composed or decomposed' {
        $files = Save-ImapAttachment accents -Folder All -Uid 24 -Path (New-TestDirectory 'accents-denied') -ErrorVariable errors -ErrorAction SilentlyContinue

        $files | Should -BeNullOrEmpty
        $errors.Count | Should -Be 2
        foreach ($record in $errors) { $record.FullyQualifiedErrorId | Should -BeLike 'AttachmentWithheld,*' }
        @((Read-ImapMessage accents -Folder All -Uid 24).Attachments | Where-Object Withheld).Count | Should -Be 2
    }

    # -like ignores case as the culture of the session does: in Turkish, "I" is not the capital of "i"
    It 'matches the patterns of the policy, of -Name and of -ContentType alike in the Turkish culture' {
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'tr-TR'
            $denied = Save-ImapAttachment zip -Folder All -Uid 28 -Path (New-TestDirectory 'turkish-denied') -ErrorVariable errors -ErrorAction SilentlyContinue
            $named = Save-ImapAttachment open -Folder All -Uid 28 -Path (New-TestDirectory 'turkish-named') -Name '*.zip'
            $typed = Save-ImapAttachment open -Folder All -Uid 28 -Path (New-TestDirectory 'turkish-typed') -ContentType 'APPLICATION/*'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $culture
        }

        $denied | Should -BeNullOrEmpty
        $errors.FullyQualifiedErrorId | Should -BeLike 'AttachmentWithheld,*'
        $named.Name | Should -Be 'INVOICE.ZIP'
        $typed.Name | Should -Be 'INVOICE.ZIP'
    }

    # MimeKit, parsing the message, would write its lines with the line ends of the platform, and what is no message
    # as nothing
    It 'saves a message attached as the server keeps it, byte for byte' {
        $files = Save-ImapAttachment open -Folder All -Uid 25 -Path (New-TestDirectory 'eml')

        $files.Name | Should -Be 'original.eml', 'mislabeled.eml'
        $original = [Text.Encoding]::UTF8.GetBytes("From: Someone <someone@client.example>`r`nSubject: Original`r`n`r`nThe original text.`r`n")
        [Convert]::ToHexString([IO.File]::ReadAllBytes($files[0].FullName)) | Should -Be ([Convert]::ToHexString($original))
        [Convert]::ToHexString([IO.File]::ReadAllBytes($files[1].FullName)) | Should -Be ([Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes("%PDF-1.4`r`n%%EOF")))
    }

    # BODY[] would carry the headers of the message around it too (Copilot on #13)
    It 'saves a message attached as the whole body of another as the server keeps it, without the headers around it' {
        $files = Save-ImapAttachment open -Folder All -Uid 30 -Path (New-TestDirectory 'whole-eml')

        $files.Name | Should -Be 'forwarded.eml'
        $inside = [Text.Encoding]::UTF8.GetBytes("From: Someone <someone@client.example>`r`nSubject: Inside`r`n`r`nThe text inside.`r`n")
        [Convert]::ToHexString([IO.File]::ReadAllBytes($files[0].FullName)) | Should -Be ([Convert]::ToHexString($inside))
    }

    It 'never replaces a read-only file, -Force or not, and says so before fetching the attachment' -Skip:$isRoot {
        $directory = New-TestDirectory 'read-only'
        $existing = Join-Path $directory 'report.pdf'
        Set-Content -LiteralPath $existing -Value 'kept' -NoNewline
        if ($IsWindows) { [IO.File]::SetAttributes($existing, 'ReadOnly') } else { [IO.File]::SetUnixFileMode($existing, 'UserRead') }
        $before = $server.State.Commands.Count
        try {
            $files = Save-ImapAttachment open -Folder All -Uid 10 -Path $directory -Name report.pdf -Force -ErrorVariable errors -ErrorAction SilentlyContinue
        } finally {
            if ($IsWindows) { [IO.File]::SetAttributes($existing, 'Normal') } else { [IO.File]::SetUnixFileMode($existing, 'UserRead, UserWrite') }
        }

        $files | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AttachmentFileExists,*'
        "$($errors[0])" | Should -BeLike "'*report.pdf' already exists, so the part 'report.pdf' of the message 10 * was not saved: it is read-only, and not even -Force replaces such a file."
        Get-CommandSince $before | Where-Object { $_ -like '*BODY.PEEK`[2*' } | Should -BeNullOrEmpty
        Get-Content -LiteralPath $existing -Raw | Should -BeExactly 'kept'
    }

    # Where the volume keeps short names (NTFS when they are on, as on the drive of Windows, and FAT32 always),
    # REPORT~1.PDF stands for the first long name of the directory that starts so
    It 'replaces no other file through its short name, -Force or not' -Skip:(-not $IsWindows) {
        $directory = New-TestDirectory 'short-name'
        $long = Join-Path $directory 'report-final-version.pdf'
        Set-Content -LiteralPath $long -Value 'kept' -NoNewline
        if (-not [IO.File]::Exists((Join-Path $directory 'REPORT~1.PDF'))) {
            Set-ItResult -Skipped -Because 'the volume of the test drive keeps no short names'
            return
        }
        $files = Save-ImapAttachment open -Folder All -Uid 26 -Path $directory -Force

        $files.Name | Should -Be 'REPORT_1.PDF'
        Get-Content -LiteralPath $long -Raw | Should -BeExactly 'kept'
    }

    It 'refuses, once fetched, an attachment larger than the structure of the message told and than MaxAttachmentSize' {
        $files = Save-ImapAttachment small -Folder All -Uid 27 -Path (New-TestDirectory 'understated') -ErrorVariable errors -ErrorAction SilentlyContinue

        $files | Should -BeNullOrEmpty
        $errors.Count | Should -Be 1
        $errors[0].FullyQualifiedErrorId | Should -BeLike 'AttachmentWithheld,*'
        "$($errors[0])" | Should -BeLike "The part 'small.pdf' of the message 27 * was not saved: it has 2005 bytes, more than MaxAttachmentSize of the policy 'small' (1000), though the server told of fewer."
    }

    It 'saves a message given twice once, with no error' {
        $files = Save-ImapAttachment open -Folder All -Uid 10, 10 -Path (New-TestDirectory 'given-twice') -ErrorVariable errors -ErrorAction SilentlyContinue

        $errors | Should -BeNullOrEmpty
        $files.Name | Should -Be 'report.pdf', 'photo.jpg'
    }

    # Two servers may give the same user, folder, UIDVALIDITY and UID: the message of the second account is not taken
    # for a message given twice (Copilot on #13)
    It 'does not take the messages of two accounts with the same UID for one' {
        $two = [PSCustomObject]@{ Account = 'open'; Folder = '[Gmail]/All Mail'; Uid = 10 }, [PSCustomObject]@{ Account = 'elsewhere'; Folder = '[Gmail]/All Mail'; Uid = 10 }
        $files = $two | Save-ImapAttachment -Path (New-TestDirectory 'two-accounts') -Name photo.jpg -ErrorVariable errors -ErrorAction SilentlyContinue

        $files.Account | Should -Be 'open'
        $errors.Count | Should -Be 1
        "$($errors[0])" | Should -BeLike "*'photo.jpg'*AllowAttachmentTypes of the policy 'pdf'."
    }

    # A program that watches the directory may take a file away as soon as it comes
    It 'returns a file it saved that is gone at once, with no second error' {
        Mock -ModuleName ElektoImapPosh Get-Item { }
        $directory = New-TestDirectory 'taken-away'
        $files = Save-ImapAttachment open -Folder All -Uid 10 -Path $directory -Name report.pdf -ErrorVariable errors -ErrorAction SilentlyContinue

        $errors | Should -BeNullOrEmpty
        $files.FullName | Should -Be (Join-Path $directory 'report.pdf')
        $files.Uid | Should -Be 10
    }

    It 'refuses a -Path that is not of the file system' {
        { Save-ImapAttachment open -Folder All -Uid 10 -Path Env:\ } | Should -Throw "'Env:\' is not a directory of the file system, so no attachment can be saved in it."
    }

    It 'refuses a pattern that is not valid in -Name or -ContentType, before anything' {
        $before = $server.State.Commands.Count

        { Save-ImapAttachment open -Folder All -Uid 10 -Path (New-TestDirectory 'bad-pattern') -Name 'image[0' } | Should -Throw "Cannot validate argument on parameter 'Name'. The specified wildcard character pattern is not valid: image``[0"
        { Save-ImapAttachment open -Folder All -Uid 10 -Path (New-TestDirectory 'bad-type') -ContentType 'image/[' } | Should -Throw "Cannot validate argument on parameter 'ContentType'. The specified wildcard character pattern is not valid: image/``["
        $server.State.Commands.Count | Should -Be $before
    }
}
