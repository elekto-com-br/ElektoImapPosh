# Attachments, and the parts shown in the body of a message rather than attached (inline: images pasted or embedded):
# the name a file is saved under, its size before it is fetched, and the saving. The name of a part comes from whoever
# sent the message, so it is never taken as a path, and the policy checks the name the file gets, not the one the
# message gives (Get-AttachmentWithheldReason, in Policies.ps1).

# The name an attachment is saved under. Only the last part of the name the message gives, so that it cannot be
# written elsewhere ("../../x", "C:\x"); without the characters Windows refuses in a file name, control characters,
# and those that reverse the direction of text (they can show "exe.pdf" for "fdp.exe"); without the spaces and dots
# Windows drops at the end ("x.exe." would be saved as "x.exe"); at most 200 bytes of UTF-8, keeping the extension
# (Linux takes 255 bytes in a name, and the number, the UID and the temporary suffix need some); "_" before a name
# Windows keeps for a device (CON, NUL, COM1, COM with a superscript digit...); and "attachment", with the extension of
# its MIME type (attachment.png), when nothing is left. The same on every platform, so that a file saved on Linux
# keeps its name on Windows.
function Get-AttachmentFileName([string]$Name, [string]$ContentType) {
    $leaf = ($Name -split '[\\/]')[-1]
    $leaf = ($leaf -replace '[<>:"|?*\x00-\x1F\x7F\u200E\u200F\u202A-\u202E\u2066-\u2069]', '_').Trim().TrimEnd('.', ' ')
    if ([Text.Encoding]::UTF8.GetByteCount($leaf) -gt 200) {
        $extension = [IO.Path]::GetExtension($leaf)
        if ([Text.Encoding]::UTF8.GetByteCount($extension) -gt 20) { $extension = '' }
        $base = $leaf.Substring(0, $leaf.Length - $extension.Length)
        while ($base -and [Text.Encoding]::UTF8.GetByteCount($base + $extension) -gt 200) {
            $base = $base.Substring(0, $base.Length - 1)
            # Not between the two halves of a character outside the BMP
            if ($base -and [char]::IsHighSurrogate($base[-1])) { $base = $base.Substring(0, $base.Length - 1) }
        }
        # The cut may leave dots or spaces at the end ("x.exe.zzz" cut after "x.exe."), which Windows would drop
        $leaf = ($base + $extension).TrimEnd('.', ' ')
    }
    if ($leaf -match '^(CON|PRN|AUX|NUL|COM[0-9\xB9\xB2\xB3]|LPT[0-9\xB9\xB2\xB3])(\.|$)') { $leaf = "_$leaf" }
    if (-not $leaf) {
        $extension = $null
        if ($ContentType -and [MimeKit.MimeTypes]::TryGetExtension($ContentType, [ref]$extension)) { return "attachment$extension" }
        return 'attachment'
    }
    return $leaf
}

# A file name that $Used does not have yet, which it then gets: the name itself, or, for a name already given to
# another file of the same message, "name (2).ext", "name (3).ext"... Prints pasted in Gmail are all "image.png".
function Get-UniqueFileName([string]$FileName, [System.Collections.Generic.HashSet[string]]$Used) {
    $candidate = $FileName
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $extension = [IO.Path]::GetExtension($FileName)
    for ($number = 2; -not $Used.Add($candidate); $number++) { $candidate = "$base ($number)$extension" }
    return $candidate
}

# The parts of a message that can be saved as files, without fetching them: its attachments, in the order of its
# structure, and then, as Inline, the parts shown in its body rather than attached (images pasted or embedded, which
# the HTML shows by cid:, or with no disposition at all), that are neither text nor a message. Each with the name the
# message gives, the name its file gets (Get-AttachmentFileName; a name repeated in the message numbered by
# Get-UniqueFileName, attachments first, so that each file of a message has a name of its own, the same every time,
# and an attachment keeps its own), the MIME type, the most the file takes (Get-AttachmentSize), why the policy keeps
# it from being saved, if it does, and Part, the part of MailKit, to fetch it. A part that is the same file as another
# is listed all the same: only its content tells (Save-AttachmentFile).
function Get-ImapPartList($Session, $Folder, $Summary) {
    $attachments = @($Summary.BodyParts | Where-Object { $_.IsAttachment })
    $inline = @($Summary.BodyParts | Where-Object { -not $_.IsAttachment -and $_.ContentType.MediaType -notin 'text', 'message' })
    $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    return , [object[]]@(foreach ($part in $attachments + $inline) {
            # In lower case: a part without parameters keeps the case of the server, upper case on Gmail
            $type = $part.ContentType.MimeType.ToLowerInvariant()
            $fileName = Get-UniqueFileName (Get-AttachmentFileName $part.FileName $type) $used
            [PSCustomObject]@{
                Name        = $part.FileName
                FileName    = $fileName
                ContentType = $type
                Size        = Get-AttachmentSize $part
                Inline      = -not $part.IsAttachment
                Withheld    = Get-AttachmentWithheldReason $Session $Folder $Summary $part $fileName
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
# or a message attached (message/rfc822) as it is, which makes an .eml
function Write-AttachmentContent($Entity, [IO.Stream]$Stream) {
    if ($Entity -is [MimeKit.MessagePart]) { $Entity.Message.WriteTo($Stream) }
    else { $Entity.Content.DecodeTo($Stream) }
}

# Saves an attachment of a message in a directory, under $FileName, and returns the file; or $null after reporting why
# not. Fetches that part alone (BODY.PEEK), and writes it under a temporary name in the same directory, which it then
# renames: whoever watches the directory never sees half a file. An existing file is replaced only with -Force.
# A part that is the same file as one saved before from the same message, by the SHA-256 of its content in $Saved, is
# not written again: a message forwarded by Gmail carries an image both shown and attached (JP's NVR, 2026-11-05), and
# Outlook repeats the logos of a signature. A file that exists counts as saved, so that running again gives the same.
function Save-AttachmentFile($Cmdlet, $Session, $Folder, $Summary, $Part, [string]$Directory, [string]$FileName, [System.Collections.Generic.HashSet[string]]$Saved, [switch]$Force) {
    $where = "the message $($Summary.UniqueId.Id) in the folder '$($Folder.FullName)' of $($Session.Settings.User)"
    $shown = if ($Part.FileName) { $Part.FileName } else { $FileName }
    $path = [IO.Path]::Combine($Directory, $FileName)
    if (-not $Force -and ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path))) {
        if ([IO.File]::Exists($path)) { $null = $Saved.Add((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) }
        Write-ImapError $Cmdlet "'$path' already exists, so the part '$shown' of $where was not saved: give -Force to replace the file." 'AttachmentFileExists' ResourceExists $path
        return $null
    }
    $task = $Folder.GetBodyPartAsync($Summary.UniqueId, $Part, [System.Threading.CancellationToken]::None, $null)
    $failure = Wait-ImapTask $task
    if ($failure) {
        Write-ImapError $Cmdlet "Could not fetch the part '$shown' of ${where}: $failure" 'AttachmentFetchFailed' ReadError $shown
        return $null
    }
    # Decoded in memory, where MimeKit already holds the part, to tell a file saved before by its content
    $content = [IO.MemoryStream]::new()
    Write-AttachmentContent $task.Result $content
    if (-not $Saved.Add([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($content.ToArray())))) {
        Write-Verbose "The part '$shown' of $where is the same file as one saved before from it, and was not saved again."
        return $null
    }
    $temporary = "$path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).part"
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $content.Position = 0; $content.CopyTo($stream) } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $path, [bool]$Force)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    # -Force, or a file whose name starts with a dot, hidden on Linux, is not found
    return Get-Item -LiteralPath $path -Force
}
