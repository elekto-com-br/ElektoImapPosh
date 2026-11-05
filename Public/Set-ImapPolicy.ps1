<#
.SYNOPSIS
Creates or changes a policy: what the commands of ElektoImapPosh may read from the accounts that follow it.

.DESCRIPTION
A policy is a named set of rules for reading a mailbox, meant above all for its use by AI agents: it
keeps the full text of some messages, and some attachments, from being read by accident, limits how
much one command downloads, and makes the owner's intent explicit. An account follows the policy given
to Set-ImapAccount -Policy (without accounts, the one named by the environment variable IMAP_POLICY),
and several accounts may share one. An account without a policy allows all reading.

The commands that read messages (not in this version yet) follow it. The metadata of every message
(sender, recipients, subject, date, labels, the names and sizes of its attachments) can always be
read; of a message withheld by the policy, only that is shown, and the message says so.

A policy prevents accidents. It is no protection against anyone, an agent included, who can run
commands as the same user: they can change the policy, as they can read the stored passwords.

Senders and attachments are wildcard patterns, read ignoring case. An allow list, when given, withholds
what it does not name; a deny list wins over it. Only the settings given are changed: an empty list or
value removes a setting, and 0 removes a limit. Policies are kept in accounts.json, with the accounts.

.PARAMETER Name
The name of the policy: letters, digits, '.', '-' and '_', starting with a letter or digit.

.PARAMETER DenyFolders
Folders whose messages are listed, with their metadata, but not read nor changed: full names,
special uses (Junk, Trash...) or wildcard patterns, as -Folder of Get-ImapFolder takes them.

.PARAMETER AllowReadFrom
The senders whose messages may be read in full; those of any other sender are withheld. Addresses or
patterns, such as jp@example.com or *@example.com. Since anyone can write any address as the sender,
they match only a sender authenticated by the server named by -TrustAuthenticationResults: without
it, no message is read in full.

.PARAMETER DenyReadFrom
The senders whose messages are withheld, even if -AllowReadFrom names them. Addresses or patterns, as
for -AllowReadFrom, matched against the sender as the message gives it, authenticated or not: a forged
sender here only withholds more.

.PARAMETER AllowAttachmentsFrom
The senders whose attachments may be saved; those of any other sender may not. Matched as
-AllowReadFrom is: authenticated senders only.

.PARAMETER AllowAttachmentTypes
The attachments that may be saved; any other may not. MIME types, with a "/" (application/pdf,
image/*), or file names (*.pdf, *.csv). An attachment matches by its type or by its name.

.PARAMETER DenyAttachmentTypes
The attachments that may not be saved, even if -AllowAttachmentTypes names them, given as for
-AllowAttachmentTypes. An attachment is denied when its type or its name matches: since the sender
chooses both, name here the file names that must never be saved (*.exe).

.PARAMETER MaxAgeDays
How old a message may be, in days: older ones are not searched nor read.

.PARAMETER MaxMessages
How many messages one command may handle.

.PARAMETER MaxMessageSize
The largest message, in bytes (such as 25MB), that may be read in full: of a larger one, only its
metadata is shown.

.PARAMETER MaxAttachmentSize
The largest attachment, in bytes (such as 10MB), that may be saved.

.PARAMETER TrustAuthenticationResults
The receiving server whose Authentication-Results headers tell an authenticated sender: mx.google.com
on Gmail and Google Workspace. A sender is authenticated when the topmost of those headers comes from
that server and says that DMARC passed for the domain of the sender.

.EXAMPLE
Set-ImapPolicy agent -DenyFolders 'Finance/*', Junk -MaxAgeDays 90 -MaxMessages 200 -MaxMessageSize 25MB

Creates the policy "agent": the messages of the folders under Finance and of the junk folder are not
read, nor those older than 90 days, one command handles at most 200 messages, and a message larger
than 25 MB shows only its metadata.

.EXAMPLE
Set-ImapPolicy agent -AllowReadFrom '*@example.com' -TrustAuthenticationResults mx.google.com

Lets the messages of the authenticated senders of example.com be read in full, and withholds the
others.

.EXAMPLE
Set-ImapPolicy agent -DenyAttachmentTypes '*.exe', '*.zip' -MaxAttachmentSize 10MB

Keeps executables, zip files and any attachment larger than 10 MB from being saved.

.EXAMPLE
Set-ImapPolicy agent -MaxMessages 0 -DenyFolders @()

Removes the limit on the number of messages and the folders denied, keeping the other settings.
#>
Function Set-ImapPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        # Options None tells case apart, as the pattern names both: by default it ignores case as the culture does,
        # and took a dotless i in Turkish
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$', Options = 'None')]
        [string]$Name,

        [string[]]$DenyFolders,
        [string[]]$AllowReadFrom,
        [string[]]$DenyReadFrom,
        [string[]]$AllowAttachmentsFrom,
        [string[]]$AllowAttachmentTypes,
        [string[]]$DenyAttachmentTypes,
        [ValidateRange('NonNegative')]
        [int]$MaxAgeDays,
        [ValidateRange('NonNegative')]
        [int]$MaxMessages,
        [ValidateRange('NonNegative')]
        [long]$MaxMessageSize,
        [ValidateRange('NonNegative')]
        [long]$MaxAttachmentSize,
        [string]$TrustAuthenticationResults
    )

    $file = Read-AccountFile
    $policies = if ($file) { $file.Policies } else { [ordered]@{} }

    # An existing policy keeps the spelling of its name
    $existingName = Find-PolicyName $file $Name
    if ($existingName) { $Name = $existingName }
    $settings = [ordered]@{}
    if ($existingName) { foreach ($key in $policies[$Name].Keys) { $settings[$key] = $policies[$Name][$key] } }

    foreach ($key in $script:PolicySettings.Keys) {
        if (-not $PSBoundParameters.ContainsKey($key)) { continue }
        $value = $PSBoundParameters[$key]
        # An empty list or value, or a limit of 0, removes a setting
        $empty = if ($script:PolicySettings[$key] -eq 'Limit') { $value -eq 0 } else { @($value | Where-Object { $_ }).Count -eq 0 }
        if ($empty) { $settings.Remove($key); continue }
        $reason = Get-PolicyValueError $key $value
        if ($reason) { throw "-$key $reason." }
        $settings[$key] = ConvertTo-PolicyValue $key $value
    }

    $allowLists = @('AllowReadFrom', 'AllowAttachmentsFrom' | Where-Object { $settings.Contains($_) })
    if ($allowLists -and -not $settings.Contains('TrustAuthenticationResults')) {
        Write-Warning "Policy '$Name' has no TrustAuthenticationResults, and without it no sender is authenticated, so no sender passes $($allowLists -join ' and '). Give -TrustAuthenticationResults (mx.google.com on Gmail)."
    }

    if (-not $PSCmdlet.ShouldProcess("policy '$Name' in '$(Get-AccountFilePath)'", 'Save')) { return }

    $policies[$Name] = $settings
    $accounts = if ($file) { $file.Accounts } else { [ordered]@{} }
    $defaultName = if ($file) { $file.Default } else { $null }
    Write-AccountFile $defaultName $accounts $policies
    Write-Verbose "Policy '$Name' saved in '$(Get-AccountFilePath)'."
}
