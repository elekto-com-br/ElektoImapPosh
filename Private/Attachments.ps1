# Attachments, and the parts shown in the body of a message rather than attached (inline: images pasted or embedded):
# the name a file is saved under, its size before it is fetched, and the saving. The name of a part comes from whoever
# sent the message, so it is never taken as a path, and the policy checks the name the file gets, not the one the
# message gives (Get-AttachmentWithheldReason, in Policies.ps1). A message saved whole (Save-ImapMessage) is named by
# the same rules, and written the same way: every file the module writes goes through Test-FileTarget, which holds it
# to its directory, and Write-ImapFile.

# The name an attachment is saved under. Only the last part of the name the message gives, so that it cannot be
# written elsewhere ("../../x", "C:\x"); composed (ConvertTo-ComposedText), since macOS takes a name and its decomposed
# form for one file, where Windows and Linux see two; without the characters that change only how it is shown, and
# with "_" for those Windows refuses in a file name and for those that hide, reorder or drive (control characters,
# the overrides of direction that can show "exe.pdf" for "fdp.exe", the tags of Unicode), as Format-ShownText takes
# them out of a text; without the spaces and dots Windows drops at the end ("x.exe." would be saved as "x.exe"); at
# most 200 bytes of UTF-8 before the ".download" of a name the shell acts on, keeping the extension (Linux takes 255
# bytes in a name, and the number, the UID and the temporary suffix need some); "_" for the
# "~" of a name shaped as the short name (8.3) Windows gives a long one, since "REPORT~1.PDF" can stand for the
# "report-final.pdf" of the directory, which -Force would replace; "_" before a name Windows keeps for a device (CON,
# NUL, COM1, COM with a superscript digit, CONIN$...), also followed by spaces or an extension ("NUL .txt", which
# Windows 10 reads as NUL); "attachment", with the extension of its MIME type (attachment.png), when nothing is left;
# and, but with -KeepShellName, a name that the shell of Windows acts on renamed (Get-ShellSafeFileName). The same on
# every platform, so that a file saved on Linux keeps its name on Windows. The sender writes the name, of any length:
# it is cut in a few steps, not one for each character.
function Get-AttachmentFileName([string]$Name, [string]$ContentType, [switch]$KeepShellName) {
    $leaf = ConvertTo-ComposedText ($Name -csplit '[\\/]')[-1]
    $leaf = (($leaf -creplace $script:InvisibleCharacter, '') -creplace ('[<>:"|?*]|' + $script:HiddenCharacter), '_').Trim().TrimEnd('.', ' ')
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
        $leaf = if ($ContentType -and [MimeKit.MimeTypes]::TryGetExtension($ContentType, [ref]$extension)) { "attachment$extension" } else { 'attachment' }
    }
    if ($KeepShellName) { return $leaf }
    return Get-ShellSafeFileName $leaf
}

# The extensions of the files that the shell of Windows shows otherwise than they are, or reads by only showing their
# folder, as a pattern of the end of a name (see Get-ShellSafeFileName)
$script:ShellExtension = '\.(lnk|url|pif|scf|website|appref-ms|library-ms|search-ms|searchconnector-ms|accountpicture-ms|desklink|mapimail|mydocs|zfsendtotarget|(exe|com|scr)\.local|\{[^.]*\})$'

# A file name made safe from the shell of Windows, which acts on some names by their look alone, whatever the Mark of
# the Web says. Explorer hides the extension of some types even when it shows the others (NeverShowExt in the
# registry: .lnk, .url, .pif, .scf, .website, .library-ms, .search-ms, .searchConnector-ms and a few more, measured on
# Windows 11), so "invoice.pdf.lnk" shows as "invoice.pdf", with the icon the shortcut names, and "invoice.pdf.pif" is
# a program; and it reads some files by only showing their folder: the icon of a shortcut, which can be on a server of
# the sender's, which Windows then logs in to, giving away a hash of the user's password; desktop.ini, which customizes
# its folder; Thumbs.db, its thumbnails. An "app.exe.local" beside app.exe changes where that program loads its
# libraries from (not ".env.local", which no program reads so), and an extension "{CLSID}" shows a file as an object of
# the shell, hiding its type. So such a file gets ".download" after
# its own extension, which Chromium gives such a download in place of its own, and Windows does not know (measured), so
# Explorer shows the whole name: "invoice.pdf.lnk.download". desktop.ini and Thumbs.db get "_" before them, as Chromium
# names them. Ignoring case as Windows does, whatever the culture of the session.
function Get-ShellSafeFileName([string]$Name) {
    if ([regex]::IsMatch($Name, '^(desktop\.ini|thumbs\.db)$', 'IgnoreCase, CultureInvariant')) { return "_$Name" }
    if ([regex]::IsMatch($Name, $script:ShellExtension, 'IgnoreCase, CultureInvariant')) { return "$Name.download" }
    return $Name
}

# The name a message saved whole is written under (Save-ImapMessage): its UID, then its subject, by the rules of the
# name of an attachment (Get-AttachmentFileName), since the sender writes the subject: "12045-Proposal for 2027.eml",
# or "12045.eml" for a message without one. A subject is no path, so a slash in it is a character of the name, as "_",
# rather than the end of a folder ("Invoice 11/2026" would be "2026.eml"), and a run of its tabs and line breaks is a
# space, as Format-ShownText shows them.
function Get-MessageFileName([uint32]$Uid, [string]$Subject) {
    $text = (($Subject -creplace $script:LineBreak, ' ') -creplace '[\\/]', '_').Trim()
    $name = if ($text) { "$Uid-$text.eml" } else { "$Uid.eml" }
    return Get-AttachmentFileName $name 'message/rfc822'
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

# The parts of a message that are files, told from its structure (nothing fetched), each list in the order of the
# message: Attachments, the parts it attaches (Content-Disposition: attachment), and those it shows in its body with
# a name that is not an image's, as Apple Mail sends a PDF, or a client a CSV; and Inline, the other parts it shows in
# its body that are neither text nor a message: images pasted or embedded (by cid: in the HTML), named, as Outlook's
# image001.png, or not, as the photo of a camera, and files without a name. An image shown in the body is no
# attachment even with a name, since most are logos and signatures; a text without a name is the text of the message.
# In one pass over the parts, for every message listed (HasAttachments).
function Get-ImapFilePart($Summary) {
    $attachments = [System.Collections.Generic.List[object]]::new()
    $inline = [System.Collections.Generic.List[object]]::new()
    foreach ($part in $Summary.BodyParts) {
        if ($part.IsAttachment -or ($part.FileName -and $part.ContentType.MediaType -ne 'image')) { $attachments.Add($part) }
        elseif ($part.ContentType.MediaType -notin 'text', 'message') { $inline.Add($part) }
    }
    return @{ Attachments = $attachments; Inline = $inline }
}

# The parts of a message that can be saved as files, without fetching them: its attachments, and then, as Inline, the
# other parts shown in its body (Get-ImapFilePart). Each with the name the message gives (as Format-ShownText shows
# it), the name its file gets (Get-AttachmentFileName; a name repeated in the message numbered by Get-UniqueFileName,
# attachments first, so that each file of a message has a name of its own, the same every time, and an attachment
# keeps its own), the MIME type, the most the file takes (Get-AttachmentSize), why the policy keeps it from being
# saved, if it does, and Part, the part of MailKit, to fetch it. The policy takes the name of the file and, when a
# number changes it, the name written too, both having to pass, as with -UniqueName: a second "secret.pdf", written as
# "secret (2).pdf", is a "secret.pdf" all the same. And so the name before the rename of a name the shell acts on
# (Get-ShellSafeFileName): DenyAttachmentTypes '*.url' withholds "invoice.url", which would be saved as
# "invoice.url.download". A part that is the same file as another is listed all the same: only its content tells
# (Save-AttachmentFile).
function Get-ImapPartList($Session, $Folder, $Summary) {
    $files = Get-ImapFilePart $Summary
    $used = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    return , [object[]]@(foreach ($inline in $false, $true) {
            foreach ($part in $(if ($inline) { $files.Inline } else { $files.Attachments })) {
                # In lower case: a part without parameters keeps the case of the server, upper case on Gmail
                $type = $part.ContentType.MimeType.ToLowerInvariant()
                $plain = Get-AttachmentFileName $part.FileName $type -KeepShellName
                $own = Get-ShellSafeFileName $plain
                $fileName = Get-UniqueFileName $own $used
                $withheld = Get-AttachmentWithheldReason $Session $Folder $Summary $part $own
                if (-not $withheld -and $plain -cne $own) { $withheld = Get-AttachmentWithheldReason $Session $Folder $Summary $part $plain }
                if (-not $withheld -and $fileName -cne $own) { $withheld = Get-AttachmentWithheldReason $Session $Folder $Summary $part $fileName }
                [PSCustomObject]@{
                    Name        = Format-ShownText $part.FileName
                    FileName    = $fileName
                    ContentType = $type
                    Size        = Get-AttachmentSize $part
                    Inline      = $inline
                    Withheld    = $withheld
                    Part        = $part
                }
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
# the server keeps it instead, unless it comes encoded, which MimeKit gives as a file. MimeKit gives a part whose body
# is empty no Content (measured), whose file is then an empty file: before, the call on the Content that was not
# there failed, with an error of PowerShell, and with a try up the stack the whole command ended there (found in the
# review before the first release).
function Write-AttachmentContent($Entity, [IO.Stream]$Stream) {
    if ($Entity -is [MimeKit.MessagePart]) { $Entity.Message.WriteTo($Stream) }
    elseif ($null -ne $Entity.Content) { $Entity.Content.DecodeTo($Stream) }
}

# The Mark of the Web, as Outlook and the browsers write it in the stream Zone.Identifier of a file they save on
# Windows: ZoneId=3 is the zone of the internet, so SmartScreen warns before such a program runs, Office opens such a
# document in Protected View and blocks its macros, and PowerShell under RemoteSigned asks for the signature of such
# a script. A file saved from a message is from the internet; Unblock-File takes the mark off.
$script:MarkOfTheWeb = "[ZoneTransfer]`r`nZoneId=3`r`n"

# Writes the content of a file under a temporary name, new (CreateNew) and kept from other programs while it is
# written, and renames it to its path, replacing a file there only when told to; the temporary file is deleted when
# that fails. In a task, so that a failure (a file another program keeps open, a directory that cannot be written, a
# full disk) is the message of the task (Wait-ImapTask), reported once, and not an exception that PowerShell would also
# add to $Error and to the -ErrorVariable of the command. It renames the file only once it takes $commit, a
# TaskCompletionSource that only one side can complete: the command takes it first when it no longer waits for the
# file (Save-AttachmentFile), and the task then deletes the temporary file instead.
# Before the rename, it writes the Mark of the Web to the stream named by zone (the Zone.Identifier of the temporary
# file on Windows; none, null or empty, elsewhere), which the rename keeps, so that the file is never in its place
# without it. A volume that keeps no streams either refuses it (FAT32 and exFAT take no ":" in a name) or writes it as
# a file of its own, named with the ":" (the share of WSL, measured, and Samba when it maps names). Either way the file
# is saved all the same, and the task gives why it has no mark, or $null: a stream that is still there once the
# temporary file is gone is such a file, and is deleted. A delegate compiled from an expression tree, since a script
# block has no runspace to run in on the thread of a task:
#   (content, temporary, path, overwrite, commit, zone) => Task.Run(() => {
#       string unmarked = null;
#       var stream = File.Open(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None);
#       try {
#           try { content.WriteTo(stream); } finally { stream.Dispose(); }
#           if (!string.IsNullOrEmpty(zone)) {
#               try { File.WriteAllText(zone, MarkOfTheWeb); } catch (Exception refusal) { unmarked = refusal.Message; }
#           }
#           if (commit.TrySetResult(true)) File.Move(temporary, path, overwrite);
#       } finally {
#           if (File.Exists(temporary)) File.Delete(temporary);
#           if (!string.IsNullOrEmpty(zone) && File.Exists(zone)) {
#               File.Delete(zone);
#               unmarked = "it wrote the mark as a file of its own, which was deleted";
#           }
#       }
#       return unmarked; })
$script:SaveFileTask = & {
    $E = [System.Linq.Expressions.Expression]
    $content = $E::Parameter([IO.MemoryStream], 'content')
    $temporary = $E::Parameter([string], 'temporary')
    $path = $E::Parameter([string], 'path')
    $overwrite = $E::Parameter([bool], 'overwrite')
    $commit = $E::Parameter([System.Threading.Tasks.TaskCompletionSource[bool]], 'commit')
    $zone = $E::Parameter([string], 'zone')
    $stream = $E::Variable([IO.FileStream], 'stream')
    $unmarked = $E::Variable([string], 'unmarked')
    $refusal = $E::Variable([Exception], 'refusal')
    $file = [IO.File]
    # Empty as well as null: PowerShell passes $null to a parameter of type string as "" (measured on Linux)
    $noZone = $E::Call([string].GetMethod('IsNullOrEmpty', [type[]]@([string])), $zone)
    $mark = $E::IfThen($E::Not($noZone),
        $E::TryCatch(
            $E::Call($file.GetMethod('WriteAllText', [type[]]@([string], [string])), [System.Linq.Expressions.Expression[]]@($zone, $E::Constant($script:MarkOfTheWeb))),
            [System.Linq.Expressions.CatchBlock[]]@($E::Catch($refusal, $E::Block([void], [System.Linq.Expressions.Expression[]]@($E::Assign($unmarked, $E::Property($refusal, 'Message'))))))))
    $save = $E::Block(
        [System.Linq.Expressions.ParameterExpression[]]@($stream, $unmarked),
        $E::Assign($stream, $E::Call($file.GetMethod('Open', [type[]]@([string], [IO.FileMode], [IO.FileAccess], [IO.FileShare])),
                [System.Linq.Expressions.Expression[]]@($temporary, $E::Constant([IO.FileMode]::CreateNew), $E::Constant([IO.FileAccess]::Write), $E::Constant([IO.FileShare]::None)))),
        $E::TryFinally(
            $E::Block(
                $E::TryFinally(
                    $E::Call($content, [IO.MemoryStream].GetMethod('WriteTo', [type[]]@([IO.Stream])), [System.Linq.Expressions.Expression[]]@($stream)),
                    $E::Call($stream, [IO.Stream].GetMethod('Dispose', [type[]]@()))),
                $mark,
                $E::IfThen($E::Call($commit, [System.Threading.Tasks.TaskCompletionSource[bool]].GetMethod('TrySetResult', [type[]]@([bool])), [System.Linq.Expressions.Expression[]]@($E::Constant($true))),
                    $E::Call($file.GetMethod('Move', [type[]]@([string], [string], [bool])), [System.Linq.Expressions.Expression[]]@($temporary, $path, $overwrite)))),
            $E::Block(
                $E::IfThen($E::Call($file.GetMethod('Exists', [type[]]@([string])), $temporary), $E::Call($file.GetMethod('Delete', [type[]]@([string])), $temporary)),
                $E::IfThen($E::AndAlso($E::Not($noZone), $E::Call($file.GetMethod('Exists', [type[]]@([string])), $zone)),
                    $E::Block([void], [System.Linq.Expressions.Expression[]]@(
                            $E::Call($file.GetMethod('Delete', [type[]]@([string])), $zone),
                            $E::Assign($unmarked, $E::Constant('it wrote the mark as a file of its own, which was deleted'))))))),
        $unmarked)
    # Task.Run<string>(Func<string>), not its overload for a function that returns a task
    $runOf = [System.Threading.Tasks.Task].GetMethods() | Where-Object {
        $_.Name -eq 'Run' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.GetGenericArguments()[0].IsGenericParameter
    }
    $run = $E::Call($runOf.MakeGenericMethod([string]), $E::Lambda([Func[string]], $save))
    $E::Lambda([Func[IO.MemoryStream, string, string, bool, System.Threading.Tasks.TaskCompletionSource[bool], string, System.Threading.Tasks.Task[string]]], $run, [System.Linq.Expressions.ParameterExpression[]]@($content, $temporary, $path, $overwrite, $commit, $zone)).Compile()
}

# The full path of a file named $FileName in $Directory, or $null when it would not be a file of that very directory.
# The module makes every name it writes safe first (Get-AttachmentFileName), so this refuses none of them: it holds
# whatever a sender or a server may give ("../../x", "C:\x", or "x:y", a stream of another file on Windows) to the
# directory, should a name ever come here otherwise. The directory is resolved the way the path is, from a name that
# is surely of it, so that a root ("C:\", "/") or a share ("\\server\share") is no special case.
function Get-ContainedPath([string]$Directory, [string]$FileName) {
    if (-not $FileName -or $FileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $null }
    $path = [IO.Path]::GetFullPath([IO.Path]::Combine($Directory, $FileName))
    $own = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([IO.Path]::Combine($Directory, 'x')))
    # Ordinal: -ceq takes texts that differ in a format character for the same
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($path), $own, [StringComparison]::Ordinal)) { return $null }
    # Also a name that the system writes otherwise ("a. " is written "a" on Windows), or that names the directory itself
    if (-not [string]::Equals([IO.Path]::GetFileName($path), $FileName, [StringComparison]::Ordinal)) { return $null }
    return $path
}

# The full path where a file named $FileName may be written in $Directory (Get-ContainedPath); or $null after reporting
# why not, naming $What would have been saved ("the part 'x.pdf' of the message 12 in the folder..."), with ErrorIds of
# its $Kind ("Attachment" gives AttachmentFileExists): a directory of that name is never replaced, and a file only with
# -Force, and never one the user may not write (read-only: Windows would refuse to replace it, and Linux and macOS
# replace it all the same), all told before anything is fetched. A file there that is not replaced counts, in $Saved
# when given, for the copies of the same message (see Save-AttachmentFile).
function Test-FileTarget($Cmdlet, [string]$Directory, [string]$FileName, [string]$What, [string]$Kind, [System.Collections.Generic.Dictionary[string, object]]$Saved, [switch]$Force) {
    $path = Get-ContainedPath $Directory $FileName
    if (-not $path) {
        Write-ImapError $Cmdlet "'$(Format-ShownText $FileName)' is not the name of a file in '$Directory', so $What was not saved." 'PathOutsideDirectory' SecurityError $FileName
        return $null
    }
    if ([IO.Directory]::Exists($path)) {
        Write-ImapError $Cmdlet "'$path' is a directory, so $What was not saved." "${Kind}FileExists" ResourceExists $path
        return $null
    }
    # One look at the file, so that one taken away meanwhile raises no exception
    $existing = [IO.FileInfo]::new($path)
    if ($existing.Exists -and ($existing.IsReadOnly -or -not $Force)) {
        # A file that cannot be read, such as one another program keeps open with no sharing, counts for no part, and
        # Get-FileHash adds no error of its own to the one refusal
        if ($null -ne $Saved) {
            $hash = Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Ignore
            if ($hash -and -not $Saved.ContainsKey($hash.Hash)) { $Saved[$hash.Hash] = @{ Path = $path; Before = $true } }
        }
        $how = if ($existing.IsReadOnly) { 'it is read-only, and not even -Force replaces such a file' } else { 'give -Force to replace the file' }
        Write-ImapError $Cmdlet "'$path' already exists, so $What was not saved: $how." "${Kind}FileExists" ResourceExists $path
        return $null
    }
    return $path
}

# Writes $Content to a file at $Path (from Test-FileTarget), in its directory $Directory, and returns the file; or $null
# after reporting why not, naming $What would have been saved, with the ErrorId of its $Kind (AttachmentWriteFailed).
# Under a temporary name in the same directory, which it then renames ($script:SaveFileTask): whoever watches the
# directory never sees half a file under its name. On Windows the file carries the Mark of the Web; where the volume
# keeps none, it is saved without it, and a warning says so once for each directory in $Unmarked. A file there is
# replaced only with -Force. When the file cannot be written, the one that was there is not returned as if written.
function Write-ImapFile($Cmdlet, [IO.MemoryStream]$Content, [string]$Path, [string]$Directory, [string]$What, [string]$Kind, [System.Collections.Generic.HashSet[string]]$Unmarked, [switch]$Force) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).part"
    # The Mark of the Web goes into the stream Zone.Identifier of the temporary file, on Windows only
    $zone = if ($IsWindows) { "${temporary}:Zone.Identifier" } else { $null }
    # Ctrl+C stops the wait, not the task, which went on and renamed the file after the command had ended, replacing the
    # one there with -Force (Copilot on #13). Stopped, the command takes $commit before the task can: the task then
    # renames nothing, and deletes the temporary file once written. If the task took it first, it is renaming the file,
    # and the command waits for that, as a finally entered by Ctrl+C runs to its end (measured). The task starts inside
    # the try, so as not to count on where PowerShell notices Ctrl+C
    $commit = [System.Threading.Tasks.TaskCompletionSource[bool]]::new()
    try {
        $task = $script:SaveFileTask.Invoke($Content, $temporary, $Path, [bool]$Force, $commit, $zone)
        $failure = Wait-ImapTask $task
    } finally {
        if (-not $commit.TrySetResult($false)) { $null = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($task)) }
    }
    if ($failure) {
        Write-ImapError $Cmdlet "Could not write '$Path', so $What was not saved: $failure" "${Kind}WriteFailed" WriteError $Path
        return $null
    }
    # Saved without the mark, where the volume keeps none: said once for each directory, not for each file
    if ($task.Result -and $Unmarked.Add($Directory)) {
        Write-Warning "The files saved in '$Directory' carry no Mark of the Web, which tells Windows that a file came from the internet, since its volume does not keep one (FAT32, exFAT and some network shares do not): $($task.Result)"
    }
    # As PowerShell gives a file, with the PSPath the commands it goes to read; -Force for a name that starts with a dot,
    # hidden on Linux. A program that takes the file away at once, as one that watches the directory may, leaves the
    # FileInfo alone, rather than a second error
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
    if (-not $file) { $file = [IO.FileInfo]::new($Path) }
    return $file
}

# Saves an attachment of a message in a directory, under $FileName, and returns the file; or $null after reporting why
# not, naming the part $Shown (as Format-ShownText shows it). Told before the part is fetched when the file cannot go
# there (Test-FileTarget); then fetches that part alone (BODY.PEEK), and writes it (Write-ImapFile).
# A part that is the same file as one saved before from the same message, by the SHA-256 of its content, is not
# written again: a message forwarded by Gmail carries an image both shown and attached (JP's NVR, 2026-11-05), and
# Outlook repeats the logos of a signature. $Saved keeps, for each content, the file that has it. A file that exists
# counts as saved, so that running again gives the same, with a warning, since it may have come from another message;
# one that could not be written does not (Copilot on #13), nor one that exists but cannot be read, of unknown content.
function Save-AttachmentFile($Cmdlet, $Session, $Folder, $Summary, $Part, [string]$Directory, [string]$FileName, [string]$Shown, [System.Collections.Generic.Dictionary[string, object]]$Saved, [System.Collections.Generic.HashSet[string]]$Unmarked, [switch]$Force) {
    $where = "the message $($Summary.UniqueId.Id) in the folder '$($Folder.FullName)' of $($Session.Settings.User)"
    $what = "the part '$Shown' of $where"
    $path = Test-FileTarget $Cmdlet $Directory $FileName $what 'Attachment' $Saved -Force:$Force
    if (-not $path) { return $null }
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
    # An empty file is no copy of another: every one has the same hash, so the second of two empty files of a message,
    # an export with no rows and an empty log, was not saved
    $hash = $null
    if ($content.Length) {
        $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([IO.Stream]$content))
        $same = $null
        if ($Saved.TryGetValue($hash, [ref]$same)) {
            if ($same.Before) { Write-Warning "The part '$Shown' of $where was not saved: it is the same file as '$($same.Path)', which was already in the directory." }
            else { Write-Verbose "The part '$Shown' of $where is the same file as '$($same.Path)', saved from it, and was not saved again." }
            return $null
        }
    }
    $file = Write-ImapFile $Cmdlet $content $path $Directory $what 'Attachment' $Unmarked -Force:$Force
    if ($null -ne $file -and $hash) { $Saved[$hash] = @{ Path = $path; Before = $false } }
    return $file
}

# Saves a message whole in a directory, under $FileName (Get-MessageFileName), and returns the file; or $null after
# reporting why not. The message as the server keeps it, byte for byte, by BODY.PEEK[] (nothing is marked as read):
# its headers, its text and its attachments, as an .eml, which mail clients open. Told before it is fetched when the
# file cannot go there (Test-FileTarget), and written as an attachment is (Write-ImapFile), with the Mark of the Web on
# Windows. MaxMessageSize was held to the size the server told before the fetch (Get-WithheldReason); this is the
# size of the file itself.
function Save-MessageFile($Cmdlet, $Session, $Folder, $Summary, [string]$Directory, [string]$FileName, [System.Collections.Generic.HashSet[string]]$Unmarked, [switch]$Force) {
    $where = "the message $($Summary.UniqueId.Id) in the folder '$($Folder.FullName)' of $($Session.Settings.User)"
    $path = Test-FileTarget $Cmdlet $Directory $FileName $where 'Message' $null -Force:$Force
    if (-not $path) { return $null }
    $task = $Folder.GetStreamAsync($Summary.UniqueId, [System.Threading.CancellationToken]::None, $null)
    $failure = Wait-ImapTask $task
    if ($failure) {
        Write-ImapError $Cmdlet "Could not fetch ${where}: $failure" 'MessageFetchFailed' ReadError $Summary.UniqueId.Id
        return $null
    }
    $content = [IO.MemoryStream]::new()
    $task.Result.CopyTo($content)
    $task.Result.Dispose()
    $policy = $Session.Settings.Policy
    if ($policy -and $policy.MaxMessageSize -and $content.Length -gt $policy.MaxMessageSize) {
        Write-ImapError $Cmdlet "The message $($Summary.UniqueId.Id) in the folder '$($Folder.FullName)' of $($Session.Settings.User) was not saved: it has $($content.Length) bytes, more than MaxMessageSize of the policy '$($policy.Name)' ($($policy.MaxMessageSize)), though the server told of fewer." 'MessageWithheld' PermissionDenied $Summary.UniqueId.Id
        return $null
    }
    return Write-ImapFile $Cmdlet $content $path $Directory $where 'Message' $Unmarked -Force:$Force
}
