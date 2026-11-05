# Folders, and the names that find them. Gmail translates the names of its special folders ("[Gmail]/Sent Mail",
# "[Gmail]/E-mails enviados"), so a folder can also be named by its special use (RFC 6154, or XLIST on older
# servers), which the server marks it with: Inbox, Sent, All, Drafts, Trash, Junk...
# An IMailFolder is an IEnumerable of its messages: written to the pipeline on its own, it is enumerated,
# downloading every message (or failing, when it is not open). So folders go out of a function in an array.

$script:SpecialUseNames = @('Inbox', 'All', 'Archive', 'Drafts', 'Flagged', 'Important', 'Junk', 'Sent', 'Trash')

# Whether the server marks a folder with a special use, one of SpecialUseNames. INBOX is the inbox in any
# case (RFC 3501).
function Test-SpecialUse($Folder, [string]$Name) {
    if ($Name -eq 'Inbox' -and $Folder.FullName -eq 'INBOX') { return $true }
    return $Folder.Attributes.HasFlag([MailKit.FolderAttributes]$Name)
}

# The special use of a folder, or $null. A folder can have more than one (All and Archive, say): this is the
# first in the order of SpecialUseNames, while -Folder finds the folder by any of them.
function Get-SpecialUse($Folder) {
    foreach ($name in $script:SpecialUseNames) {
        if (Test-SpecialUse $Folder $name) { return $name }
    }
    return $null
}

# Whether a folder can hold messages: "[Gmail]", for one, only holds other folders
function Test-SelectableFolder($Folder) {
    return -not ($Folder.Attributes -band ([MailKit.FolderAttributes]::NoSelect -bor [MailKit.FolderAttributes]::NonExistent))
}

# The folders a name given to -Folder stands for, in an array: those the server marks with that special use,
# when it is one and the server marks any; or else the folder of that full name, ignoring case; or else, when
# the name has wildcards, those whose full names match it. The exact name comes first because Gmail's names
# have brackets, which -like reads as a wildcard.
# With -Literal, only the folder of that exact full name: for a name that came from the pipeline, which is the
# full name of a folder the server listed, and may be a label "Sent" on Gmail, which is not its sent folder.
function Select-ImapFolder($Folders, [string]$Name, [switch]$Literal) {
    if ($Literal) { return , @($Folders | Where-Object { $_.FullName -ceq $Name }) }
    if ($script:SpecialUseNames -contains $Name) {
        $special = @($Folders | Where-Object { Test-SpecialUse $_ $Name })
        if ($special) { return , $special }
    }
    $exact = @($Folders | Where-Object { $_.FullName -eq $Name })
    if ($exact -or -not [WildcardPattern]::ContainsWildcardCharacters($Name)) { return , $exact }
    return , @($Folders | Where-Object { $_.FullName -like $Name })
}

# The folders that the names given to -Folder stand for (see Select-ImapFolder), each once, in an array. A name that
# matches no folder is reported (FolderNotFound), and the others go on; a pattern that matches none is no error.
function Select-ImapFolderList($Cmdlet, $Session, $Folders, [string[]]$Names, [switch]$Literal) {
    $chosen = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $Names) {
        $found = Select-ImapFolder $Folders $name -Literal:$Literal
        if ($found.Count -eq 0 -and ($Literal -or -not [WildcardPattern]::ContainsWildcardCharacters($name))) {
            Write-ImapError $Cmdlet "There is no folder '$name' in the mailbox of $($Session.Settings.User). Get-ImapFolder lists them." 'FolderNotFound' ObjectNotFound $name
        }
        foreach ($item in $found) {
            if (-not $chosen.Contains($item)) { $chosen.Add($item) }
        }
    }
    return , $chosen.ToArray()
}

# The folders a name given to -Folder stands for (Select-ImapFolderList), for a command that takes messages from the
# pipeline, each with the name of its folder; or $null when the folders cannot be listed. Found once for each name in
# the session, since a search of the list for each message would take the number of folders times that of the
# messages (3 ms a message with 500 labels). A name that finds no folder is looked for, and reported, again each time.
function Find-ImapFolder($Cmdlet, $Session, [string]$Name, [switch]$Literal) {
    $folders = Get-ImapFolderList $Cmdlet $Session
    if ($null -eq $folders) { return $null }
    if (-not $Session.ContainsKey('FoundFolders')) { $Session.FoundFolders = [System.Collections.Generic.Dictionary[string, object[]]]::new([StringComparer]::Ordinal) }
    $key = "$([int][bool]$Literal)$Name"
    $found = $null
    if ($Session.FoundFolders.TryGetValue($key, [ref]$found)) { return , $found }
    $found = Select-ImapFolderList $Cmdlet $Session $folders $Name -Literal:$Literal
    if ($found.Count) { $Session.FoundFolders[$key] = $found }
    return , $found
}

# The folders of the session that can hold messages, in an array, as the server lists them; or $null after
# reporting why not. With StatusItems, their counts come in the listing (one command, with LIST-STATUS).
# The folders do not change while a command runs, so they are listed once per session, unless the counts are
# wanted with them: a pipeline of folders would otherwise list them all again for each one.
function Get-ImapFolderList($Cmdlet, $Session, [MailKit.StatusItems]$StatusItems = 'None') {
    if ($StatusItems -eq 'None' -and $Session.ContainsKey('Folders')) { return , $Session.Folders }
    Write-Verbose "Listing the folders of $($Session.Settings.User)..."
    $client = $Session.Client
    $folders = [System.Collections.Generic.List[object]]::new()
    foreach ($namespace in $client.PersonalNamespaces) {
        $task = $client.GetFoldersAsync($namespace, $StatusItems, $false, [System.Threading.CancellationToken]::None)
        $failure = Wait-ImapTask $task
        if ($failure) {
            Write-ImapError $Cmdlet "Could not list the folders of $($Session.Settings.User): $failure" 'FolderListFailed' ReadError $Session.Settings.Account
            return $null
        }
        foreach ($folder in $task.Result) {
            if (Test-SelectableFolder $folder) { $folders.Add($folder) }
        }
    }
    $Session.Folders = $folders.ToArray()
    return , $Session.Folders
}

# Whether the account allows changes of a kind (one of WriteKinds) to its mailbox (AllowWrite, or
# IMAP_ALLOW_WRITE); if not, reports so, naming what would have changed and how to allow it. Every command
# that changes the mailbox asks this first, whatever it changes: the read-only opening of Open-ImapFolder
# covers only the messages of the folder opened, while copying them to another folder, creating, renaming or
# deleting folders and adding messages are still possible on the connection.
function Test-ImapWriteAllowed($Cmdlet, $Session, [string]$Kind, [string]$Target) {
    $settings = $Session.Settings
    $allowed = @($settings.AllowWrite)
    if ($allowed -contains 'All' -or $allowed -contains $Kind) { return $true }
    $others = if ($allowed) { " (it allows $($allowed -join ', '))" } else { '' }
    $wanted = @($script:WriteKinds | Where-Object { $allowed -contains $_ -or $_ -eq $Kind }) -join ', '
    $how = if ($settings.Account) { "Set-ImapAccount $($settings.Account) -AllowWrite $wanted" } else { "the environment variable IMAP_ALLOW_WRITE=$($wanted -replace ' ')" }
    Write-ImapError $Cmdlet "Changes of the kind $Kind are not allowed in the mailbox of $($settings.User)$others, so '$Target' was left as it is. To allow them: $how." 'WriteNotAllowed' PermissionDenied $Target
    return $false
}

# Opens a folder to read its messages: read-only, by EXAMINE, so the server itself refuses any change to the
# messages of that folder, flags included, whatever a command asks of it (RFC 3501; MailKit also refuses to
# send one), and a message read is not marked as read. EXAMINE covers that folder only, not the connection:
# see Test-ImapWriteAllowed. Only a command that writes opens a folder with -ForWrite and the kind of change
# it makes (SELECT), and only on an account that allows that kind. Returns $true, or $false after reporting
# why not. A connection has one folder open at a time: opening another closes the one before.
function Open-ImapFolder($Cmdlet, $Session, $Folder, [string]$ForWrite) {
    $settings = $Session.Settings
    if ($ForWrite -and -not (Test-ImapWriteAllowed $Cmdlet $Session $ForWrite $Folder.FullName)) { return $false }
    $access = if ($ForWrite) { [MailKit.FolderAccess]::ReadWrite } else { [MailKit.FolderAccess]::ReadOnly }
    if ($Folder.IsOpen -and $Folder.Access -eq $access) { return $true }
    $failure = Wait-ImapTask ($Folder.OpenAsync($access, [System.Threading.CancellationToken]::None))
    if ($failure) {
        Write-ImapError $Cmdlet "Could not open the folder '$($Folder.FullName)' of $($settings.User): $failure" 'FolderOpenFailed' ReadError $Folder.FullName
        return $false
    }
    return $true
}
