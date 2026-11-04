# Folders, and the names that find them. Gmail translates the names of its special folders ("[Gmail]/Sent Mail",
# "[Gmail]/E-mails enviados"), so a folder can also be named by its special use (RFC 6154, or XLIST on older
# servers), which the server marks it with: Inbox, Sent, All, Drafts, Trash, Junk...
# An IMailFolder is an IEnumerable of its messages: written to the pipeline on its own, it is enumerated,
# downloading every message (or failing, when it is not open). So folders go out of a function in an array.

$script:SpecialUseNames = @('Inbox', 'All', 'Archive', 'Drafts', 'Flagged', 'Important', 'Junk', 'Sent', 'Trash')

# The special use of a folder, one of SpecialUseNames, or $null. INBOX is the inbox in any case (RFC 3501).
function Get-SpecialUse($Folder) {
    if ($Folder.FullName -eq 'INBOX' -or $Folder.Attributes.HasFlag([MailKit.FolderAttributes]::Inbox)) { return 'Inbox' }
    foreach ($name in $script:SpecialUseNames) {
        if ($Folder.Attributes.HasFlag([MailKit.FolderAttributes]$name)) { return $name }
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
function Select-ImapFolder($Folders, [string]$Name) {
    if ($script:SpecialUseNames -contains $Name) {
        $special = @($Folders | Where-Object { (Get-SpecialUse $_) -eq $Name })
        if ($special) { return , $special }
    }
    $exact = @($Folders | Where-Object { $_.FullName -eq $Name })
    if ($exact -or -not [WildcardPattern]::ContainsWildcardCharacters($Name)) { return , $exact }
    return , @($Folders | Where-Object { $_.FullName -like $Name })
}

# The folders of the session that can hold messages, in an array, as the server lists them; or $null after
# reporting why not. With StatusItems, their counts come in the listing (one command, with LIST-STATUS).
function Get-ImapFolderList($Cmdlet, $Session, [MailKit.StatusItems]$StatusItems = 'None') {
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
    return , $folders.ToArray()
}
