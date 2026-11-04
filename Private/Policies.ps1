# Policies: what may be read from the accounts that follow them, meant above all for their use by agents. A policy
# is a named set of rules kept in accounts.json apart from the accounts (Policies); an account follows the one its
# setting Policy names (without accounts, the one IMAP_POLICY names), and several accounts may share one. An
# account without a policy allows all reading; writing still needs AllowWrite, which is of the account.
# A policy prevents accidents, such as an agent reading in full what it should not, and makes the owner's intent
# explicit. It is no protection against whoever runs commands as the same user, who can change it. The metadata of
# a message (headers, subject, labels, the names and sizes of its attachments) is always readable.
# The rules, for the commands that read messages (DenyFolders also for those that change them):
# - DenyFolders: folders whose messages are listed but not read nor changed (names, special uses or patterns, as
#   -Folder takes them, see Select-ImapFolder)
# - AllowReadFrom, DenyReadFrom: the senders whose full messages may be read, or not
# - AllowAttachmentsFrom: the senders whose attachments may be saved
# - AllowAttachmentTypes, DenyAttachmentTypes: the attachments that may be saved, or not
# - MaxAgeDays: older messages are not searched
# - MaxMessages, MaxMessageSize, MaxAttachmentSize: limits per command, so nothing large is downloaded by accident
# - TrustAuthenticationResults: the receiving server whose Authentication-Results headers tell an authenticated
#   sender. The allow lists of senders match only authenticated senders; the deny lists match the From as written,
#   since a forged From there only withholds more.
# An allow list, when present, denies what it does not name; a deny list wins. Senders and attachments are wildcard
# patterns, ignoring case: senders such as *@example.com, attachments a MIME type when they have a "/" (image/*) and
# a file name otherwise (*.pdf). Sizes are in bytes.
# Every command that reads messages makes one check, Get-WithheldReason, on the metadata of each message, before its
# body or an attachment is fetched: a message withheld is still listed, saying why. On Gmail a message is in every
# folder its labels name (All Mail holds them all), so a label that names a denied folder withholds it too. Messages
# in the sent folder are the user's own and have no Authentication-Results: they count as authenticated.

# Each setting of a policy, in the order of the file, with its kind of value
$script:PolicySettings = [ordered]@{
    DenyFolders                = 'Folders'
    AllowReadFrom              = 'Senders'
    DenyReadFrom               = 'Senders'
    AllowAttachmentsFrom       = 'Senders'
    AllowAttachmentTypes       = 'Attachments'
    DenyAttachmentTypes        = 'Attachments'
    MaxAgeDays                 = 'Limit'
    MaxMessages                = 'Limit'
    MaxMessageSize             = 'Limit'
    MaxAttachmentSize          = 'Limit'
    TrustAuthenticationResults = 'Server'
}

# Why a value cannot be the setting of a policy, to follow its name in a message; $null when it can. A list may be
# a single string. A pattern that -like cannot read ("report[12") is refused here, rather than fail when applied.
# So are a sender without "@" and a bare extension as a file name (".pdf", "pdf"), patterns that would match
# nothing or a file of that very name only: in a deny list, they would let through what was meant to be withheld.
# "*.pdf" matches a file named ".pdf" too, so nothing is lost.
function Get-PolicyValueError([string]$Setting, $Value) {
    $kind = $script:PolicySettings[$Setting]
    if ($kind -eq 'Limit') {
        if (($Value -is [int] -or $Value -is [long]) -and $Value -ge 1) { return $null }
        return 'must be a whole number above 0'
    }
    if ($kind -eq 'Server') {
        if ($Value -is [string] -and $Value -match '^[^\s@/]+$') { return $null }
        return 'must be the name of the receiving server that adds the Authentication-Results headers, such as mx.google.com'
    }
    $items = @($Value)
    $wrong = @($items | Where-Object { $_ -isnot [string] -or -not $_.Trim() })
    if ($null -eq $Value -or $items.Count -eq 0 -or $wrong.Count) {
        $what = @{ Folders = 'folder names or patterns'; Senders = 'addresses or patterns, such as *@example.com'; Attachments = 'MIME types or file names, such as application/pdf, image/* or *.pdf' }[$kind]
        return "must be a non-empty list of $what, with no empty entries"
    }
    $wrong = @($items | Where-Object { try { $null = '' -like $_; $false } catch { $true } })
    if ($wrong.Count) { return "has '$($wrong[0])', which is not a valid wildcard pattern" }
    if ($kind -eq 'Senders') {
        $wrong = @($items | Where-Object { $_ -notlike '*@*' })
        if ($wrong.Count) { return "must be a list of addresses or patterns, such as jp@example.com or *@example.com, and '$($wrong[0])' has no @" }
    }
    if ($kind -eq 'Attachments') {
        $wrong = @($items | Where-Object { $_ -notlike '*/*' -and $_ -match '^\.?[^.]+$' -and -not [WildcardPattern]::ContainsWildcardCharacters($_) })
        if ($wrong.Count) { return "must be a list of MIME types or file names, such as application/pdf, image/* or *.pdf, and '$($wrong[0])' would match only a file of that very name: for the extension, write *.$($wrong[0].TrimStart('.'))" }
    }
    return $null
}

# A setting of a policy as it is kept: a list of strings, a number, or a string
function ConvertTo-PolicyValue([string]$Setting, $Value) {
    switch ($script:PolicySettings[$Setting]) {
        'Limit' { return [long]$Value }
        'Server' { return [string]$Value }
        default { return , [string[]]@($Value) }
    }
}

# Reads the Policies of the accounts file into an ordered dictionary, name -> settings, looked up ignoring case as
# the accounts are; throws when they are not valid
function Read-PolicyList($Policies, [string]$Path) {
    $list = [ordered]@{}
    if ($null -eq $Policies) { return $list }
    if ($Policies -isnot [System.Collections.IDictionary]) { throw "'Policies' in '$Path' must be a JSON object." }
    foreach ($entry in $Policies.GetEnumerator()) {
        $name = $entry.Key
        if ($name -notmatch $script:AccountNamePattern) {
            throw "Invalid policy name '$name' in '$Path': use letters, digits, '.', '-' and '_', starting with a letter or digit."
        }
        $sameName = @($list.psbase.Keys | Where-Object { $_ -eq $name })
        if ($sameName) { throw "The policies '$($sameName[0])' and '$name' in '$Path' differ only in case, which makes them the same policy: rename or remove one." }
        if ($entry.Value -isnot [System.Collections.IDictionary]) { throw "Policy '$name' in '$Path' must be a JSON object." }

        $settings = [ordered]@{}
        foreach ($setting in $entry.Value.GetEnumerator()) {
            $key = $script:PolicySettings.Keys | Where-Object { $_ -eq $setting.Key }
            if (-not $key) {
                throw "Unknown setting '$($setting.Key)' in policy '$name' of '$Path'. Settings: $($script:PolicySettings.Keys -join ', ')."
            }
            if ($settings.Contains($key)) { throw "The setting '$key' is twice in policy '$name' of '$Path', in different case." }
            $reason = Get-PolicyValueError $key $setting.Value
            if ($reason) { throw "$key of policy '$name' in '$Path' $reason." }
            $settings[$key] = ConvertTo-PolicyValue $key $setting.Value
        }
        $list[$name] = $settings
    }
    return $list
}

# The name of a policy as the file spells it, or $null when the file has no such policy
function Find-PolicyName($File, [string]$Name) {
    if (-not $File -or -not $Name) { return $null }
    return @($File.Policies.psbase.Keys | Where-Object { $_ -eq $Name })[0]
}

# The accounts of the file that follow a policy
function Get-PolicyAccount($File, [string]$Name) {
    return , @($File.Accounts.psbase.Keys | Where-Object { $File.Accounts[$_].Policy -eq $Name })
}

# The Gmail system labels (X-GM-LABELS), and the special uses of the folders they stand for
$script:SystemLabels = @{
    '\Inbox' = 'Inbox'; '\Sent' = 'Sent'; '\Draft' = 'Drafts'; '\Drafts' = 'Drafts'; '\Important' = 'Important'
    '\Starred' = 'Flagged'; '\Flagged' = 'Flagged'; '\Spam' = 'Junk'; '\Junk' = 'Junk'; '\Trash' = 'Trash'
}

# The first day whose messages a policy lets the commands search and read (MaxAgeDays), or $null without that limit
function Get-PolicyStartDate($Policy) {
    if (-not $Policy -or -not $Policy.MaxAgeDays) { return $null }
    return [datetime]::Today.AddDays(-$Policy.MaxAgeDays)
}

# The full names of the folders a Gmail label stands for, as the listing spells them: a system label, the folder of its
# special use; any other, the folder of that name, ignoring case
function Get-LabelFolder($Folders, [string]$Label) {
    $use = $script:SystemLabels[$Label]
    $found = if ($use) { Select-ImapFolder $Folders $use } else { , @($Folders | Where-Object { $_.FullName -eq $Label }) }
    return , [string[]]@($found | ForEach-Object { $_.FullName })
}

# The folders of a session that its policy names, found once in its listing, as sets of full names as it spells them:
# Denied, those of DenyFolders (as -Folder takes them), and Sent, the sent folder, whose messages are the user's own
function Get-PolicyFolderSet($Session) {
    if ($Session.PolicyFolders) { return $Session.PolicyFolders }
    # Without the listing, DenyFolders would find no folder, and withhold nothing
    if (-not $Session.ContainsKey('Folders')) { throw 'The folders of the mailbox must be listed before its policy is applied.' }
    $denied = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($pattern in $Session.Settings.Policy.DenyFolders) {
        foreach ($folder in (Select-ImapFolder $Session.Folders $pattern)) { $null = $denied.Add($folder.FullName) }
    }
    $sent = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($folder in (Select-ImapFolder $Session.Folders 'Sent')) { $null = $sent.Add($folder.FullName) }
    $Session.PolicyFolders = @{ Denied = $denied; Sent = $sent }
    return $Session.PolicyFolders
}

# Whether the receiving server named by a policy (TrustAuthenticationResults) authenticated the sender of a message:
# the topmost Authentication-Results header, which the receiving server adds above any that came with the message, is
# from that server and says that DMARC passed for the domain of the From. A message with more than one sender in its
# From, or none, has no sender to authenticate.
function Test-AuthenticatedSender($Summary, [string]$Server) {
    $senders = @($Summary.Envelope.From.Mailboxes)
    if (-not $Server -or $senders.Count -ne 1) { return $false }
    $header = @($Summary.Headers | Where-Object { $_.Field -eq 'Authentication-Results' })[0]
    $results = $null
    if (-not $header -or -not [MimeKit.Cryptography.AuthenticationResults]::TryParse($header.RawValue, [ref]$results)) { return $false }
    if ($results.AuthenticationServiceIdentifier -ne $Server) { return $false }
    foreach ($result in $results.Results) {
        if ($result.Method -ne 'dmarc' -or $result.Result -ne 'pass') { continue }
        $domains = @($result.Properties | Where-Object { $_.PropertyType -eq 'header' -and $_.Property -eq 'from' } | ForEach-Object { $_.Value })
        if ($domains -contains $senders[0].Domain) { return $true }
    }
    return $false
}

# Why the policy of a session withholds the body and the attachments of a message, in a sentence, or $null when it does
# not. The one check for every command that reads messages, made on the summary that Get-ImapMessageSummary fetches,
# before the body or an attachment is; $Folder is the folder the message was read from. Fails closed: a message whose
# date or size is unknown is withheld by a limit on them.
function Get-WithheldReason($Session, $Folder, $Summary) {
    $policy = $Session.Settings.Policy
    if (-not $policy) { return $null }
    $of = "of the policy '$($policy.Name)'"
    $places = Get-PolicyFolderSet $Session

    if ($places.Denied.Contains($Folder.FullName)) { return "The folder '$($Folder.FullName)' is in DenyFolders $of." }
    $own = $places.Sent.Contains($Folder.FullName)
    foreach ($label in $Summary.GMailLabels) {
        foreach ($name in (Get-LabelFolder $Session.Folders $label)) {
            if ($places.Denied.Contains($name)) { return "It has the label '$label', and the folder '$name' is in DenyFolders $of." }
            if ($places.Sent.Contains($name)) { $own = $true }
        }
    }

    $start = Get-PolicyStartDate $policy
    if ($start -and -not ($Summary.InternalDate -and $Summary.InternalDate.LocalDateTime -ge $start)) {
        return "It was received before $($start.ToString('yyyy-MM-dd')), and MaxAgeDays $of is $($policy.MaxAgeDays)."
    }
    if ($policy.MaxMessageSize -and -not ($null -ne $Summary.Size -and $Summary.Size -le $policy.MaxMessageSize)) {
        return "It has $($Summary.Size) bytes, more than MaxMessageSize $of ($($policy.MaxMessageSize))."
    }

    $senders = @($Summary.Envelope.From.Mailboxes | ForEach-Object { $_.Address })
    foreach ($pattern in $policy.DenyReadFrom) {
        $match = @($senders | Where-Object { $_ -like $pattern })
        if ($match.Count) { return "The sender $($match[0]) matches '$pattern' in DenyReadFrom $of." }
    }
    if ($policy.AllowReadFrom) {
        $server = $policy.TrustAuthenticationResults
        if (-not $own -and -not (Test-AuthenticatedSender $Summary $server)) {
            if (-not $server) { return "AllowReadFrom $of passes only authenticated senders, and the policy has no TrustAuthenticationResults to authenticate them." }
            return "The sender is not authenticated by $server (no DMARC pass for the domain of the From), and AllowReadFrom $of passes only authenticated senders."
        }
        if ($senders.Count -eq 0) { return "It has no sender, and AllowReadFrom $of passes only the senders it names." }
        $outside = @($senders | Where-Object { $address = $_; -not @($policy.AllowReadFrom | Where-Object { $address -like $_ }).Count })
        if ($outside.Count) { return "The sender $($outside[0]) is not in AllowReadFrom $of." }
    }
    return $null
}

# Adds to the settings of a connection the policy named by its account (or by IMAP_POLICY, without one) as Policy:
# its settings, and its Name; $null without one. Reports an error of the command and returns $null when there is no
# such policy: reading without it would read what it withholds.
function Add-ImapPolicy($Cmdlet, $File, $Settings, [string]$Name) {
    $Settings.Policy = $null
    if (-not $Name) { return $Settings }
    $policyName = Find-PolicyName $File $Name
    if (-not $policyName) {
        $namedBy, $how = if ($Settings.Account) { "the account '$($Settings.Account)'", "give the account another policy (Set-ImapAccount $($Settings.Account) -Policy <name>, or '' for none)" }
        else { 'the environment variable IMAP_POLICY', 'change IMAP_POLICY' }
        Write-ImapError $Cmdlet "There is no policy '$Name' (named by $namedBy) in '$(Get-AccountFilePath)', so nothing is read: create it with Set-ImapPolicy, or $how." 'PolicyNotFound' ObjectNotFound $Name
        return $null
    }
    $Settings.Policy = [ordered]@{ Name = $policyName }
    foreach ($key in $File.Policies[$policyName].Keys) { $Settings.Policy[$key] = $File.Policies[$policyName][$key] }
    return $Settings
}
