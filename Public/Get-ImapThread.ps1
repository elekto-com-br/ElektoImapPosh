<#
.SYNOPSIS
Lists the messages of Gmail threads (conversations), with their metadata, without their bodies.

.DESCRIPTION
The `Get-ImapThread` function lists the messages of each thread given, as Gmail groups the messages of a
conversation (X-GM-THRID). It searches All Mail, since a thread spans the inbox, the sent messages and the
labels, and lists the messages the oldest first, as Gmail shows a conversation. Each one comes as
Get-ImapMessage returns it, with its metadata, its labels and its folder (All Mail), so that Read-ImapMessage
reads it and Save-ImapAttachment saves its attachments. It downloads no body and marks nothing as read. Gmail
keeps a conversation to 100 messages, and the messages in the trash or the spam are not in All Mail, so they
are not listed.

Threads are Gmail's, and Google Workspace's: with any other server, the error ThreadNotSupported says so, once
for each account. A thread with no message in All Mail is the error ThreadNotFound.

The threads usually come from Get-ImapMessage, whose messages carry their ThreadId: a thread given more than
once, as by several of its messages, is listed once.

When the account follows a policy (Set-ImapAccount -Policy), every message of the thread is still listed, and
the property Withheld says why its body and attachments may not be read, as Get-ImapMessage says it. The
policy also narrows the search to the days of its MaxAgeDays, and lets one command list the MaxMessages of
each account, the newest of each thread, with a warning that says how many were left out.

.PARAMETER Account
The account to read from, kept by Set-ImapAccount. If not provided, reads from the default account, if there
is one, or else from the IMAP_* environment variables. Also taken from the pipeline.

.PARAMETER ThreadId
The threads, by the ThreadId that Get-ImapMessage returns of each message on Gmail. Also taken from the
pipeline.

.EXAMPLE
Get-ImapMessage work -Subject proposal -First 1 | Get-ImapThread

Lists the whole conversation of the newest message in the inbox whose subject has "proposal", the replies sent
included.

.EXAMPLE
Get-ImapThread work -ThreadId 1849112309876543210 | Read-ImapMessage

Reads every message of the thread, the oldest first.

.EXAMPLE
Get-ImapMessage work -Unread | Get-ImapThread | Where-Object Labels -Contains '\Sent'

Lists the messages you sent in the conversations of the unread messages of the inbox.

.EXAMPLE
Get-ImapThread work -ThreadId 1849112309876543210 | Save-ImapAttachment -Path ./Thread -UniqueName

Saves the attachments of every message of the thread, each file named after the UID of its message.
#>
Function Get-ImapThread {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$Account,

        # Off Gmail, Get-ImapMessage gives no thread: $null is taken, so that the error says why (ThreadNotSupported),
        # where PowerShell would only say that it is null
        [Parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true)]
        [AllowNull()]
        [uint64[]]$ThreadId
    )

    begin {
        $sessions = @{}
    }

    process {
        $session = Get-ImapSession $PSCmdlet $sessions $Account
        if (-not $session) { return }
        $settings = $session.Settings
        $policy = $settings.Policy
        if (-not (Test-GMailServer $session)) {
            # Once for each account, however many messages come from the pipeline
            if (-not $session.ThreadsRefused) {
                $session.ThreadsRefused = $true
                Write-ImapError $PSCmdlet "Threads are Gmail's (X-GM-THRID), and $($settings.Server) does not offer them (X-GM-EXT-1): find the messages of a conversation with Get-ImapMessage -Subject or -From." 'ThreadNotSupported' InvalidOperation $settings.Server
            }
            return
        }
        if ($null -eq $ThreadId) {
            Write-ImapError $PSCmdlet "No ThreadId was given, so no thread of $($settings.User) was listed: Get-ImapMessage gives the ThreadId of each message." 'ThreadNotFound' ObjectNotFound $null
            return
        }
        # The threads not listed yet in this command, told first: the messages of a thread come one by one from the
        # pipeline, and each of them took some 0.4 ms when the folder was looked for before, 0.25 ms so (measured on
        # 10,000 messages of two threads)
        if (-not $session.ContainsKey('ThreadsSeen')) { $session.ThreadsSeen = [System.Collections.Generic.HashSet[uint64]]::new() }
        $new = @(foreach ($id in $ThreadId) {
                if ($session.ThreadsSeen.Add($id)) { $id }
                else { Write-Verbose "The thread $id of $($settings.User) was given more than once: its messages are listed once." }
            })
        if ($new.Count -eq 0) { return }
        $folder = Open-NamedImapFolder $PSCmdlet $session 'All'
        if ($null -eq $folder) { return }
        # MaxAgeDays goes into the search, as in every search
        $start = Get-PolicyStartDate $policy

        foreach ($id in $new) {
            $search = [MailKit.Search.SearchQuery]::GMailThreadId($id)
            if ($start) { $search = $search.And([MailKit.Search.SearchQuery]::DeliveredAfter($start)) }
            $found = Find-ImapMessage $PSCmdlet $session $folder $search
            if ($null -eq $found) { continue }
            if ($found.Count -eq 0) {
                $since = if ($start) { " received since $($start.ToString('yyyy-MM-dd')), the first day that MaxAgeDays of the policy '$($policy.Name)' allows" }
                Write-ImapError $PSCmdlet "There is no message of the thread $id in the folder '$($folder.FullName)' of $($settings.User)$since." 'ThreadNotFound' ObjectNotFound $id
                continue
            }

            # MaxMessages counts the messages of the account over the whole command, and keeps the newest of a thread,
            # as Get-ImapMessage keeps the newest of a folder: the end of a conversation says most of where it stands
            $limit = $found.Count
            if ($policy -and $policy.MaxMessages) {
                $left = [Math]::Max(0, $policy.MaxMessages - [int]$session.MessagesHandled)
                if ($limit -gt $left) {
                    $session.MessagesLeftOut = [int]$session.MessagesLeftOut + $limit - $left
                    $limit = $left
                }
            }
            if ($limit -eq 0) { continue }
            # Found the newest first
            $uids = @($found[0..($limit - 1)])
            $session.MessagesHandled = [int]$session.MessagesHandled + $uids.Count

            $summaries = Get-ImapMessageSummary $PSCmdlet $session $folder $uids
            if ($null -eq $summaries) { continue }
            # The oldest first, as a conversation reads
            for ($index = $summaries.Count - 1; $index -ge 0; $index--) {
                $summary = $summaries[$index]
                ConvertTo-ImapMessage $session $folder $summary (Get-WithheldReason $session $folder $summary)
            }
        }
    }

    end {
        # One warning for each account, however many threads came from the pipeline
        $warned = [System.Collections.Generic.List[object]]::new()
        foreach ($session in @($sessions.psbase.Values)) {
            if (-not $session -or -not $session.MessagesLeftOut -or $warned.Contains($session)) { continue }
            $warned.Add($session)
            $max = $session.Settings.Policy.MaxMessages
            $more = if ($session.MessagesLeftOut -eq 1) { '1 more was' } else { "$($session.MessagesLeftOut) more were" }
            Write-Warning "The policy '$($session.Settings.Policy.Name)' lets one command handle $max message$(if ($max -ne 1) { 's' }) of $($session.Settings.User): of the threads asked for, $more left out."
        }
        Close-ImapSession $sessions
    }

    clean {
        Close-ImapSession $sessions -Abort
    }
}
