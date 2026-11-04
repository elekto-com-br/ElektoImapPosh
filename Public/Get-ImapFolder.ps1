<#
.SYNOPSIS
Lists the folders of one or more accounts, with how many messages each holds and how many are unread.

.DESCRIPTION
The `Get-ImapFolder` function connects to each account and returns its folders that can hold
messages, with their special use (Inbox, Sent, All, Drafts, Trash, Junk...), the number of
messages and the number of unread ones. It only reads: nothing is marked as read.

Gmail translates the names of its special folders ("[Gmail]/Sent Mail" in English), so the
special use is the name that works in any language, with -Folder of this and the other commands.

The objects returned take the pipeline to the other commands, which read from the same account
and folder.

.PARAMETER Account
The accounts to read from, kept by Set-ImapAccount: names or wildcard patterns. If not provided,
reads from the default account, if there is one, or else from the IMAP_* environment variables.
Also taken from the pipeline, as the accounts listed by Get-ImapAccount. An account that fails is
reported as an error without stopping the others.

.PARAMETER Folder
The folders to show, instead of all of them: a special use (Inbox, All, Archive, Drafts, Flagged,
Important, Junk, Sent or Trash), which stands for the folder the server marks so, or else for the
folder of that name; or a full folder name, such as "[Gmail]/Sent Mail" or "Work/Clients",
ignoring case; or a wildcard pattern matched against the full names. A name that matches no folder
is reported as an error.
Also taken from the pipeline, as the folders listed by Get-ImapFolder: each is then the folder of
that exact full name, so that a label "Sent" of the user stays that label.

.EXAMPLE
Get-ImapFolder

Lists the folders of the default account.

.EXAMPLE
Get-ImapFolder -Account * -Folder Inbox

Shows how many messages, and how many unread, the inbox of every account holds.

.EXAMPLE
Get-ImapFolder work | Where-Object Unread -gt 0

Lists the folders of the account "work" that have unread messages.
#>
Function Get-ImapFolder {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [Alias('Name')]
        [SupportsWildcards()]
        [string[]]$Account,

        [Parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
        [SupportsWildcards()]
        [string[]]$Folder
    )

    begin {
        $sessions = @{}
        $statusItems = [MailKit.StatusItems]'Count, Unread'
        # Here, before any input, only what was typed is bound; a -Folder typed is never replaced by the
        # pipeline, so one that was not typed comes from the pipeline, with the exact name of a folder
        $folderFromPipeline = -not $PSBoundParameters.ContainsKey('Folder')
    }

    process {
        foreach ($accountName in (Resolve-ImapAccountName $Account)) {
            $session = Get-ImapSession $PSCmdlet $sessions $accountName
            if (-not $session) { continue }
            $settings = $session.Settings

            # Without -Folder, the counts come with the listing; with it, only for the folders chosen
            $folders = Get-ImapFolderList $PSCmdlet $session $(if (-not $Folder) { $statusItems } else { 'None' })
            if ($null -eq $folders) { continue }

            $chosen = $folders
            if ($Folder) { $chosen = Select-ImapFolderList $PSCmdlet $session $folders $Folder -Literal:$folderFromPipeline }

            foreach ($item in $chosen) {
                if ($Folder) {
                    $failure = Wait-ImapTask ($item.StatusAsync($statusItems, [System.Threading.CancellationToken]::None))
                    if ($failure) {
                        Write-ImapError $PSCmdlet "Could not read the folder '$($item.FullName)' of $($settings.User): $failure" 'FolderStatusFailed' ReadError $item.FullName
                        continue
                    }
                }
                [PSCustomObject]@{
                    PSTypeName = 'ElektoImapPosh.Folder'
                    Account    = $settings.Account
                    Folder     = $item.FullName
                    SpecialUse = Get-SpecialUse $item
                    Count      = $item.Count
                    Unread     = $item.Unread
                }
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
