<#
.SYNOPSIS
Reads the text of messages, with their metadata and the list of their attachments.

.DESCRIPTION
The `Read-ImapMessage` function returns the text of each message given, besides what Get-ImapMessage
returns of it: its text/plain part, or, when it has none, its HTML as it is; with -Html, the HTML
part first. The property Format says which one came (Text or Html). The text is decoded (base64 or
quoted-printable, and its character set), but HTML is never converted: whoever wants plain text from
it pipes it to a converter of its own.

Only that part is downloaded, never the attachments, which are listed in Attachments: the name the
message gives, the name of the file Save-ImapAttachment would save (FileName), the type, the most the file
takes (Size), and why the policy keeps it from being saved, if it does (Withheld). A file shown in the body
with a name of its own is an attachment too, unless it is an image (Apple Mail sends a PDF so); the other
parts shown in the body, such as images pasted in it, are listed the same way in InlineParts. The folder
is opened read-only, so nothing is marked as read, and nothing in the message is fetched from the network
(images) nor followed (links).

The text comes as Get-ImapMessage gives the subject, but with its tabs and line breaks, and whole: without
what would drive a terminal (an escape sequence), reorder the text or hide it from whoever reads it (the
tags of Unicode, which an AI reads and a person does not see), each run of them shown as one U+FFFD, the
replacement character; the invisible characters that only change how a text is shown (soft hyphen,
zero-width space, marks of direction) are removed.

When the account follows a policy (Set-ImapAccount -Policy), a message whose body it withholds is not
read: the error MessageWithheld says why, and nothing of the message is downloaded but its metadata.
MaxMessages of the policy limits how many messages of each account one command reads, with a warning
that says how many were left out.

Messages come from the pipeline of Get-ImapMessage, which says where each is: account, folder and UID.
If the folder was numbered anew since then (another UIDVALIDITY), the error UidValidityChanged says
so, rather than read another message with the same number.

.PARAMETER Account
The account to read from, kept by Set-ImapAccount. If not provided, reads from the default account, if
there is one, or else from the IMAP_* environment variables. Also taken from the pipeline.

.PARAMETER Folder
The folder of the messages: a special use (Inbox, All, Sent...), a full folder name or a pattern that
matches one folder only, as Get-ImapMessage takes it. Default is the inbox. Also taken from the
pipeline, as the exact full name of the folder of each message.

.PARAMETER Uid
The UIDs of the messages in the folder, as Get-ImapMessage returns them. Also taken from the pipeline.

.PARAMETER UidValidity
The UIDVALIDITY of the folder when the UIDs were listed, as Get-ImapMessage returns it: when the folder
has another one now, its messages were numbered anew, and they are not read. Also taken from the
pipeline.

.PARAMETER Html
Returns the HTML part of the messages that have one, rather than their plain text.

.PARAMETER MaxLength
The most characters of text to return of each message. A text cut short has the property Truncated.
If not provided, the whole text.

.EXAMPLE
Get-ImapMessage -First 5 | Read-ImapMessage

Reads the five newest messages in the inbox of the default account.

.EXAMPLE
Read-ImapMessage work -Folder Inbox -Uid 12045

Reads the message with the UID 12045 in the inbox of the account "work".

.EXAMPLE
Get-ImapMessage work -From bank.example -Since (Get-Date).Date | Read-ImapMessage | Where-Object Text -Match 'Total: ([\d.,]+)'

Reads today's messages from bank.example, and keeps those whose text has a total.

.EXAMPLE
Get-ImapMessage -Unread | Where-Object { -not $_.Withheld } | Read-ImapMessage -MaxLength 4000

Reads at most 4000 characters of each unread message that the policy of the account allows to be read.

.EXAMPLE
Read-ImapMessage -Uid 12045 -Html | Select-Object -ExpandProperty Text | pandoc -f html -t plain

Reads the HTML of a message and converts it to plain text with pandoc.
#>
Function Read-ImapMessage {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$Account,

        [Parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
        [string]$Folder,

        [Parameter(Mandatory = $true, Position = 2, ValueFromPipelineByPropertyName = $true)]
        [uint32[]]$Uid,

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [uint32]$UidValidity,

        [switch]$Html,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxLength
    )

    begin {
        $sessions = @{}
        # Here, before any input, only what was typed is bound: see Get-ImapFolder
        $folderFromPipeline = -not $PSBoundParameters.ContainsKey('Folder')
    }

    process {
        $session = Get-ImapSession $PSCmdlet $sessions $Account
        if (-not $session) { return }
        $settings = $session.Settings
        $policy = $settings.Policy
        # Once MaxMessages is spent, the messages that come are left out without opening their folder or fetching anything
        if ($policy -and $policy.MaxMessages -and [int]$session.MessagesHandled -ge $policy.MaxMessages) {
            $session.MessagesLeftOut = [int]$session.MessagesLeftOut + $Uid.Count
            return
        }

        $name = if ($Folder) { $Folder } else { 'Inbox' }
        $found = Get-ImapMessageByUid $PSCmdlet $session $name -Literal:($folderFromPipeline -and $Folder) -Uid $Uid -UidValidity $UidValidity
        if (-not $found) { return }
        $item = $found.Folder
        foreach ($id in $Uid) {
            $summary = $found.ByUid[$id]
            if (-not $summary) {
                Write-ImapError $PSCmdlet "There is no message with the UID $id in the folder '$($item.FullName)' of $($settings.User)." 'MessageNotFound' ObjectNotFound $id
                continue
            }
            # The one check of the policy, on the metadata, before the body is fetched
            $reason = Get-WithheldReason $session $item $summary
            if ($reason) {
                Write-ImapError $PSCmdlet "The message $id in the folder '$($item.FullName)' of $($settings.User) was not read: $reason" 'MessageWithheld' PermissionDenied $id
                continue
            }
            # MaxMessages counts the messages of the account read in the whole command
            if ($policy -and $policy.MaxMessages -and [int]$session.MessagesHandled -ge $policy.MaxMessages) {
                $session.MessagesLeftOut = [int]$session.MessagesLeftOut + 1
                continue
            }
            $session.MessagesHandled = [int]$session.MessagesHandled + 1

            $content = Get-ImapMessageText $PSCmdlet $session $item $summary -Html:$Html
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

    end {
        # One warning for each account, however many messages came from the pipeline
        $warned = [System.Collections.Generic.List[object]]::new()
        foreach ($session in @($sessions.psbase.Values)) {
            if (-not $session -or -not $session.MessagesLeftOut -or $warned.Contains($session)) { continue }
            $warned.Add($session)
            $more = if ($session.MessagesLeftOut -eq 1) { '1 more was' } else { "$($session.MessagesLeftOut) more were" }
            $max = $session.Settings.Policy.MaxMessages
            Write-Warning "The policy '$($session.Settings.Policy.Name)' lets one command read $max message$(if ($max -ne 1) { 's' }) of $($session.Settings.User): $more not read."
        }
        Close-ImapSession $sessions
    }

    clean {
        Close-ImapSession $sessions -Abort
    }
}
