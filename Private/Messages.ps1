# Messages: how a command finds them, by a SEARCH on the server, and what it fetches of each before the policy decides
# whether its body may be read (Get-WithheldReason, in Policies.ps1). Only metadata is fetched here: the envelope, the
# flags, the size, the date the server received it, the structure of its parts (whether it has attachments), on Gmail
# its thread and labels, and the Authentication-Results headers that tell an authenticated sender. Bodies are fetched
# with BODY.PEEK from folders opened read-only, so nothing is marked as read.

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
# an array; or $null after reporting why not
function Find-ImapMessage($Cmdlet, $Session, $Folder, [MailKit.Search.SearchQuery]$Query) {
    $task = $Folder.SearchAsync($Query, [System.Threading.CancellationToken]::None)
    $failure = Wait-ImapTask $task
    if ($failure) {
        Write-ImapError $Cmdlet "Could not search the folder '$($Folder.FullName)' of $($Session.Settings.User): $failure" 'SearchFailed' ReadError $Folder.FullName
        return $null
    }
    return , @($task.Result | Sort-Object Id -Descending)
}

# The summaries of the messages of an open folder with the UIDs given, the newest first, in an array: their metadata,
# with all that the check of the policy needs; or $null after reporting why not
function Get-ImapMessageSummary($Cmdlet, $Session, $Folder, $Uids) {
    $items = [MailKit.MessageSummaryItems]'UniqueId, Envelope, Flags, InternalDate, Size, BodyStructure'
    if (Test-GMailServer $Session) { $items = $items -bor [MailKit.MessageSummaryItems]'GMailThreadId, GMailLabels' }
    $request = [MailKit.FetchRequest]::new($items)
    $request.Headers = [MailKit.HeaderSet]::new([string[]]@('Authentication-Results'))
    $list = [System.Collections.Generic.List[MailKit.UniqueId]]::new()
    foreach ($uid in $Uids) { $list.Add($uid) }

    $task = $Folder.FetchAsync([System.Collections.Generic.IList[MailKit.UniqueId]]$list, [MailKit.IFetchRequest]$request, [System.Threading.CancellationToken]::None)
    $failure = Wait-ImapTask $task
    if ($failure) {
        Write-ImapError $Cmdlet "Could not read the messages of the folder '$($Folder.FullName)' of $($Session.Settings.User): $failure" 'MessageFetchFailed' ReadError $Folder.FullName
        return $null
    }
    return , @($task.Result | Sort-Object { $_.UniqueId.Id } -Descending)
}

# The addresses of a list as text, each as "Name <address>", or the address alone when it has no name
function Format-ImapAddress($List) {
    return , [string[]]@($List | ForEach-Object {
            if ($_ -is [MimeKit.MailboxAddress] -and $_.Name) { "$($_.Name) <$($_.Address)>" }
            elseif ($_ -is [MimeKit.MailboxAddress]) { $_.Address }
            else { "$_" }
        })
}

# A message as the commands return it: its metadata, and why the policy withholds its body, if it does. The properties
# are the same on every server (ThreadId and Labels are $null off Gmail), so that the objects export alike.
function ConvertTo-ImapMessage($Session, $Folder, $Summary) {
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
        Withheld       = Get-WithheldReason $Session $Folder $Summary
    }
}
