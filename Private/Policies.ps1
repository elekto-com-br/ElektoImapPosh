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
# a single string. A sender without "@" and a file name such as ".pdf" or "pdf" are refused, as patterns that would
# match nothing: in a deny list, they would let through what was meant to be withheld.
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
    if ($kind -eq 'Senders') {
        $wrong = @($items | Where-Object { $_ -notlike '*@*' })
        if ($wrong.Count) { return "must be a list of addresses or patterns, such as jp@example.com or *@example.com, and '$($wrong[0])' has no @" }
    }
    if ($kind -eq 'Attachments') {
        $wrong = @($items | Where-Object { $_ -notlike '*/*' -and ($_ -like '.*' -or $_ -notmatch '[.*?]') })
        if ($wrong.Count) { return "must be a list of MIME types or file names, such as application/pdf, image/* or *.pdf, not '$($wrong[0])'" }
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
