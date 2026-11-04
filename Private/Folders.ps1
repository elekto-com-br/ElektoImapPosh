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

# Opens a folder to read its messages: read-only, by EXAMINE, so the server itself refuses any change to the
# mailbox, flags included, whatever a command asks of it (RFC 3501; MailKit also refuses to send one), and a
# message read is not marked as read. Only a command that writes opens it with -ForWrite (SELECT), and only on
# an account that allows it (AllowWrite, or IMAP_ALLOW_WRITE). Returns $true, or $false after reporting why
# not. A connection has one folder open at a time: opening another closes the one before.
function Open-ImapFolder($Cmdlet, $Session, $Folder, [switch]$ForWrite) {
    $settings = $Session.Settings
    if ($ForWrite -and -not $settings.AllowWrite) {
        $how = if ($settings.Account) { "Set-ImapAccount $($settings.Account) -AllowWrite" } else { 'the environment variable IMAP_ALLOW_WRITE=true' }
        Write-ImapError $Cmdlet "Changes are not allowed in the mailbox of $($settings.User), so '$($Folder.FullName)' was left as it is. To allow them: $how." 'WriteNotAllowed' PermissionDenied $Folder.FullName
        return $false
    }
    $access = if ($ForWrite) { [MailKit.FolderAccess]::ReadWrite } else { [MailKit.FolderAccess]::ReadOnly }
    if ($Folder.IsOpen -and $Folder.Access -eq $access) { return $true }
    $failure = Wait-ImapTask ($Folder.OpenAsync($access, [System.Threading.CancellationToken]::None))
    if ($failure) {
        Write-ImapError $Cmdlet "Could not open the folder '$($Folder.FullName)' of $($settings.User): $failure" 'FolderOpenFailed' ReadError $Folder.FullName
        return $false
    }
    return $true
}
