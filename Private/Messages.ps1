# Messages: how a command finds them, by a SEARCH on the server, and what it fetches of each before the policy decides
# whether its body may be read (Get-WithheldReason, in Policies.ps1). First only metadata: the envelope, the flags,
# the size, the date the server received it, the structure of its parts (its text parts and attachments), on Gmail its
# thread and labels, and the Authentication-Results headers that tell an authenticated sender. Then, when the policy
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
    $request.Headers = [MailKit.HeaderSet]::new([string[]]@('Authentication-Results'))
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

# The addresses of a list as text, each as "Name <address>", or the address alone when it has no name; none for no list
function Format-ImapAddress($List) {
    return , [string[]]@(foreach ($address in $List) {
            if ($address -is [MimeKit.MailboxAddress] -and $address.Name) { "$($address.Name) <$($address.Address)>" }
            elseif ($address -is [MimeKit.MailboxAddress]) { $address.Address }
            else { "$address" }
        })
}

# The messages with the UIDs given in a folder, named as -Folder of Read-ImapMessage takes it (a single folder; with
# -Literal, as from the pipeline, its exact name), opened read-only: a hashtable with the Folder and the summaries
# ByUid; or $null after reporting why not. A UidValidity that is not the folder's (0 is none given: UIDVALIDITY never
# is) means that its messages were numbered anew since they were listed, so that the UIDs may be of other messages:
# each one is reported, and none is read.
function Get-ImapMessageByUid($Cmdlet, $Session, [string]$FolderName, [switch]$Literal, [uint32[]]$Uid, [uint32]$UidValidity) {
    $user = $Session.Settings.User
    $folders = Get-ImapFolderList $Cmdlet $Session
    if ($null -eq $folders) { return $null }
    $chosen = Select-ImapFolderList $Cmdlet $Session $folders $FolderName -Literal:$Literal
    if ($chosen.Count -gt 1) {
        Write-ImapError $Cmdlet "'$FolderName' names $($chosen.Count) folders of $user ($($chosen.FullName -join ', ')), and a UID is of one: give its full name." 'FolderAmbiguous' InvalidArgument $FolderName
        return $null
    }
    if ($chosen.Count -eq 0) { return $null }
    $folder = $chosen[0]
    if (-not (Open-ImapFolder $Cmdlet $Session $folder)) { return $null }
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

# A message as the commands return it: its metadata, and why the policy withholds its body, if it does, as the check of
# the caller found (Get-WithheldReason). The properties are the same on every server (ThreadId and Labels are $null
# off Gmail), so that the objects export alike.
function ConvertTo-ImapMessage($Session, $Folder, $Summary, [string]$Withheld) {
    $envelope = $Summary.Envelope
    $gmail = Test-GMailServer $Session
    $labels = if ($gmail) { , [string[]]@($Summary.GMailLabels) }
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
        Subject        = $envelope.Subject
        Size           = [long]$Summary.Size
        Flags          = $Summary.Flags
        HasAttachments = @($Summary.Attachments).Count -gt 0
        MessageId      = $envelope.MessageId
        InReplyTo      = $envelope.InReplyTo
        ThreadId       = if ($gmail) { $Summary.GMailThreadId } else { $null }
        Labels         = $labels
        Withheld       = if ($Withheld) { $Withheld } else { $null }
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
