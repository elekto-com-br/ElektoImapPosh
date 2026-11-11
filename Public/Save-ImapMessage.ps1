<#
.SYNOPSIS
Saves one message whole, as the server keeps it, as an .eml file in a directory.

.DESCRIPTION
The `Save-ImapMessage` function saves a message as the server keeps it, byte for byte (its headers, its text
and its attachments), as an .eml file in the directory of -Path, and returns the file. Mail clients open such
a file, and its headers tell how the message came (Received, Authentication-Results, DKIM-Signature). Nothing
is marked as read. The file is the sender's message as it is: what the other commands keep out of what they
return (the characters that drive a terminal or hide text) stays in it, and only its name is made safe.

It saves one message, and only one: by its UID, or by its Message-ID. When more than one message comes from
the pipeline, or more than one message of the folder has the Message-ID, nothing is saved, and the error
MoreThanOneMessage says so. To save the attachments of many messages, use Save-ImapAttachment; to read their
text, Read-ImapMessage.

The file is named after the UID and the subject of the message ("12045-Proposal for 2027.eml", or "12045.eml"
without a subject), by the rules that make the name of an attachment safe on any platform (see
Save-ImapAttachment), since the sender writes the subject; a slash in the subject is "_" ("Invoice 11_2026").
It is written as an attachment is: under a temporary name ending in .part, then renamed, so that whoever
watches the directory never sees half a file; on Windows, with the Mark of the Web, which tells Windows and
the programs that read it that the file came from the internet (Unblock-File takes the mark off), and on
Linux and macOS with no mark. A file that
already exists is not replaced, unless -Force is given; a directory of that name never is, nor a read-only
file. Ctrl+C while the file is written stops the command without saving the file or replacing the one there.

When the account follows a policy (Set-ImapAccount -Policy), the message is saved only when the policy lets it
be read, and lets every one of its parts be saved, attachments and inline parts alike, as Save-ImapAttachment
-Inline would save them: the file carries them all. Otherwise nothing is downloaded, and the error
MessageWithheld says why. MaxMessageSize holds the message before it is downloaded, by the size the server
tells, and after, by its own. A search by Message-ID, as every search, finds only the messages of the days
that MaxAgeDays allows.

.PARAMETER Account
The account to read from, kept by Set-ImapAccount. If not provided, reads from the default account, if there
is one, or else from the IMAP_* environment variables. Also taken from the pipeline.

.PARAMETER Folder
The folder of the message: a special use (Inbox, All, Sent...), a full folder name or a pattern that matches
one folder only. Default is the inbox; on Gmail, All holds every message but those in the trash and the spam.
Also taken from the pipeline, as the exact full name of the folder of the message.

.PARAMETER Uid
The UID of the message in the folder, as Get-ImapMessage returns it. Also taken from the pipeline.

.PARAMETER UidValidity
The UIDVALIDITY of the folder when the UID was listed, as Get-ImapMessage returns it: when the folder has
another one now, its messages were numbered anew, and nothing is saved. Also taken from the pipeline.

.PARAMETER MessageId
The Message-ID of the message, with or without its angle brackets, as Get-ImapMessage returns it in MessageId:
only a message whose Message-ID is exactly this one is saved, and none when more than one message of the
folder has it. Give it whole: the server finds the messages with the text in their Message-ID, and when more
than 100 have it, as for a part of one, nothing is saved.

.PARAMETER Path
The directory where the file is saved. It must exist.

.PARAMETER Force
Replaces a file of that name that already exists, but never a directory, nor a read-only file.

.EXAMPLE
Save-ImapMessage work -Uid 12045 -Path .

Saves the message with the UID 12045 in the inbox of the account "work" in the current directory, as
12045-<its subject>.eml.

.EXAMPLE
Get-ImapMessage work -From bank.example -First 1 | Save-ImapMessage -Path ~/Evidence

Saves the newest message from bank.example in the inbox, headers and all, in the directory Evidence of the
home directory.

.EXAMPLE
Save-ImapMessage work -Folder All -MessageId CAF8kLm1x@mail.gmail.com -Path ./Messages

Saves the message with that Message-ID, wherever it is in the Gmail mailbox of the account "work". The
Message-ID may be given with or without its angle brackets.

.EXAMPLE
Save-ImapMessage -Uid 12045 -Path ./Messages -WhatIf

Shows the file that the message with the UID 12045 in the inbox would be saved as, without downloading it.
#>
Function Save-ImapMessage {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Uid')]
    param (
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$Account,

        [Parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
        [string]$Folder,

        [Parameter(Mandatory = $true, Position = 2, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'Uid')]
        [uint32]$Uid,

        [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'Uid')]
        [uint32]$UidValidity,

        # Something besides the angle brackets, which would find every message by a search for nothing
        [Parameter(Mandatory = $true, ParameterSetName = 'MessageId')]
        [ValidatePattern('[^<>\s]', Options = 'None')]
        [string]$MessageId,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$Force
    )

    begin {
        $sessions = @{}
        # What comes, typed or from the pipeline, is kept until the end: one message is saved, and only when one came
        $given = [System.Collections.Generic.List[hashtable]]::new()
        # Here, before any input, only what was typed is bound: see Get-ImapFolder
        $folderFromPipeline = -not $PSBoundParameters.ContainsKey('Folder')
        $byMessageId = $PSCmdlet.ParameterSetName -eq 'MessageId'
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "There is no directory '$Path' to save the message in: create it first." }
        $provider = $drive = $null
        $directory = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
        # The path of another provider (HKCU:\Software) would be read by .NET as relative to the directory of the process
        if ($provider.Name -ne 'FileSystem') { throw "'$Path' is not a directory of the file system, so no message can be saved in it." }
    }

    process {
        $given.Add(@{ Account = $Account; Folder = $Folder; Uid = $Uid; UidValidity = $UidValidity })
    }

    end {
        # In a script block of its own, which a step that fails leaves, so that the connection is closed after it all the same
        & {
            if ($given.Count -gt 1) {
                Write-ImapError $PSCmdlet "Save-ImapMessage saves one message, and $($given.Count) came, so none was saved: Save-ImapAttachment saves the attachments of many, and Read-ImapMessage reads their text." 'MoreThanOneMessage' InvalidArgument $given.Count
                return
            }
            if ($given.Count -eq 0) { return }
            $one = $given[0]
            $session = Get-ImapSession $PSCmdlet $sessions $one.Account
            if (-not $session) { return }
            $settings = $session.Settings
            $folderName = if ($one.Folder) { $one.Folder } else { 'Inbox' }
            $literal = $folderFromPipeline -and $one.Folder
            if ($byMessageId) {
                $found = Find-ImapMessageById $PSCmdlet $session $folderName -Literal:$literal $MessageId
                if (-not $found) { return }
                $item = $found.Folder
                $summary = $found.Summary
            } else {
                $found = Get-ImapMessageByUid $PSCmdlet $session $folderName -Literal:$literal -Uid $one.Uid -UidValidity $one.UidValidity
                if (-not $found) { return }
                $item = $found.Folder
                $summary = $found.ByUid[$one.Uid]
                if (-not $summary) {
                    Write-ImapError $PSCmdlet "There is no message with the UID $($one.Uid) in the folder '$($item.FullName)' of $($settings.User)." 'MessageNotFound' ObjectNotFound $one.Uid
                    return
                }
            }
            $id = $summary.UniqueId.Id
            $where = "message $id in the folder '$($item.FullName)' of $($settings.User)"

            # The one check of the policy, on the metadata, before anything is downloaded: the message may be read, and
            # every part it carries may be saved. MaxMessages is 1 at least, and this command handles one message.
            $reason = Get-WithheldReason $session $item $summary
            if ($reason) {
                Write-ImapError $PSCmdlet "The $where was not saved: $reason" 'MessageWithheld' PermissionDenied $id
                return
            }
            # Assigned first: Get-ImapPartList gives its list as one object, which a pipeline would not enumerate
            $parts = Get-ImapPartList $session $item $summary
            $withheld = @($parts | Where-Object { $_.Withheld })
            if ($withheld.Count) {
                $part = $withheld[0]
                $what = if ($part.Inline) { 'inline part' } else { 'attachment' }
                $shown = if ($part.Name) { $part.Name } else { $part.FileName }
                $more = if ($withheld.Count -gt 1) { " Of its other parts, $($withheld.Count - 1) may not be saved either." }
                Write-ImapError $PSCmdlet "The $where was not saved, since its $what '$shown' may not be saved: $($part.Withheld)$more" 'MessageWithheld' PermissionDenied $id
                return
            }

            $fileName = Get-MessageFileName $id $summary.Envelope.Subject
            if (-not $PSCmdlet.ShouldProcess([IO.Path]::Combine($directory, $fileName), "Save the $where")) { return }
            $unmarked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $file = Save-MessageFile $PSCmdlet $session $item $summary $directory $fileName $unmarked -Force:$Force
            if (-not $file) { return }
            $file | Add-Member -NotePropertyMembers ([ordered]@{
                    Account = $settings.Account
                    Folder  = $item.FullName
                    Uid     = $id
                }) -PassThru
        }
        Close-ImapSession $sessions
    }

    clean {
        Close-ImapSession $sessions -Abort
    }
}
