# A fake Gmail IMAP server, for the tests of what Gmail has and no emulator does: the extensions of X-GM-EXT-1 (labels,
# threads, X-GM-RAW searches), folders marked with their special use, and a BODYSTRUCTURE with attachments, which
# smtp4dev leaves out. It answers from a runspace, on a free port of the loopback, one connection after another, the
# commands MailKit sends, as Gmail answers them, and keeps the commands it got. Like smtp4dev, it has no TLS.
# The answers follow Google's description of its extensions (developers.google.com/workspace/gmail/imap/imap-extensions)
# and the Gmail transcripts of MailKit's tests (UnitTests/Net/Imap/Resources/gmail): the folders and their attributes,
# the labels as a FETCH of summaries gives them (system labels quoted too, "\Inbox"), X-GM-THRID.
# It announces fewer capabilities than Gmail (no ESEARCH, LIST-STATUS or CONDSTORE), so MailKit sends the plain form of
# its commands. It proves the module's reading of those answers, not Gmail's: what an Authentication-Results header of
# Gmail says, for one, comes from a real message.
# Each message is a hashtable: Uid, Folders (the full names of those it is in), Labels, ThreadId, From, Subject, Date,
# Size, Seen, AuthenticationResults (the value of the topmost header), Text (of its text/plain part, the only one, or
# the first of a multipart/mixed when it has an Attachment, a file name), Raw (the X-GM-RAW
# searches it matches; any other search matches every message of the folder), and ChangedElsewhere: as if another
# client had changed its flags, a FETCH of them comes, unasked, with every UID FETCH that does not ask for it.

# The folders of the mailbox, with their attributes: Gmail's in English, and labels of the user, one named Sent
$script:FakeGmailFolders = [ordered]@{
    'INBOX'             = '\HasNoChildren'
    '[Gmail]'           = '\HasChildren \NonExistent'
    '[Gmail]/All Mail'  = '\All \HasNoChildren'
    '[Gmail]/Sent Mail' = '\HasNoChildren \Sent'
    '[Gmail]/Trash'     = '\HasNoChildren \Trash'
    'Finance'           = '\HasChildren'
    'Finance/Bank'      = '\HasNoChildren'
    'Sent'              = '\HasNoChildren'
}

function Start-FakeGmail([hashtable[]]$Messages) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $state = [hashtable]::Synchronized(@{ Commands = [Collections.Concurrent.ConcurrentQueue[string]]::new(); Client = $null })
    $runspace = [powershell]::Create().AddScript({
            param($Listener, $State, $Messages, $Folders)

            function Format-Quoted([string]$Text) {
                if (-not $Text) { return 'NIL' }
                return '"' + ($Text -replace '\\', '\\' -replace '"', '\"') + '"'
            }
            # "Name <box@domain>" or "box@domain" as an address of an envelope, in a list
            function Format-Address([string]$Address) {
                $null = $Address -match '^(?:(.*?)\s*<)?([^<@\s]+)@([^>\s]+)>?$'
                return "(($(Format-Quoted $Matches[1]) NIL $(Format-Quoted $Matches[2]) $(Format-Quoted $Matches[3])))"
            }
            function Get-FolderMessage($Messages, [string]$Folder) {
                return , @($Messages | Where-Object { $_.Folders -contains $Folder } | Sort-Object { $_.Uid })
            }
            function Expand-UidSet([string]$Set, $InFolder) {
                $uids = foreach ($part in $Set -split ',') {
                    $first, $last = $part -split ':'
                    $last = if ($null -eq $last) { $first } else { $last }
                    $top = [int]::MaxValue
                    $low = if ($first -eq '*') { $top } else { [int]$first }
                    $high = if ($last -eq '*') { $top } else { [int]$last }
                    if ($low -gt $high) { $low, $high = $high, $low }
                    $InFolder | Where-Object { $_.Uid -ge $low -and $_.Uid -le $high } | ForEach-Object { $_.Uid }
                }
                return @($uids | Sort-Object -Unique)
            }
            # A section of a message, as BODY[section] gives it: the whole message (""), a part ("1"), or its headers ("1.MIME")
            function Get-Section($Message, [string]$Section) {
                $text = if ($Message.Text) { $Message.Text } else { "The body of $($Message.Subject)." }
                $textHeaders = "Content-Type: text/plain; charset=utf-8`r`nContent-Transfer-Encoding: 8bit`r`n`r`n"
                $name = $Message.Attachment
                switch ($Section) {
                    '' {
                        $top = "From: $($Message.From)`r`nTo: Me <me@gmail.com>`r`nSubject: $($Message.Subject)`r`nMessage-ID: <$($Message.Uid)@fake.example>`r`nMIME-Version: 1.0`r`n"
                        if (-not $name) { return $top + $textHeaders + $text }
                        return $top + "Content-Type: multipart/mixed; boundary=b1`r`n`r`n--b1`r`n$textHeaders$text`r`n--b1`r`n" +
                            "Content-Type: application/pdf; name=$name`r`nContent-Disposition: attachment; filename=$name`r`nContent-Transfer-Encoding: base64`r`n`r`nJVBERi0xLjQK`r`n--b1--`r`n"
                    }
                    '1' { return $text }
                    '1.MIME' { return $textHeaders }
                    '2' { return "JVBERi0xLjQK`r`n" }
                    '2.MIME' { return "Content-Type: application/pdf; name=$name`r`nContent-Disposition: attachment; filename=$name`r`nContent-Transfer-Encoding: base64`r`n`r`n" }
                }
                return ''
            }

            # The items asked for, and only those, as Gmail answers; literals counted in the bytes of UTF-8
            function Write-Fetch($Writer, [int]$Sequence, $Message, [string]$Items) {
                $culture = [Globalization.CultureInfo]::InvariantCulture
                $date = ([DateTimeOffset]$Message.Date).ToUniversalTime()
                $envelope = '(' + (@(
                        Format-Quoted $date.ToString('ddd, dd MMM yyyy HH:mm:ss +0000', $culture)
                        Format-Quoted $Message.Subject
                        Format-Address $Message.From
                        Format-Address $Message.From
                        Format-Address $Message.From
                        Format-Address 'Me <me@gmail.com>'
                        'NIL', 'NIL', 'NIL'
                        Format-Quoted "<$($Message.Uid)@fake.example>"
                    ) -join ' ') + ')'
                $text = '("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 20 1 NIL NIL NIL NIL)'
                $structure = if (-not $Message.Attachment) { $text } else {
                    $name = Format-Quoted $Message.Attachment
                    "($text(`"APPLICATION`" `"PDF`" (`"NAME`" $name) NIL NIL `"BASE64`" 1000 NIL (`"ATTACHMENT`" (`"FILENAME`" $name)) NIL NIL) `"MIXED`" (`"BOUNDARY`" `"b1`") NIL NIL NIL)"
                }
                $labels = @($Message.Labels | ForEach-Object { Format-Quoted $_ }) -join ' '
                $thread = if ($Message.ThreadId) { $Message.ThreadId } else { $Message.Uid }
                $header = if ($Message.AuthenticationResults) { "Authentication-Results: $($Message.AuthenticationResults)`r`n`r`n" } else { "`r`n" }
                $answer = @(
                    "UID $($Message.Uid)"
                    if ($Items -match '\bFLAGS\b') { "FLAGS ($(if ($Message.Seen) { '\Seen' }))" }
                    if ($Items -match '\bINTERNALDATE\b') { "INTERNALDATE `"$($date.ToString('dd-MMM-yyyy HH:mm:ss +0000', $culture))`"" }
                    if ($Items -match '\bRFC822\.SIZE\b') { "RFC822.SIZE $($Message.Size)" }
                    if ($Items -match '\bENVELOPE\b') { "ENVELOPE $envelope" }
                    if ($Items -match '\bBODYSTRUCTURE\b') { "BODYSTRUCTURE $structure" }
                    if ($Items -match '\bX-GM-THRID\b') { "X-GM-THRID $thread" }
                    if ($Items -match '\bX-GM-LABELS\b') { "X-GM-LABELS ($labels)" }
                    if ($Items -match 'HEADER\.FIELDS \(AUTHENTICATION-RESULTS\)') { "BODY[HEADER.FIELDS (AUTHENTICATION-RESULTS)] {$([Text.Encoding]::UTF8.GetByteCount($header))}`r`n$header" }
                    foreach ($match in [regex]::Matches($Items, 'BODY\.PEEK\[([^\]]*)\]')) {
                        $section = $match.Groups[1].Value
                        if ($section -like 'HEADER.FIELDS*') { continue }
                        $content = Get-Section $Message $section
                        "BODY[$section] {$([Text.Encoding]::UTF8.GetByteCount($content))}`r`n$content"
                    }
                ) -join ' '
                $Writer.Write("* $Sequence FETCH ($answer)`r`n")
            }

            $capabilities = 'IMAP4rev1 X-GM-EXT-1 SPECIAL-USE CHILDREN'
            while ($true) {
                try { $client = $Listener.AcceptTcpClient() } catch { break }
                $State.Client = $client
                try {
                    $stream = $client.GetStream()
                    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII)
                    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
                    $writer.NewLine = "`r`n"
                    $writer.AutoFlush = $true
                    $writer.WriteLine("* OK [CAPABILITY $capabilities] Fake Gmail ready")
                    $selected = $null
                    while ($null -ne ($line = $reader.ReadLine())) {
                        $State.Commands.Enqueue($line)
                        # The tagged answer, when it is not a plain OK ("continue" here would only leave the switch)
                        $answer = $null
                        $tag, $command, $arguments = $line -split ' ', 3
                        $command = $command.ToUpperInvariant()
                        if ($command -eq 'UID') { $command, $arguments = $arguments -split ' ', 2; $command = "UID $($command.ToUpperInvariant())" }
                        switch ($command) {
                            'CAPABILITY' { $writer.WriteLine("* CAPABILITY $capabilities") }
                            'LIST' {
                                $pattern = ($arguments -split ' ', 2)[1].Trim('"')
                                if ($pattern -eq '') { $writer.WriteLine('* LIST (\Noselect) "/" ""') }
                                foreach ($entry in $Folders.GetEnumerator()) {
                                    if ($pattern -like '*[*%]*' -or $pattern -eq $entry.Key) { $writer.WriteLine("* LIST ($($entry.Value)) `"/`" $(Format-Quoted $entry.Key)") }
                                }
                            }
                            { $_ -in 'EXAMINE', 'SELECT' } {
                                $selected = $arguments.Trim('"') -replace '\\(.)', '$1'
                                $inFolder = Get-FolderMessage $Messages $selected
                                $next = if ($inFolder) { ($inFolder | ForEach-Object { $_.Uid } | Measure-Object -Maximum).Maximum + 1 } else { 1 }
                                $writer.WriteLine('* FLAGS (\Answered \Flagged \Draft \Deleted \Seen)')
                                $writer.WriteLine('* OK [PERMANENTFLAGS ()] Flags permitted.')
                                $writer.WriteLine('* OK [UIDVALIDITY 7] UIDs valid.')
                                $writer.WriteLine("* $($inFolder.Count) EXISTS")
                                $writer.WriteLine('* 0 RECENT')
                                $writer.WriteLine("* OK [UIDNEXT $next] Predicted next UID.")
                                $answer = "$tag OK [READ-ONLY] $selected selected. (Success)"
                            }
                            'UID SEARCH' {
                                $inFolder = Get-FolderMessage $Messages $selected
                                # MailKit sends the search as an atom when it can, and quoted otherwise
                                $found = if ($arguments -match 'X-GM-RAW (?:"((?:[^"\\]|\\.)*)"|(\S+))') {
                                    $raw = if ($null -ne $Matches[1]) { $Matches[1] -replace '\\(.)', '$1' } else { $Matches[2] }
                                    $inFolder | Where-Object { $_.Raw -contains $raw }
                                } else { $inFolder }
                                $writer.WriteLine("* SEARCH $(@($found | ForEach-Object { $_.Uid }) -join ' ')".TrimEnd())
                            }
                            'UID FETCH' {
                                $inFolder = Get-FolderMessage $Messages $selected
                                $set, $items = $arguments -split ' ', 2
                                foreach ($uid in (Expand-UidSet $set $inFolder)) {
                                    $index = [array]::IndexOf(@($inFolder | ForEach-Object { $_.Uid }), $uid)
                                    Write-Fetch $writer ($index + 1) $inFolder[$index] $items
                                }
                                $asked = Expand-UidSet $set $inFolder
                                for ($index = 0; $index -lt $inFolder.Count; $index++) {
                                    $message = $inFolder[$index]
                                    if ($message.ChangedElsewhere -and $asked -notcontains $message.Uid) {
                                        $writer.Write("* $($index + 1) FETCH (UID $($message.Uid) FLAGS ($(if ($message.Seen) { '\Seen' })))`r`n")
                                    }
                                }
                            }
                            'LOGOUT' { $writer.WriteLine('* BYE Fake Gmail logging out') }
                        }
                        $writer.WriteLine($(if ($answer) { $answer } else { "$tag OK $command completed (Success)" }))
                        if ($command -eq 'LOGOUT') { break }
                    }
                } catch {
                    # The connection closed by the client, or by Stop-FakeGmail; kept, for a test that fails
                    $State.LastError = $_
                } finally {
                    $client.Dispose()
                }
            }
        }).AddArgument($listener).AddArgument($state).AddArgument($Messages).AddArgument($script:FakeGmailFolders)
    $null = $runspace.BeginInvoke()
    [pscustomobject]@{ Port = $listener.LocalEndpoint.Port; Listener = $listener; Runspace = $runspace; State = $state }
}

function Stop-FakeGmail($Server) {
    $Server.Listener.Stop()
    if ($Server.State.Client) { $Server.State.Client.Dispose() }
    $null = $Server.Runspace.BeginStop($null, $null)
    $Server.Runspace.Dispose()
}
