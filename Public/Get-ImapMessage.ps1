<#
.SYNOPSIS
Lists the messages of one or more accounts, with their senders, subjects and dates, without their bodies.

.DESCRIPTION
The `Get-ImapMessage` function searches folders of each account, on the server, and returns the newest
messages that match, with their metadata: sender, recipients, subject, the date the server received
them, size, flags, whether they have attachments (a file attached, or shown in the body with a name of
its own, unless it is an image) and, on Gmail, their thread and labels. It downloads no body and marks
nothing as read.

What the sender writes (the subject, the senders and recipients, the Message-IDs) comes without what
would drive a terminal (an escape sequence), reorder the text (an override of direction) or hide it from
whoever reads it (the tags of Unicode, which an AI reads and a person does not see): each run of such
characters is shown as one U+FFFD, the replacement character, a tab or line break as a space, and the
invisible characters that only change how a text is shown (soft hyphen, zero-width space, marks of
direction) are removed. Each of those texts is cut to 1000 characters, ending in an ellipsis (U+2026), but
for the name of an address, cut on its own to 200, so that the address after it stays whole; and each list
of addresses to its first 100, with a last entry that says how many more there were, such as
"... and 9900 more" (with the ellipsis).

Without -Folder, it searches the inbox, or All Mail with -Query. -First says how many messages of each
folder it returns, the newest first.

When the account follows a policy (Set-ImapAccount -Policy), every message found is still listed, and
the property Withheld says why its body and attachments may not be read; it is empty when they may.
The policy also narrows the search: to the days of its MaxAgeDays, and to the MaxMessages of each
account in a command, with a warning that says how many were left out. It keeps bodies from being
read, not from being searched: the server matches -From, -Subject and -Query against every message,
withheld or not.

.PARAMETER Account
The accounts to read from, kept by Set-ImapAccount: names or wildcard patterns. If not provided,
reads from the default account, if there is one, or else from the IMAP_* environment variables.
Also taken from the pipeline, as the accounts listed by Get-ImapAccount. An account that fails is
reported as an error without stopping the others.

.PARAMETER Folder
The folders to search, instead of the inbox: a special use (Inbox, All, Archive, Drafts, Flagged,
Important, Junk, Sent or Trash), which stands for the folder the server marks so, or else for the
folder of that name; or a full folder name, such as "[Gmail]/Sent Mail" or "Work/Clients", ignoring
case; or a wildcard pattern matched against the full names, where only * and ? are wildcards and
brackets are taken as written, so that "[Gmail]/*" is every system folder of Gmail. A name that matches
no folder is reported as an error, a pattern that matches none is not.
Also taken from the pipeline, as the folders listed by Get-ImapFolder: each is then the folder of that
exact full name, so that a label "Sent" of the user stays that label.

.PARAMETER Since
Only the messages received on this day or later, as the server dates them (the time of day is
ignored). A policy with MaxAgeDays narrows an earlier day to its own, with a warning.

.PARAMETER Unread
Only the messages not yet read.

.PARAMETER From
Only the messages whose sender has this text, such as an address, a domain or a name. The server
compares it, ignoring case.

.PARAMETER Subject
Only the messages whose subject has this text. The server compares it, ignoring case.

.PARAMETER Query
A Gmail search, as typed in the search box of Gmail, such as "from:bank.example has:attachment
newer_than:7d" (sent as X-GM-RAW). Without -Folder, it searches All Mail. Only for servers with the
Gmail extensions, Gmail and Google Workspace; with any other it is an error. It searches the text of
every message of the account, those a policy withholds included: a withheld message that matches is
listed, with its reason in Withheld, and its body stays unread. A policy with DenyQuery refuses it.

.PARAMETER First
How many messages of each folder to return, the newest first. Default is 50. A policy with
MaxMessages lowers it.

.EXAMPLE
Get-ImapMessage

Lists the 50 newest messages in the inbox of the default account.

.EXAMPLE
Get-ImapMessage -Account * -Unread -Since (Get-Date).AddDays(-7)

Lists the unread messages of the last seven days in the inbox of every account.

.EXAMPLE
Get-ImapMessage work -Query 'from:bank.example has:attachment' -First 10

Searches the whole mailbox of the Gmail account "work", and lists the ten newest messages from
bank.example with attachments.

.EXAMPLE
Get-ImapFolder work -Folder 'Clients/*' | Get-ImapMessage -From client.example

Lists the messages from client.example in each folder under "Clients".

.EXAMPLE
Get-ImapMessage | Where-Object Withheld | Select-Object From, Subject, Withheld

Shows which messages of the inbox the policy of the account withholds, and why.
#>
Function Get-ImapMessage {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [Alias('Name')]
        [SupportsWildcards()]
        [string[]]$Account,

        [Parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
        [SupportsWildcards()]
        [string[]]$Folder,

        [datetime]$Since,
        [switch]$Unread,
        [string]$From,
        [string]$Subject,
        [string]$Query,
        [ValidateRange(1, [int]::MaxValue)]
        [int]$First = 50
    )

    begin {
        $sessions = @{}
        # Here, before any input, only what was typed is bound: see Get-ImapFolder
        $folderFromPipeline = -not $PSBoundParameters.ContainsKey('Folder')
        $sinceGiven = $PSBoundParameters.ContainsKey('Since')
    }

    process {
        foreach ($accountName in (Resolve-ImapAccountName $Account)) {
            $session = Get-ImapSession $PSCmdlet $sessions $accountName
            if (-not $session) { continue }
            $settings = $session.Settings
            $policy = $settings.Policy

            if ($Query -and -not (Test-GMailServer $session)) {
                Write-ImapError $PSCmdlet "-Query is a Gmail search, and $($settings.Server) does not offer it (X-GM-EXT-1): use -From, -Subject, -Since and -Unread." 'QueryNotSupported' InvalidOperation $Query
                continue
            }
            # -Query searches the text of every message, those the policy withholds included, and lists the withheld
            # ones that match: the search would tell what the body has. Refused before any folder is opened.
            if ($Query -and $policy -and $policy.DenyQuery) {
                Write-ImapError $PSCmdlet "-Query searches the text of every message, those withheld included, and the policy '$($policy.Name)' of $($settings.User) denies it (DenyQuery): use -From, -Subject, -Since and -Unread." 'QueryNotAllowed' PermissionDenied $Query
                continue
            }

            $folders = Get-ImapFolderList $PSCmdlet $session
            if ($null -eq $folders) { continue }
            $names = if ($Folder) { $Folder } elseif ($Query) { 'All' } else { 'Inbox' }
            $chosen = Select-ImapFolderList $PSCmdlet $session $folders $names -Literal:($folderFromPipeline -and $Folder)

            # A command parameter only narrows the policy: an earlier -Since becomes the first day it allows
            $searchSince = if ($sinceGiven) { $Since } else { $null }
            $start = Get-PolicyStartDate $policy
            if ($start -and -not ($searchSince -and $searchSince.Date -ge $start)) {
                if ($sinceGiven -and -not $session.SinceNarrowed) {
                    Write-Warning "The policy '$($policy.Name)' of $($settings.User) allows only the last $(if ($policy.MaxAgeDays -eq 1) { 'day' } else { "$($policy.MaxAgeDays) days" }): messages received before $($start.ToString('yyyy-MM-dd')) were not searched."
                    $session.SinceNarrowed = $true
                }
                $searchSince = $start
            }
            $search = Get-ImapSearchQuery -Since $searchSince -Unread:$Unread -From $From -Subject $Subject -Query $Query

            foreach ($item in $chosen) {
                if (-not (Open-ImapFolder $PSCmdlet $session $item)) { continue }
                $found = Find-ImapMessage $PSCmdlet $session $item $search
                if ($null -eq $found) { continue }

                # MaxMessages counts the messages of the account over the whole command, in every folder; the warning
                # tells only those that -First would have returned
                $limit = [Math]::Min($First, $found.Count)
                if ($policy -and $policy.MaxMessages) {
                    $left = [Math]::Max(0, $policy.MaxMessages - [int]$session.MessagesHandled)
                    if ($limit -gt $left) {
                        $more = if ($limit - $left -eq 1) { '1 more was' } else { "$($limit - $left) more were" }
                        Write-Warning "The policy '$($policy.Name)' lets one command handle $($policy.MaxMessages) message$(if ($policy.MaxMessages -ne 1) { 's' }) of $($settings.User): of those found in '$($item.FullName)', $more left out."
                        $limit = $left
                    }
                }
                if ($limit -eq 0) { continue }
                $uids = @($found[0..($limit - 1)])
                $session.MessagesHandled = [int]$session.MessagesHandled + $uids.Count

                $summaries = Get-ImapMessageSummary $PSCmdlet $session $item $uids
                if ($null -eq $summaries) { continue }
                foreach ($summary in $summaries) { ConvertTo-ImapMessage $session $item $summary (Get-WithheldReason $session $item $summary) }
            }
        }
    }

    end {
        Close-ImapSession $sessions
    }

    clean {
        Close-ImapSession $sessions -Abort
    }
}
