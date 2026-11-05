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
# the first of a multipart/mixed when it has attachments), Attachments (each a hashtable: Name, Type, Data, its content
# as text, sent in base64, or as it is with Encoding 7bit, as a message attached comes, Octets, a size to declare in
# place of the real one, Disposition, attachment by default, or inline, or none, and ContentId) or Attachment (the name
# of a PDF), Raw (the X-GM-RAW
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
            # The attachments of a message, each a hashtable with Name, Type and Data (and Octets, a size to declare)
            function Get-Attachment($Message) {
                if ($Message.Attachments) { return , @($Message.Attachments) }
                if ($Message.Attachment) { return , @(@{ Name = $Message.Attachment; Type = 'application/pdf'; Data = "%PDF-1.4`n" }) }
                return , @()
            }
            # The content of an attachment as the message carries it: in base64, or as it is with Encoding 7bit
            function Get-PartBody($Attachment) {
                if ($Attachment.Encoding -eq '7bit') { return $Attachment.Data }
                return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Attachment.Data))
            }
            # The disposition of an attachment: attachment, unless it says inline, or none (no Content-Disposition)
            function Get-Disposition($Attachment) { if ($Attachment.Disposition) { return $Attachment.Disposition }; return 'attachment' }
            function Get-AttachmentHeader($Attachment) {
                $name = $Attachment.Name -replace '\\', '\\' -replace '"', '\"'
                $disposition = Get-Disposition $Attachment
                $lines = @(
                    if ($Attachment.Name) { "Content-Type: $($Attachment.Type); name=`"$name`"" } else { "Content-Type: $($Attachment.Type)" }
                    if ($disposition -ne 'none') { if ($Attachment.Name) { "Content-Disposition: $disposition; filename=`"$name`"" } else { "Content-Disposition: $disposition" } }
                    if ($Attachment.ContentId) { "Content-ID: <$($Attachment.ContentId)>" }
                    if ($Attachment.Encoding -eq '7bit') { 'Content-Transfer-Encoding: 7bit' } else { 'Content-Transfer-Encoding: base64' }
                )
                return ($lines -join "`r`n") + "`r`n`r`n"
            }
            # A section of a message, as BODY[section] gives it: the whole message (""), a part ("1", the text, "2" and on, the
            # attachments), or the headers of a part ("1.MIME")
            function Get-Section($Message, [string]$Section) {
                $text = if ($Message.Text) { $Message.Text } else { "The body of $($Message.Subject)." }
                $textHeaders = "Content-Type: text/plain; charset=utf-8`r`nContent-Transfer-Encoding: 8bit`r`n`r`n"
                $attachments = Get-Attachment $Message
                if ($Section -eq '') {
                    $top = "From: $($Message.From)`r`nTo: Me <me@gmail.com>`r`nSubject: $($Message.Subject)`r`nMessage-ID: <$($Message.Uid)@fake.example>`r`nMIME-Version: 1.0`r`n"
                    if (-not $attachments.Count) { return $top + $textHeaders + $text }
                    $parts = @("--b1`r`n$textHeaders$text`r`n") + @(foreach ($attachment in $attachments) { "--b1`r`n$(Get-AttachmentHeader $attachment)$(Get-PartBody $attachment)`r`n" })
                    return $top + "Content-Type: multipart/mixed; boundary=b1`r`n`r`n" + ($parts -join '') + "--b1--`r`n"
                }
                if ($Section -eq '1') { return $text }
                if ($Section -eq '1.MIME') { return $textHeaders }
                if ($Section -match '^(\d+)(\.MIME)?$' -and [int]$Matches[1] -ge 2 -and [int]$Matches[1] -le $attachments.Count + 1) {
                    $attachment = $attachments[[int]$Matches[1] - 2]
                    if ($Matches[2]) { return Get-AttachmentHeader $attachment }
                    # The CRLF before the boundary is not part of the content, which base64 does not mind
                    if ($attachment.Encoding -eq '7bit') { return $attachment.Data }
                    return "$(Get-PartBody $attachment)`r`n"
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
                $attachments = Get-Attachment $Message
                $structure = if (-not $attachments.Count) { $text } else {
                    $parts = foreach ($attachment in $attachments) {
                        $type, $subtype = $attachment.Type -split '/'
                        # Without a name, no parameters at all, as a server gives them
                        $name = Format-Quoted $attachment.Name
                        $parameters = if ($attachment.Name) { "(`"NAME`" $name)" } else { 'NIL' }
                        $kind = (Get-Disposition $attachment).ToUpperInvariant()
                        $disposition = if ($kind -eq 'NONE') { 'NIL' } elseif ($attachment.Name) { "(`"$kind`" (`"FILENAME`" $name))" } else { "(`"$kind`" NIL)" }
                        $id = if ($attachment.ContentId) { Format-Quoted "<$($attachment.ContentId)>" } else { 'NIL' }
                        $seven = $attachment.Encoding -eq '7bit'
                        $octets = if ($attachment.Octets) { $attachment.Octets } elseif ($seven) { [Text.Encoding]::UTF8.GetByteCount($attachment.Data) } else { (Get-PartBody $attachment).Length + 2 }
                        # A part of type TEXT also gives its number of lines, after its size; one of type MESSAGE/RFC822 the
                        # envelope and the structure of the message it carries, and then its number of lines
                        $size = if ($type -eq 'text') { "$octets 1" }
                        elseif ($attachment.Type -eq 'message/rfc822') { "$octets (NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL) (`"TEXT`" `"PLAIN`" NIL NIL NIL `"7BIT`" 0 0 NIL NIL NIL NIL) 1" }
                        else { "$octets" }
                        $encoding = if ($seven) { '7BIT' } else { 'BASE64' }
                        "(`"$($type.ToUpperInvariant())`" `"$($subtype.ToUpperInvariant())`" $parameters $id NIL `"$encoding`" $size NIL $disposition NIL NIL)"
                    }
                    "($text$($parts -join '') `"MIXED`" (`"BOUNDARY`" `"b1`") NIL NIL NIL)"
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
