# Messages: how a command finds them, by a SEARCH on the server, and what it fetches of each before the policy decides
# whether its body may be read (Get-WithheldReason, in Policies.ps1). First only metadata: the envelope, the flags,
# the size, the date the server received it, the structure of its parts (its text parts and attachments), on Gmail its
# thread and labels, the Authentication-Results headers that tell an authenticated sender, and X-Original-From, where
# a Google Group puts the sender it replaces. Then, when the policy
# allows it, the text part alone (Get-ImapMessageText). Parts are fetched with BODY.PEEK from folders opened read-only,
# so nothing is marked as read.

# Whether the server has the Gmail extensions (labels, threads, X-GM-RAW). They are used only when it announces them.
function Test-GMailServer($Session) {
    return $Session.Client.Capabilities.HasFlag([MailKit.Net.Imap.ImapCapabilities]::GMailExt1)
}

# The query of a search, with every term given, all of which must match: every message without any. -Since is the
# date the server received the message (SINCE), and -From and -Subject find part of the text, as IMAP does.
function Get-ImapSearchQuery([Nullable[datetime]]$Since, [switch]$Unread, [string]$From, [string]$Subject, [string]$Query) {
    $terms = @(
        if ($Since) { [MailKit.Search.SearchQuery]::DeliveredAfter($Since.Date) }
        if ($Unread) { [MailKit.Search.SearchQuery]::NotSeen }
        if ($From) { [MailKit.Search.SearchQuery]::FromContains($From) }
        if ($Subject) { [MailKit.Search.SearchQuery]::SubjectContains($Subject) }
        if ($Query) { [MailKit.Search.SearchQuery]::GMailRawSearch($Query) }
    )
    if ($terms.Count -eq 0) { return [MailKit.Search.SearchQuery]::All }
    $search = $terms[0]
    foreach ($term in ($terms | Select-Object -Skip 1)) { $search = $search.And($term) }
    return $search
}

# The UIDs of the messages of an open folder that match a query, the newest first (UIDs grow as messages arrive), in
# an array; or $null after reporting why not. Sorted by .NET, not by Sort-Object: All Mail can have hundreds of
# thousands, which a pipeline takes seconds to sort (measured: 1.6 s for 300,000, against 0.04 s).
function Find-ImapMessage($Cmdlet, $Session, $Folder, [MailKit.Search.SearchQuery]$Query) {
    $task = $Folder.SearchAsync($Query, [System.Threading.CancellationToken]::None)
    $failure = Wait-ImapTask $task
    if ($failure) {
        Write-ImapError $Cmdlet "Could not search the folder '$($Folder.FullName)' of $($Session.Settings.User): $failure" 'SearchFailed' ReadError $Folder.FullName
        return $null
    }
    $uids = [System.Linq.Enumerable]::ToArray([System.Collections.Generic.IEnumerable[MailKit.UniqueId]]$task.Result)
    [Array]::Sort($uids)
    [Array]::Reverse($uids)
    return , $uids
}

# The summaries of the messages of an open folder with the UIDs given, the newest first, in an array: their metadata,
# with all that the check of the policy needs; or $null after reporting why not. Only those of the UIDs given: when
# another client changes the folder, the server may add what changed in other messages, which MailKit returns too.
function Get-ImapMessageSummary($Cmdlet, $Session, $Folder, $Uids) {
    $items = [MailKit.MessageSummaryItems]'UniqueId, Envelope, Flags, InternalDate, Size, BodyStructure'
    if (Test-GMailServer $Session) { $items = $items -bor [MailKit.MessageSummaryItems]'GMailThreadId, GMailLabels' }
    $request = [MailKit.FetchRequest]::new($items)
    $request.Headers = [MailKit.HeaderSet]::new([string[]]@('Authentication-Results', 'X-Original-From'))
    $list = [System.Collections.Generic.List[MailKit.UniqueId]]::new()
    $wanted = [System.Collections.Generic.HashSet[uint]]::new()
    foreach ($uid in $Uids) { $list.Add($uid); $null = $wanted.Add($uid.Id) }

    $task = $Folder.FetchAsync([System.Collections.Generic.IList[MailKit.UniqueId]]$list, [MailKit.IFetchRequest]$request, [System.Threading.CancellationToken]::None)
    $failure = Wait-ImapTask $task
    if ($failure) {
        Write-ImapError $Cmdlet "Could not read the messages of the folder '$($Folder.FullName)' of $($Session.Settings.User): $failure" 'MessageFetchFailed' ReadError $Folder.FullName
        return $null
    }
    return , @($task.Result | Where-Object { $_.UniqueId.IsValid -and $wanted.Contains($_.UniqueId.Id) } | Sort-Object { $_.UniqueId.Id } -Descending)
}

# The addresses of a list as text, each as "Name <address>", or the address alone when it has no name, as
# Format-ShownText shows a text; none for no list. At most the first $script:ShownAddressCount, and then how many more
# there were ("... and 9900 more"), so that thousands of them do not flood the context of an AI, and a script that
# answers them all fails on that line rather than leave some out unsaid.
function Format-ImapAddress($List) {
    $all = @(foreach ($address in $List) { $address })
    $count = [Math]::Min($all.Count, $script:ShownAddressCount)
    $texts = [string[]]::new($count)
    for ($index = 0; $index -lt $count; $index++) {
        $address = $all[$index]
        $texts[$index] = if ($address -is [MimeKit.MailboxAddress] -and $address.Name) { "$($address.Name) <$($address.Address)>" }
        elseif ($address -is [MimeKit.MailboxAddress]) { $address.Address }
        else { "$address" }
    }
    # All of them in one call
    $shown = [string[]]@(Format-ShownText $texts)
    if ($all.Count -gt $count) { $shown += "`u{2026} and $($all.Count - $count) more" }
    return , $shown
}

# The one folder a name given to -Folder stands for, as Read-ImapMessage takes it (with -Literal, as from the pipeline,
# the folder of that exact name; see Find-ImapFolder), opened read-only, for a command that reads its messages by UID,
# by Message-ID or by thread; or $null after reporting why not: no such folder, or a pattern that names more than one.
# In an array of one: a folder written to the pipeline on its own would be enumerated (see Folders.ps1).
function Open-NamedImapFolder($Cmdlet, $Session, [string]$Name, [switch]$Literal) {
    $chosen = Find-ImapFolder $Cmdlet $Session $Name -Literal:$Literal
    if ($null -eq $chosen) { return $null }
    if ($chosen.Count -gt 1) {
        Write-ImapError $Cmdlet "'$Name' names $($chosen.Count) folders of $($Session.Settings.User) ($($chosen.FullName -join ', ')), and the messages are read from one: give its full name." 'FolderAmbiguous' InvalidArgument $Name
        return $null
    }
    if ($chosen.Count -eq 0) { return $null }
    if (-not (Open-ImapFolder $Cmdlet $Session $chosen[0])) { return $null }
    return , $chosen[0]
}

# The messages with the UIDs given in a folder, named as -Folder of Read-ImapMessage takes it (Open-NamedImapFolder),
# opened read-only: a hashtable with the Folder and the summaries ByUid; or $null after reporting why not. A
# UidValidity that is not the folder's (0 is none given: UIDVALIDITY never is) means that its messages were numbered
# anew since they were listed, so that the UIDs may be of other messages: each one is reported, and none is read.
function Get-ImapMessageByUid($Cmdlet, $Session, [string]$FolderName, [switch]$Literal, [uint32[]]$Uid, [uint32]$UidValidity) {
    $user = $Session.Settings.User
    $folder = Open-NamedImapFolder $Cmdlet $Session $FolderName -Literal:$Literal
    if ($null -eq $folder) { return $null }
    if ($UidValidity -and $UidValidity -ne $folder.UidValidity) {
        foreach ($id in $Uid) {
            Write-ImapError $Cmdlet "The folder '$($folder.FullName)' of $user was numbered anew since its messages were listed (UIDVALIDITY $UidValidity, now $($folder.UidValidity)), so the UID $id may be another message: list them again with Get-ImapMessage." 'UidValidityChanged' InvalidData $id
        }
        return $null
    }
    $summaries = Get-ImapMessageSummary $Cmdlet $Session $folder @($Uid | ForEach-Object { [MailKit.UniqueId]::new($folder.UidValidity, $_) })
    if ($null -eq $summaries) { return $null }
    # By UID, found once: a search of the list for each of many UIDs would take their square
    $byUid = @{}
    foreach ($summary in $summaries) { $byUid[$summary.UniqueId.Id] = $summary }
    return @{ Folder = $folder; ByUid = $byUid }
}

# The most messages a search by Message-ID may find before their envelopes are fetched to tell the one. A whole
# Message-ID is part of the Message-ID of a few at most; a short text ("gmail.com") is part of those of thousands, whose
# envelopes would all be downloaded, and held to the text one by one (some 50 us a message, measured).
$script:MessageIdCandidates = 100

# The one message of a folder (Open-NamedImapFolder) whose Message-ID is $MessageId exactly, given with or without its
# angle brackets: a hashtable with its Folder and its Summary; or $null after reporting why not, when no message has
# it (MessageNotFound) or more than one has (MoreThanOneMessage). The server finds the messages whose Message-ID has
# the text, ignoring case, as IMAP searches a header; each is then held to the whole of it, as its envelope gives it
# (MailKit takes the brackets off), before the summary of the one is fetched: unless the server finds more than
# MessageIdCandidates, which only a part of a Message-ID does. Narrowed to the days of MaxAgeDays of the policy, as
# every search is.
function Find-ImapMessageById($Cmdlet, $Session, [string]$FolderName, [switch]$Literal, [string]$MessageId) {
    $user = $Session.Settings.User
    $folder = Open-NamedImapFolder $Cmdlet $Session $FolderName -Literal:$Literal
    if ($null -eq $folder) { return $null }
    $id = $MessageId.Trim()
    if ($id.StartsWith('<', [StringComparison]::Ordinal) -and $id.EndsWith('>', [StringComparison]::Ordinal)) { $id = $id.Substring(1, $id.Length - 2) }
    $search = [MailKit.Search.SearchQuery]::HeaderContains('Message-ID', $id)
    $start = Get-PolicyStartDate $Session.Settings.Policy
    if ($start) { $search = $search.And([MailKit.Search.SearchQuery]::DeliveredAfter($start)) }
    $found = Find-ImapMessage $Cmdlet $Session $folder $search
    if ($null -eq $found) { return $null }
    $shown = Format-ShownText $MessageId
    if ($found.Count -gt $script:MessageIdCandidates) {
        Write-ImapError $Cmdlet "$($found.Count) messages in the folder '$($folder.FullName)' of $user have '$shown' in their Message-ID, so none was saved: give the whole Message-ID of one, or its -Uid." 'MoreThanOneMessage' InvalidArgument $MessageId
        return $null
    }

    # Their envelopes alone, to tell the one: a short text can be part of the Message-ID of many messages
    $matching = [System.Collections.Generic.List[MailKit.UniqueId]]::new()
    if ($found.Count) {
        $wanted = [System.Collections.Generic.HashSet[uint]]::new()
        foreach ($uid in $found) { $null = $wanted.Add($uid.Id) }
        $request = [MailKit.FetchRequest]::new([MailKit.MessageSummaryItems]'UniqueId, Envelope')
        $task = $folder.FetchAsync([System.Collections.Generic.IList[MailKit.UniqueId]]$found, [MailKit.IFetchRequest]$request, [System.Threading.CancellationToken]::None)
        $failure = Wait-ImapTask $task
        if ($failure) {
            Write-ImapError $Cmdlet "Could not read the messages of the folder '$($folder.FullName)' of ${user}: $failure" 'MessageFetchFailed' ReadError $folder.FullName
            return $null
        }
        foreach ($summary in $task.Result) {
            # Only those asked for: the server may add what another client changed in other messages
            if ($summary.UniqueId.IsValid -and $wanted.Contains($summary.UniqueId.Id) -and [string]::Equals($summary.Envelope.MessageId, $id, [StringComparison]::Ordinal)) { $matching.Add($summary.UniqueId) }
        }
    }
    if ($matching.Count -gt 1) {
        $uids = @($matching | ForEach-Object { $_.Id } | Sort-Object) -join ', '
        Write-ImapError $Cmdlet "$($matching.Count) messages in the folder '$($folder.FullName)' of $user have the Message-ID '$shown' (the UIDs $uids), so none was saved: give the -Uid of one." 'MoreThanOneMessage' InvalidArgument $MessageId
        return $null
    }
    $summary = $null
    if ($matching.Count -eq 1) {
        $summaries = Get-ImapMessageSummary $Cmdlet $Session $folder @($matching[0])
        if ($null -eq $summaries) { return $null }
        # None when the message went away since the search
        $summary = @($summaries)[0]
    }
    if (-not $summary) {
        $since = if ($start) { " received since $($start.ToString('yyyy-MM-dd')), the first day that MaxAgeDays of the policy '$($Session.Settings.Policy.Name)' allows" }
        Write-ImapError $Cmdlet "There is no message with the Message-ID '$shown' in the folder '$($folder.FullName)' of $user$since." 'MessageNotFound' ObjectNotFound $MessageId
        return $null
    }
    return @{ Folder = $folder; Summary = $summary }
}

# A message as the commands return it: its metadata, and why the policy withholds its body, if it does, as the check of
# the caller found (Get-WithheldReason). The properties are the same on every server (ThreadId and Labels are $null
# off Gmail), so that the objects export alike. What the sender writes (subject, addresses, Message-IDs) as
# Format-ShownText shows it; the labels and the folder are the user's own.
function ConvertTo-ImapMessage($Session, $Folder, $Summary, [string]$Withheld) {
    $envelope = $Summary.Envelope
    $gmail = Test-GMailServer $Session
    $labels = if ($gmail) { , [string[]]@($Summary.GMailLabels) }
    $subject, $messageId, $inReplyTo = Format-ShownText $envelope.Subject, $envelope.MessageId, $envelope.InReplyTo
    [PSCustomObject]@{
        PSTypeName     = 'ElektoImapPosh.Message'
        Account        = $Session.Settings.Account
        Folder         = $Folder.FullName
        Uid            = $Summary.UniqueId.Id
        UidValidity    = $Folder.UidValidity
        Date           = if ($Summary.InternalDate) { $Summary.InternalDate.LocalDateTime } else { $null }
        From           = (Format-ImapAddress $envelope.From) -join ', '
        To             = Format-ImapAddress $envelope.To
        Cc             = Format-ImapAddress $envelope.Cc
        Subject        = $subject
        Size           = [long]$Summary.Size
        Flags          = $Summary.Flags
        HasAttachments = (Get-ImapFilePart $Summary).Attachments.Count -gt 0
        MessageId      = $messageId
        InReplyTo      = $inReplyTo
        ThreadId       = if ($gmail) { $Summary.GMailThreadId } else { $null }
        Labels         = $labels
        Withheld       = if ($Withheld) { $Withheld } else { $null }
    }
}

# The most UIDs that Read-ImapMessage keeps before it reads them: the summaries of the messages kept come in one FETCH
# for each folder, rather than one for each message, a round trip each (some 0.4 s against Gmail, measured); their texts
# still one each, as MailKit fetches a part of one message at a time (and each message has its text in a part of its own)
$script:ReadBatchSize = 100

# Reads the messages that Read-ImapMessage kept, each request one item of its pipeline (its session, the name of its
# folder, whether that name is literal, its UIDs and UidValidity), and returns what Read-ImapMessage returns for them:
# first the summaries, one FETCH for each folder of each account (and UidValidity given), in the order the folders came;
# then each message in the order it came, its folder opened again when another was opened since. Once MaxMessages is
# spent, the messages of a folder not yet fetched are left out without fetching anything; within a batch, the summaries
# (metadata, which a policy never withholds) may be fetched of messages that the limit then leaves out.
function Read-ImapMessageBatch($Cmdlet, [object[]]$Requests, [switch]$Html, [int]$MaxLength) {
    $groups = [System.Collections.Generic.List[object]]::new()
    $byKey = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($request in $Requests) {
        if (-not $request.Session.ContainsKey('BatchKey')) { $request.Session.BatchKey = [guid]::NewGuid().ToString('N') }
        $key = "$($request.Session.BatchKey)`n$([int][bool]$request.Literal)`n$($request.UidValidity)`n$($request.Folder)"
        $group = $null
        if (-not $byKey.TryGetValue($key, [ref]$group)) {
            $group = @{ Session = $request.Session; Folder = $request.Folder; Literal = $request.Literal; UidValidity = $request.UidValidity; Uids = [System.Collections.Generic.List[uint32]]::new(); Fetched = $false; Found = $null }
            $byKey[$key] = $group
            $groups.Add($group)
        }
        $request.Group = $group
        foreach ($id in $request.Uid) { $group.Uids.Add($id) }
    }
    foreach ($group in $groups) {
        $policy = $group.Session.Settings.Policy
        if ($policy -and $policy.MaxMessages -and [int]$group.Session.MessagesHandled -ge $policy.MaxMessages) { continue }
        $group.Found = Get-ImapMessageByUid $Cmdlet $group.Session $group.Folder -Literal:$group.Literal -Uid $group.Uids.ToArray() -UidValidity $group.UidValidity
        $group.Fetched = $true
    }

    foreach ($request in $Requests) {
        $session = $request.Session
        $settings = $session.Settings
        $policy = $settings.Policy
        if (-not $request.Group.Fetched) {
            $session.MessagesLeftOut = [int]$session.MessagesLeftOut + $request.Uid.Count
            continue
        }
        # Not found, or numbered anew: Get-ImapMessageByUid said so
        $found = $request.Group.Found
        if (-not $found) { continue }
        $item = $found.Folder
        foreach ($id in $request.Uid) {
            $summary = $found.ByUid[$id]
            if (-not $summary) {
                Write-ImapError $Cmdlet "There is no message with the UID $id in the folder '$($item.FullName)' of $($settings.User)." 'MessageNotFound' ObjectNotFound $id
                continue
            }
            # The one check of the policy, on the metadata, before the body is fetched
            $reason = Get-WithheldReason $session $item $summary
            if ($reason) {
                Write-ImapError $Cmdlet "The message $id in the folder '$($item.FullName)' of $($settings.User) was not read: $reason" 'MessageWithheld' PermissionDenied $id
                continue
            }
            # MaxMessages counts the messages of the account read in the whole command
            if ($policy -and $policy.MaxMessages -and [int]$session.MessagesHandled -ge $policy.MaxMessages) {
                $session.MessagesLeftOut = [int]$session.MessagesLeftOut + 1
                continue
            }
            # Another folder of the batch may have been opened since its summaries came
            if (-not (Open-ImapFolder $Cmdlet $session $item)) { continue }
            $session.MessagesHandled = [int]$session.MessagesHandled + 1

            $content = Get-ImapMessageText $Cmdlet $session $item $summary -Html:$Html
            if ($null -eq $content) { continue }
            # With its lines, and whole; then cut by -MaxLength
            $text = Format-ShownBody $content.Text
            $truncated = [bool]($MaxLength -and $text -and $text.Length -gt $MaxLength)
            if ($truncated) {
                # Not between the two halves of a character outside the BMP (an emoji), which would leave half of it
                $length = if ([char]::IsHighSurrogate($text[$MaxLength - 1])) { $MaxLength - 1 } else { $MaxLength }
                $text = $text.Substring(0, $length)
            }

            # Not withheld: the check above passed
            $message = ConvertTo-ImapMessage $session $item $summary $null
            $message.PSObject.TypeNames.Insert(0, 'ElektoImapPosh.MessageText')
            $parts = Get-ImapPartList $session $item $summary
            $message | Add-Member -NotePropertyMembers ([ordered]@{
                    Attachments = [object[]]@($parts | Where-Object { -not $_.Inline } | Select-Object Name, FileName, ContentType, Size, Withheld)
                    InlineParts = [object[]]@($parts | Where-Object { $_.Inline } | Select-Object Name, FileName, ContentType, Size, Withheld)
                    Format      = $content.Format
                    Truncated   = $truncated
                    Text        = $text
                })
            $message
        }
    }
}

# The text of a message, in a hashtable with Text and Format (Text or Html, both $null when the message has no text):
# its text/plain part, or else its text/html part, as they are; with -Html, the other way round. MimeKit decodes them
# (base64 or quoted-printable, and their charset); nothing converts the HTML. Only that part is fetched, by BODY.PEEK:
# of a multipart message, never its attachments; of a message of one part, all of it, which is that part and its
# headers. $null after reporting why not.
function Get-ImapMessageText($Cmdlet, $Session, $Folder, $Summary, [switch]$Html) {
    $parts = if ($Html) { $Summary.HtmlBody, $Summary.TextBody } else { $Summary.TextBody, $Summary.HtmlBody }
    $part = @($parts | Where-Object { $_ })[0]
    if (-not $part) { return @{ Text = $null; Format = $null } }
    $task = $Folder.GetBodyPartAsync($Summary.UniqueId, $part, [System.Threading.CancellationToken]::None, $null)
    $failure = Wait-ImapTask $task
    if ($failure) {
        Write-ImapError $Cmdlet "Could not read the message $($Summary.UniqueId.Id) of the folder '$($Folder.FullName)' of $($Session.Settings.User): $failure" 'MessageFetchFailed' ReadError $Summary.UniqueId.Id
        return $null
    }
    return @{ Text = $task.Result.Text; Format = if ($part.IsHtml) { 'Html' } else { 'Text' } }
}
