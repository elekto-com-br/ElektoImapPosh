# Attachments, and the parts shown in the body of a message rather than attached (inline: images pasted or embedded):
# the name a file is saved under, its size before it is fetched, and the saving. The name of a part comes from whoever
# sent the message, so it is never taken as a path, and the policy checks the name the file gets, not the one the
# message gives (Get-AttachmentWithheldReason, in Policies.ps1).

# A name from a message as the messages of the module show it: its control characters, which can drive a terminal (an
# escape sequence), and those that reverse the direction of text, as "?"
function Format-ShownName([string]$Name) {
    return $Name -creplace '[\p{Cc}\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]', '?'
}

# The name an attachment is saved under. Only the last part of the name the message gives, so that it cannot be
# written elsewhere ("../../x", "C:\x"); composed (ConvertTo-ComposedText), since macOS takes a name and its decomposed
# form for one file, where Windows and Linux see two; without the characters Windows refuses in a file name, control
# characters, and those that reverse the direction of text (they can show "exe.pdf" for "fdp.exe"); without the spaces
# and dots Windows drops at the end ("x.exe." would be saved as "x.exe"); at most 200 bytes of UTF-8, keeping the
# extension (Linux takes 255 bytes in a name, and the number, the UID and the temporary suffix need some); "_" for the
# "~" of a name shaped as the short name (8.3) Windows gives a long one, since "REPORT~1.PDF" can stand for the
# "report-final.pdf" of the directory, which -Force would replace; "_" before a name Windows keeps for a device (CON,
# NUL, COM1, COM with a superscript digit, CONIN$...), also followed by spaces or an extension ("NUL .txt", which
# Windows 10 reads as NUL); and "attachment", with the extension of its MIME type (attachment.png), when nothing is
# left. The same on every platform, so that a file saved on Linux keeps its name on Windows. The sender writes the
# name, of any length: it is cut in a few steps, not one for each character.
function Get-AttachmentFileName([string]$Name, [string]$ContentType) {
    $leaf = ConvertTo-ComposedText ($Name -csplit '[\\/]')[-1]
    $leaf = ($leaf -creplace '[<>:"|?*\p{Cc}\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]', '_').Trim().TrimEnd('.', ' ')
    if ([Text.Encoding]::UTF8.GetByteCount($leaf) -gt 200) {
        $extension = [IO.Path]::GetExtension($leaf)
        if ([Text.Encoding]::UTF8.GetByteCount($extension) -gt 20) { $extension = '' }
        # A character takes a byte at least, so no more of them than there are bytes of room
        $base = $leaf.Substring(0, [Math]::Min($leaf.Length - $extension.Length, 200 - $extension.Length))
        if ($base -and [char]::IsHighSurrogate($base[-1])) { $base = $base.Substring(0, $base.Length - 1) }
        while ($base -and [Text.Encoding]::UTF8.GetByteCount($base + $extension) -gt 200) {
            $base = $base.Substring(0, $base.Length - 1)
            # Not between the two halves of a character outside the BMP
            if ($base -and [char]::IsHighSurrogate($base[-1])) { $base = $base.Substring(0, $base.Length - 1) }
        }
        # The cut may leave dots or spaces at the end ("x.exe.zzz" cut after "x.exe."), which Windows would drop
        $leaf = ($base + $extension).TrimEnd('.', ' ')
    }
    if ($leaf -cmatch '^(?=[^.]{1,8}(\.[^.]{0,3})?$)[^.]*~\d+(\.|$)') { $leaf = $leaf.Replace('~', '_') }
    # Ignoring case as Windows does, whatever the culture of the session: in Turkish, "i" is not the small "I"
    if ([regex]::IsMatch($leaf, '^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[\d\xB9\xB2\xB3]|LPT[\d\xB9\xB2\xB3]) *(\.|$)', 'IgnoreCase, CultureInvariant')) { $leaf = "_$leaf" }
    if (-not $leaf) {
        $extension = $null
        if ($ContentType -and [MimeKit.MimeTypes]::TryGetExtension($ContentType, [ref]$extension)) { return "attachment$extension" }
        return 'attachment'
    }
    return $leaf
}

# A file name that $Used does not have yet, which it then gets: the name itself, or, for a name already given to
# another file of the same message, "name (2).ext", "name (3).ext"... Prints pasted in Gmail are all "image.png".
# $Used keeps, with each name, the number its next copy tries first: a sender can repeat a name thousands of times,
# and trying every number again for each copy would take the square of that (24 s for 2,000 copies, measured).
function Get-UniqueFileName([string]$FileName, [System.Collections.Generic.Dictionary[string, int]]$Used) {
    if ($Used.TryAdd($FileName, 2)) { return $FileName }
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $extension = [IO.Path]::GetExtension($FileName)
    # A name that only starts with a dot: ".env (2)", not " (2).env"
    if (-not $base) { $base, $extension = $FileName, '' }
    $number = $Used[$FileName]
    do {
        $candidate = "$base ($number)$extension"
        $number++
    } while (-not $Used.TryAdd($candidate, 2))
    $Used[$FileName] = $number
    return $candidate
}

# The parts of a message that can be saved as files, without fetching them: its attachments, in the order of its
# structure, and then, as Inline, the parts shown in its body rather than attached (images pasted or embedded, which
# the HTML shows by cid:, or with no disposition at all), that are neither text nor a message. Each with the name the
# message gives, the name its file gets (Get-AttachmentFileName; a name repeated in the message numbered by
# Get-UniqueFileName, attachments first, so that each file of a message has a name of its own, the same every time,
# and an attachment keeps its own), the MIME type, the most the file takes (Get-AttachmentSize), why the policy keeps
# it from being saved, if it does, and Part, the part of MailKit, to fetch it. The policy takes the name of the file
# and, when a number changes it, the name written too, both having to pass, as with -UniqueName: a second "secret.pdf",
# written as "secret (2).pdf", is a "secret.pdf" all the same. A part that is the same file as another is listed all
# the same: only its content tells (Save-AttachmentFile).
function Get-ImapPartList($Session, $Folder, $Summary) {
    $attachments = @($Summary.BodyParts | Where-Object { $_.IsAttachment })
    $inline = @($Summary.BodyParts | Where-Object { -not $_.IsAttachment -and $_.ContentType.MediaType -notin 'text', 'message' })
    $used = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    return , [object[]]@(foreach ($part in $attachments + $inline) {
            # In lower case: a part without parameters keeps the case of the server, upper case on Gmail
            $type = $part.ContentType.MimeType.ToLowerInvariant()
            $own = Get-AttachmentFileName $part.FileName $type
            $fileName = Get-UniqueFileName $own $used
            $withheld = Get-AttachmentWithheldReason $Session $Folder $Summary $part $own
            if (-not $withheld -and $fileName -cne $own) { $withheld = Get-AttachmentWithheldReason $Session $Folder $Summary $part $fileName }
            [PSCustomObject]@{
                Name        = $part.FileName
                FileName    = $fileName
                ContentType = $type
                Size        = Get-AttachmentSize $part
                Inline      = -not $part.IsAttachment
                Withheld    = $withheld
                Part        = $part
            }
        })
}

# The most an attachment takes once decoded, told from the structure of the message before it is fetched: base64
# writes 3 bytes in 4 characters, and the line breaks it also counts make this an upper bound; the other encodings
# take no less than what they decode to
function Get-AttachmentSize($Part) {
    if ($Part.ContentTransferEncoding -eq 'base64') { return [long][Math]::Ceiling($Part.Octets * 3 / 4) }
    return [long]$Part.Octets
}

# Writes the content of an attachment, as MimeKit fetched it, to a stream: a file decoded (base64, quoted-printable),
# or a message attached that MimeKit parsed, as MimeKit writes it. Save-AttachmentFile fetches a message attached as
# the server keeps it instead, unless it comes encoded, which MimeKit gives as a file.
function Write-AttachmentContent($Entity, [IO.Stream]$Stream) {
    if ($Entity -is [MimeKit.MessagePart]) { $Entity.Message.WriteTo($Stream) }
    else { $Entity.Content.DecodeTo($Stream) }
}

# Writes the content of a file under a temporary name, new (CreateNew) and kept from other programs while it is
# written, and renames it to its path, replacing a file there only when told to; the temporary file is deleted when
# that fails. In a task, so that a failure (a file another program keeps open, a directory that cannot be written, a
# full disk) is the message of the task (Wait-ImapTask), reported once, and not an exception that PowerShell would also
# add to $Error and to the -ErrorVariable of the command. It renames the file only once it takes $commit, a
# TaskCompletionSource that only one side can complete: the command takes it first when it no longer waits for the
# file (Save-AttachmentFile), and the task then deletes the temporary file instead. A delegate compiled from an
# expression tree, since a script block has no runspace to run in on the thread of a task:
#   (content, temporary, path, overwrite, commit) => Task.Run(() => {
#       var stream = File.Open(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None);
#       try {
#           try { content.WriteTo(stream); } finally { stream.Dispose(); }
#           if (commit.TrySetResult(true)) File.Move(temporary, path, overwrite);
#       } finally { if (File.Exists(temporary)) File.Delete(temporary); } })
$script:SaveFileTask = & {
    $E = [System.Linq.Expressions.Expression]
    $content = $E::Parameter([IO.MemoryStream], 'content')
    $temporary = $E::Parameter([string], 'temporary')
    $path = $E::Parameter([string], 'path')
    $overwrite = $E::Parameter([bool], 'overwrite')
    $commit = $E::Parameter([System.Threading.Tasks.TaskCompletionSource[bool]], 'commit')
    $stream = $E::Variable([IO.FileStream], 'stream')
    $file = [IO.File]
    $save = $E::Block(
        [System.Linq.Expressions.ParameterExpression[]]@($stream),
        $E::Assign($stream, $E::Call($file.GetMethod('Open', [type[]]@([string], [IO.FileMode], [IO.FileAccess], [IO.FileShare])),
                [System.Linq.Expressions.Expression[]]@($temporary, $E::Constant([IO.FileMode]::CreateNew), $E::Constant([IO.FileAccess]::Write), $E::Constant([IO.FileShare]::None)))),
        $E::TryFinally(
            $E::Block(
                $E::TryFinally(
                    $E::Call($content, [IO.MemoryStream].GetMethod('WriteTo', [type[]]@([IO.Stream])), [System.Linq.Expressions.Expression[]]@($stream)),
                    $E::Call($stream, [IO.Stream].GetMethod('Dispose', [type[]]@()))),
                $E::IfThen($E::Call($commit, [System.Threading.Tasks.TaskCompletionSource[bool]].GetMethod('TrySetResult', [type[]]@([bool])), [System.Linq.Expressions.Expression[]]@($E::Constant($true))),
                    $E::Call($file.GetMethod('Move', [type[]]@([string], [string], [bool])), [System.Linq.Expressions.Expression[]]@($temporary, $path, $overwrite)))),
            $E::IfThen($E::Call($file.GetMethod('Exists', [type[]]@([string])), $temporary), $E::Call($file.GetMethod('Delete', [type[]]@([string])), $temporary))))
    $run = $E::Call([System.Threading.Tasks.Task].GetMethod('Run', [type[]]@([Action])), $E::Lambda([Action], $save))
    $E::Lambda([Func[IO.MemoryStream, string, string, bool, System.Threading.Tasks.TaskCompletionSource[bool], System.Threading.Tasks.Task]], $run, [System.Linq.Expressions.ParameterExpression[]]@($content, $temporary, $path, $overwrite, $commit)).Compile()
}

# Saves an attachment of a message in a directory, under $FileName, and returns the file; or $null after reporting why
# not, naming the part $Shown (Format-ShownName). Fetches that part alone (BODY.PEEK), and writes it under a temporary
# name in the same directory, which it then renames ($script:SaveFileTask): whoever watches the directory never sees
# half a file under its name. An existing file is replaced only with -Force, and never one the user may not write
# (read-only: Windows would refuse to replace it, and Linux and macOS replace it all the same), nor a directory, told
# before the part is fetched. When the file cannot be written, the one that was there is not returned as if it were
# the attachment.
# A part that is the same file as one saved before from the same message, by the SHA-256 of its content, is not
# written again: a message forwarded by Gmail carries an image both shown and attached (JP's NVR, 2026-11-05), and
# Outlook repeats the logos of a signature. $Saved keeps, for each content, the file that has it. A file that exists
# counts as saved, so that running again gives the same, with a warning, since it may have come from another message;
# one that could not be written does not (Copilot on #13), nor one that exists but cannot be read, of unknown content.
function Save-AttachmentFile($Cmdlet, $Session, $Folder, $Summary, $Part, [string]$Directory, [string]$FileName, [string]$Shown, [System.Collections.Generic.Dictionary[string, object]]$Saved, [switch]$Force) {
    $where = "the message $($Summary.UniqueId.Id) in the folder '$($Folder.FullName)' of $($Session.Settings.User)"
    $path = [IO.Path]::Combine($Directory, $FileName)
    if ([IO.Directory]::Exists($path)) {
        Write-ImapError $Cmdlet "'$path' is a directory, so the part '$Shown' of $where was not saved." 'AttachmentFileExists' ResourceExists $path
        return $null
    }
    # One look at the file, so that one taken away meanwhile raises no exception
    $existing = [IO.FileInfo]::new($path)
    if ($existing.Exists -and ($existing.IsReadOnly -or -not $Force)) {
        # A file that cannot be read, such as one another program keeps open with no sharing, counts for no part, and
        # Get-FileHash adds no error of its own to the one refusal
        $hash = Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Ignore
        if ($hash -and -not $Saved.ContainsKey($hash.Hash)) { $Saved[$hash.Hash] = @{ Path = $path; Before = $true } }
        $how = if ($existing.IsReadOnly) { 'it is read-only, and not even -Force replaces such a file' } else { 'give -Force to replace the file' }
        Write-ImapError $Cmdlet "'$path' already exists, so the part '$Shown' of $where was not saved: $how." 'AttachmentFileExists' ResourceExists $path
        return $null
    }
    # A message attached (message/rfc822, or another message/*) is fetched as the server keeps it, an .eml byte for
    # byte: MimeKit, parsing it, would write its lines with the line ends of the platform, and what is not a message as
    # nothing. Unless it comes encoded (base64, quoted-printable), which MimeKit gives as a file, decoded as any other.
    $asKept = $Part.ContentType.MediaType -eq 'message' -and $Part.ContentTransferEncoding -notin 'base64', 'quoted-printable'
    # A part that is the whole body of the message has no number: its section is TEXT, since BODY[] would carry the
    # headers of the message around it too (Copilot on #13)
    $section = if ($Part.PartSpecifier) { [string]$Part.PartSpecifier } else { 'TEXT' }
    $none = [System.Threading.CancellationToken]::None
    $task = if ($asKept) { $Folder.GetStreamAsync($Summary.UniqueId, $section, $none, $null) } else { $Folder.GetBodyPartAsync($Summary.UniqueId, $Part, $none, $null) }
    $failure = Wait-ImapTask $task
    if ($failure) {
        Write-ImapError $Cmdlet "Could not fetch the part '$Shown' of ${where}: $failure" 'AttachmentFetchFailed' ReadError $Shown
        return $null
    }
    # In memory, where MimeKit already holds the part, to tell a file saved before by its content
    $content = [IO.MemoryStream]::new()
    if ($asKept) {
        $task.Result.CopyTo($content)
        $task.Result.Dispose()
    } else { Write-AttachmentContent $task.Result $content }
    # MaxAttachmentSize was held to the size the server told before the fetch; this is the size of the file itself
    $policy = $Session.Settings.Policy
    if ($policy -and $policy.MaxAttachmentSize -and $content.Length -gt $policy.MaxAttachmentSize) {
        Write-ImapError $Cmdlet "The part '$Shown' of $where was not saved: it has $($content.Length) bytes, more than MaxAttachmentSize of the policy '$($policy.Name)' ($($policy.MaxAttachmentSize)), though the server told of fewer." 'AttachmentWithheld' PermissionDenied $Shown
        return $null
    }
    $content.Position = 0
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([IO.Stream]$content))
    $same = $null
    if ($Saved.TryGetValue($hash, [ref]$same)) {
        if ($same.Before) { Write-Warning "The part '$Shown' of $where was not saved: it is the same file as '$($same.Path)', which was already in the directory." }
        else { Write-Verbose "The part '$Shown' of $where is the same file as '$($same.Path)', saved from it, and was not saved again." }
        return $null
    }
    $temporary = "$path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).part"
    # Ctrl+C stops the wait, not the task, which went on and renamed the file after the command had ended, replacing the
    # one there with -Force (Copilot on #13). Stopped, the command takes $commit before the task can: the task then
    # renames nothing, and deletes the temporary file once written. If the task took it first, it is renaming the file,
    # and the command waits for that, as a finally entered by Ctrl+C runs to its end (measured). The task starts inside
    # the try, so as not to count on where PowerShell notices Ctrl+C
    $commit = [System.Threading.Tasks.TaskCompletionSource[bool]]::new()
    try {
        $task = $script:SaveFileTask.Invoke($content, $temporary, $path, [bool]$Force, $commit)
        $failure = Wait-ImapTask $task
    } finally {
        if (-not $commit.TrySetResult($false)) { $null = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($task)) }
    }
    if ($failure) {
        Write-ImapError $Cmdlet "Could not write '$path', so the part '$Shown' of $where was not saved: $failure" 'AttachmentWriteFailed' WriteError $path
        return $null
    }
    $Saved[$hash] = @{ Path = $path; Before = $false }
    # As PowerShell gives a file, with the PSPath the commands it goes to read; -Force for a name that starts with a dot,
    # hidden on Linux. A program that takes the file away at once, as one that watches the directory may, leaves the
    # FileInfo alone, rather than a second error
    $file = Get-Item -LiteralPath $path -Force -ErrorAction Ignore
    if (-not $file) { $file = [IO.FileInfo]::new($path) }
    return $file
}
