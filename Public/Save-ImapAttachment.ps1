<#
.SYNOPSIS
Saves the attachments of messages as files in a directory.

.DESCRIPTION
The `Save-ImapAttachment` function saves the attachments of each message given, decoded, as files in the
directory of -Path, and returns the files. Only the attachments are downloaded, one part at a time, never the
text of the message; nothing is marked as read.

With -Inline, it also saves the parts shown in the body of a message rather than attached: images pasted in
it (prints sent by clients), or embedded by its HTML, and photos of cameras that send them so. They are left
out without it, since most messages carry logos and signatures that way. -ContentType picks the parts by
their MIME type: -Inline -ContentType image/* saves the images of a message, embedded or attached.

The name of an attachment comes from whoever sent the message, so the file gets a name that is safe on any
platform: only the last part of the name (never a path, so "../../x" is saved as "x" in -Path), in the
composed form of Unicode (NFC), without the characters Windows refuses, nor control characters, nor the
dots and spaces Windows drops at the end ("x.exe." is saved as "x.exe"), nor characters that reverse the
direction of text; with "_" before a name Windows keeps for a device ("_CON.txt", "_NUL .txt"), and for
the "~" of a name shaped as the short name Windows gives a long one ("REPORT~1.PDF" is saved as
"REPORT_1.PDF", since it could stand for another file of the directory). A part without a name is
"attachment", with the extension of its type ("attachment.png"). A name that comes more than once in a
message is numbered, attachments first, then inline parts: Gmail names every print pasted in a message
"image.png", saved as "image.png", "image (2).png"... A part whose content is the same as one saved before
from the same message, as a message forwarded by Gmail carries an image both shown and attached, or as
Outlook repeats the logos of a signature, is not saved again: -Verbose says so, and a warning when the file
with that content was already in the directory. Read-ImapMessage shows the name of each file as the
FileName of each attachment and inline part. -UniqueName puts the UID of the message before it
("12045-image.png"), so that the files of several messages do not take each other's names. A message
attached is saved as the server keeps it, an .eml.

A file that already exists is not replaced, unless -Force is given; a directory of that name never is, nor
a read-only file, nor a file this command saved, -Force or not, so that two messages that give the same
name do not lose one of them. The sender picks the names, so give -Force only for a directory of their
own: in a directory of scripts, or in the home directory, an attachment could replace a script or a
profile. Each file is written under a temporary name ending in .part and then renamed, so whoever watches
the directory never sees half a file under its name. Ctrl+C while a file is written stops the command
without saving that file or replacing the one there; the temporary file is deleted once written. A file
that cannot be written, such as one another program keeps open, is the error AttachmentWriteFailed: only
the files written are returned.

When the account follows a policy (Set-ImapAccount -Policy), the attachments of a message whose body it
withholds are not saved (the error MessageWithheld says why), and each attachment must also pass the rules
of the policy on attachments: AllowAttachmentsFrom (an authenticated sender, or the user's own message),
DenyAttachmentTypes and AllowAttachmentTypes (by MIME type, as the sender declares it, or by file name), and
MaxAttachmentSize, checked before anything is downloaded. The rules on names take the name the file gets
and, when a number or -UniqueName changes it, the name written too: both must pass. An attachment withheld
is the error AttachmentWithheld, which says why. The rules see each file as a whole: a message attached
(.eml) carries the body and the attachments of another message, whatever its sender, and a zip file other
files. MaxMessages limits how many messages of each account one command handles, with a warning that says
how many were left out.

.PARAMETER Account
The account to read from, kept by Set-ImapAccount. If not provided, reads from the default account, if there
is one, or else from the IMAP_* environment variables. Also taken from the pipeline.

.PARAMETER Folder
The folder of the messages: a special use (Inbox, All, Sent...), a full folder name or a pattern that matches
one folder only. Default is the inbox. Also taken from the pipeline, as the exact full name of the folder of
each message.

.PARAMETER Uid
The UIDs of the messages in the folder, as Get-ImapMessage returns them. Also taken from the pipeline.

.PARAMETER UidValidity
The UIDVALIDITY of the folder when the UIDs were listed, as Get-ImapMessage returns it: when the folder has
another one now, its messages were numbered anew, and nothing is saved. Also taken from the pipeline.

.PARAMETER Path
The directory where the files are saved. It must exist.

.PARAMETER Name
Only the attachments with these names: the name the message gives or the name of the file, or wildcard
patterns, such as *.pdf. If not provided, every attachment.

.PARAMETER ContentType
Only the attachments of these MIME types, or wildcard patterns, such as image/* or application/pdf. The type
is the one the sender declares. If not provided, every type.

.PARAMETER Inline
Also saves the parts shown in the body of a message rather than attached, such as images pasted in it.

.PARAMETER UniqueName
Puts the UID of the message before the name of each file ("12045-image.png"), so that files of the same
name in several messages, such as the prints of Gmail or the photos of a camera, do not take each other's
names. A UID is unique in its folder only: for messages of several folders or accounts, give each folder a
-Path of its own.

.PARAMETER Force
Replaces the files that already exist, but never a directory, nor a read-only file, nor a file this command
saved from another message.

.EXAMPLE
Get-ImapMessage -From bank.example -Since (Get-Date).Date | Save-ImapAttachment -Path ~/Statements -Name *.pdf

Saves the PDF attachments of today's messages from bank.example in the directory Statements of the home directory.

.EXAMPLE
Save-ImapAttachment work -Folder Inbox -Uid 12045 -Path .

Saves every attachment of the message with the UID 12045 in the inbox of the account "work" in the current
directory.

.EXAMPLE
Get-ImapMessage work -From client.example -Since (Get-Date).Date | Save-ImapAttachment -Path ./Prints -Inline -ContentType image/* -UniqueName

Saves the images of today's messages from client.example, the prints pasted in them included, each file
named after the UID of its message.

.EXAMPLE
Get-ImapMessage -Unread | Save-ImapAttachment -Path ./Incoming -WhatIf

Shows which attachments of the unread messages in the inbox would be saved, and where, without saving them.

.EXAMPLE
Get-ImapMessage work -From reports@client.example -First 1 | Save-ImapAttachment -Path ./Reports -Name CPTO.xlsx -Force | ForEach-Object { ./Import-Report.ps1 $_.FullName }

Saves the file CPTO.xlsx of the newest message from reports@client.example, replacing the one saved before,
and passes it to a script.
#>
Function Save-ImapAttachment {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$Account,

        [Parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
        [string]$Folder,

        [Parameter(Mandatory = $true, Position = 2, ValueFromPipelineByPropertyName = $true)]
        [uint32[]]$Uid,

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [uint32]$UidValidity,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        # A pattern that is not valid is refused here, rather than stop the command at the first attachment
        [SupportsWildcards()]
        [ValidateScript({ Assert-WildcardPattern $_; $true })]
        [string[]]$Name,

        [SupportsWildcards()]
        [ValidateScript({ Assert-WildcardPattern $_; $true })]
        [string[]]$ContentType,

        [switch]$Inline,
        [switch]$UniqueName,
        [switch]$Force
    )

    begin {
        $sessions = @{}
        # The files this command saved, which it never replaces: UIDs are per folder, so messages of other folders can
        # give the same name, -UniqueName or not
        $written = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        # Here, before any input, only what was typed is bound: see Get-ImapFolder
        $folderFromPipeline = -not $PSBoundParameters.ContainsKey('Folder')
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "There is no directory '$Path' to save the attachments in: create it first." }
        $provider = $drive = $null
        $directory = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
        # The path of another provider (HKCU:\Software) would be read by .NET as relative to the directory of the process
        if ($provider.Name -ne 'FileSystem') { throw "'$Path' is not a directory of the file system, so no attachment can be saved in it." }
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

        $folderName = if ($Folder) { $Folder } else { 'Inbox' }
        $found = Get-ImapMessageByUid $PSCmdlet $session $folderName -Literal:($folderFromPipeline -and $Folder) -Uid $Uid -UidValidity $UidValidity
        if (-not $found) { return }
        $item = $found.Folder
        foreach ($id in $Uid) {
            $summary = $found.ByUid[$id]
            $where = "the message $id in the folder '$($item.FullName)' of $($settings.User)"
            if (-not $summary) {
                Write-ImapError $PSCmdlet "There is no message with the UID $id in the folder '$($item.FullName)' of $($settings.User)." 'MessageNotFound' ObjectNotFound $id
                continue
            }
            # A message given twice (-Uid 12, 12) is saved once. Kept for each session: two accounts may give the same
            # user, folder, UIDVALIDITY and UID on two servers (Copilot on #13)
            if (-not $session.ContainsKey('MessagesSeen')) { $session.MessagesSeen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
            if (-not $session.MessagesSeen.Add("$($item.FullName)`n$($item.UidValidity)`n$id")) {
                Write-Verbose "$where was given more than once: its attachments are saved once."
                continue
            }
            # The one check of the policy, on the metadata, before an attachment is fetched
            $reason = Get-WithheldReason $session $item $summary
            if ($reason) {
                Write-ImapError $PSCmdlet "The attachments of $where were not saved: $reason" 'MessageWithheld' PermissionDenied $id
                continue
            }
            # MaxMessages counts the messages of the account handled in the whole command
            if ($policy -and $policy.MaxMessages -and [int]$session.MessagesHandled -ge $policy.MaxMessages) {
                $session.MessagesLeftOut = [int]$session.MessagesLeftOut + 1
                continue
            }
            $session.MessagesHandled = [int]$session.MessagesHandled + 1

            $parts = @(foreach ($candidate in (Get-ImapPartList $session $item $summary)) {
                    if ($candidate.Inline -and -not $Inline) { continue }
                    if ($Name -and -not @($Name | Where-Object { (Test-Wildcard $candidate.Name $_) -or (Test-Wildcard $candidate.FileName $_) }).Count) { continue }
                    if ($ContentType -and -not @($ContentType | Where-Object { Test-Wildcard $candidate.ContentType $_ }).Count) { continue }
                    $candidate
                })
            if ($parts.Count -eq 0) {
                Write-Verbose "$where has no attachment$(if ($Inline) { ' nor inline part' })$(if ($Name -or $ContentType) { ' of those asked for' })."
                continue
            }
            # The files saved from this message, by their content, so that the same file is saved once
            $saved = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            foreach ($attachment in $parts) {
                $what = if ($attachment.Inline) { 'inline part' } else { 'attachment' }
                $shown = Format-ShownName $(if ($attachment.Name) { $attachment.Name } else { $attachment.FileName })
                $fileName = if ($UniqueName) { "$id-$($attachment.FileName)" } else { $attachment.FileName }
                # The policy takes the name of the file, and with -UniqueName both names: the file's own, and the one written
                $why = $attachment.Withheld
                if (-not $why -and $UniqueName) { $why = Get-AttachmentWithheldReason $session $item $summary $attachment.Part $fileName }
                if ($why) {
                    Write-ImapError $PSCmdlet "The $what '$shown' of $where was not saved: $why" 'AttachmentWithheld' PermissionDenied $shown
                    continue
                }
                $target = [IO.Path]::Combine($directory, $fileName)
                if ($written.Contains($target)) {
                    Write-ImapError $PSCmdlet "'$target' was saved by this command from another message, so the $what '$shown' of $where was not saved: UIDs are unique only in a folder, so give the messages of each folder a -Path of their own." 'AttachmentFileExists' ResourceExists $target
                    continue
                }
                if (-not $PSCmdlet.ShouldProcess($target, "Save the $what '$shown' of $where")) { continue }
                $file = Save-AttachmentFile $PSCmdlet $session $item $summary $attachment.Part $directory $fileName $shown $saved -Force:$Force
                if (-not $file) { continue }
                $null = $written.Add($target)
                $file | Add-Member -NotePropertyMembers ([ordered]@{
                        Account    = $settings.Account
                        Folder     = $item.FullName
                        Uid        = $id
                        Attachment = $attachment.Name
                        Inline     = $attachment.Inline
                    }) -PassThru
            }
        }
    }

    end {
        # One warning for each account, however many messages came from the pipeline
        $warned = [System.Collections.Generic.List[object]]::new()
        foreach ($session in @($sessions.psbase.Values)) {
            if (-not $session -or -not $session.MessagesLeftOut -or $warned.Contains($session)) { continue }
            $warned.Add($session)
            $max = $session.Settings.Policy.MaxMessages
            $more = if ($session.MessagesLeftOut -eq 1) { '1 more was' } else { "$($session.MessagesLeftOut) more were" }
            Write-Warning "The policy '$($session.Settings.Policy.Name)' lets one command handle $max message$(if ($max -ne 1) { 's' }) of $($session.Settings.User): $more left out, and their attachments not saved."
        }
        Close-ImapSession $sessions
    }

    clean {
        Close-ImapSession $sessions -Abort
    }
}
