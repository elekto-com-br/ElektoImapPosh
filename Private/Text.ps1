# Text compared alike in every culture and in every form of Unicode. PowerShell compares text as the culture of the
# session does: -like, -match, -replace and -split ignore case as it does, and in Turkish "I" is not the capital of
# "i", so "*@client.example" missed "X@CLIENT.EXAMPLE" in a deny list of senders, and "inbox/*" the folder
# "INBOX/Invoices" (measured in a session in tr-TR), as switch -Wildcard and -Regex, Where-Object -Like, Select-String,
# Sort-Object -Unique, Group-Object and ToLower do. And a name may come written composed or decomposed (NFD), as macOS
# writes names. So every match of a pattern goes through Test-Wildcard, and every check of one through
# Assert-WildcardPattern; elsewhere the module uses only the forms that tell case apart (-cmatch, -creplace, -csplit),
# which no culture changes. Tests/Text.Tests.ps1 reads the code of the module and fails on any other.
# Names that a sender can write and a policy goes by (a domain) are compared by Test-SameText, character by character.
# Below them, how the module shows a text that comes in a message (Format-ShownText).

# Text in the composed form of Unicode (NFC), so that a name written decomposed (NFD), as macOS writes names, is the
# same name. A lone surrogate, which Normalize refuses and each file system writes its own way, becomes "_".
function ConvertTo-ComposedText([string]$Text) {
    return ($Text -creplace '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]', '_').Normalize([Text.NormalizationForm]::FormC)
}

# Whether a text matches a wildcard pattern, ignoring case alike in every culture, with both composed: WildcardPattern
# compares a pattern with wildcards character by character, so one with a wildcard before an accented letter missed a
# folder whose name came decomposed (measured). Composing both costs some 20 us a match (from 28 to 49 us, measured).
function Test-Wildcard([string]$Text, [string]$Pattern) {
    return [WildcardPattern]::new((ConvertTo-ComposedText $Pattern), [System.Management.Automation.WildcardOptions]'IgnoreCase, CultureInvariant').IsMatch((ConvertTo-ComposedText $Text))
}

# Whether two texts are the same, ignoring case alike in every culture, both composed, and otherwise character by
# character: -eq, -ceq and -contains compare as a reader would, ignoring format characters, so that 'client.example'
# -eq "cli<U+202E>ent.example" is true, as with a soft hyphen or a zero-width space in it (measured), and a domain a
# sender wrote so passed for another in the check of a relay (Get-RelayedSender, found by a test of Format-ShownText).
# For the names a policy goes by that a sender can write: domains, and the receiving server.
function Test-SameText([string]$A, [string]$B) {
    return [string]::Equals((ConvertTo-ComposedText $A), (ConvertTo-ComposedText $B), [StringComparison]::OrdinalIgnoreCase)
}

# Whether a domain is another, or one of its subdomains, compared as Test-SameText compares them: news.client.example
# is within client.example, and evilclient.example is not. For the results of the receiving server, which name the
# domain whose DMARC record it applied: Gmail writes header.from=example.com for a sender at news.example.com (measured
# on a real Gmail, 2026-11-07, for every sender of a subdomain in the inbox measured).
function Test-WithinDomain([string]$Domain, [string]$Parent) {
    $Domain = ConvertTo-ComposedText $Domain
    $Parent = ConvertTo-ComposedText $Parent
    if (-not $Domain -or -not $Parent) { return $false }
    return [string]::Equals($Domain, $Parent, [StringComparison]::OrdinalIgnoreCase) -or $Domain.EndsWith(".$Parent", [StringComparison]::OrdinalIgnoreCase)
}

# Throws when a pattern is not a valid wildcard pattern ("report[12"), so that it is refused where it is given rather
# than where it is applied, with the message of PowerShell itself: -like only reads the pattern here, matching nothing,
# where a method of .NET would wrap the message ('Exception calling "IsMatch"...', measured). Checked composed, as
# Test-Wildcard matches it: composing changes some characters (U+232A is U+3009 composed), so a range taken here as
# written failed once composed when applied, and another refused here would have matched (Copilot on #14, measured).
function Assert-WildcardPattern([string]$Pattern) {
    $null = '' -like (ConvertTo-ComposedText $Pattern)
}

# Text from a message as the module shows it: in what its commands return (subjects, senders and recipients,
# Message-IDs, the names of attachments, the text of a message) and in its messages. Whoever sends a message writes
# that text, and can put in it what drives a terminal (an escape sequence clears the screen, or writes to the
# clipboard), what reorders it (an override of direction shows "fdp.exe" as "exe.pdf"), text that whoever reads it
# does not see and an AI reads all the same (the tags of Unicode), and as much of it as fills the context of an AI.
# Format-ShownText takes that out of a text of one line, Format-ShownBody out of the text of a message, and
# Get-AttachmentFileName the same characters out of the name of a file.

# The most characters of a text from a message that the module shows, and the most addresses of a list (From, To,
# Cc): far more than a person writes, and few enough that the messages of one command do not flood the context of an AI
$script:ShownTextLength = 1000
$script:ShownAddressCount = 100

# Characters that change only how a text is shown, removed: the soft hyphen, the zero-width space, the word joiner
# and the BOM, which split a word unseen, and the marks of direction (ALM, LRM, RLM), which can turn the digits of an
# amount or of a date around
$script:InvisibleCharacter = '[\u00AD\u061C\u200B\u200E\u200F\u2060\uFEFF]'

# A character that hides, reorders or drives, as a pattern: a control character (C0 and C1, ESC among them) or a
# format character of Unicode (Cf: the embeddings, overrides and isolates of direction, the invisible operators, the
# tags U+E0001 and U+E0020 to U+E007F and the other format characters outside the BMP, which a pattern of .NET sees as
# two halves, so they are named here), but for the joiners that emoji and some scripts need (ZWNJ, ZWJ); a half of a
# character without its other half; or variation selectors in a row (one follows a letter or an emoji, and more carry
# hidden data). Tests/Text.Tests.ps1 checks it against every character that .NET knows.
$script:HiddenCharacter = '(?:[\p{Cc}\p{Cf}-[\u200C\u200D]]|\uDB40[\uDC01\uDC20-\uDC7F]|\uD804[\uDCBD\uDCCD]|\uD80D[\uDC30-\uDC3F]|\uD82F[\uDCA0-\uDCA3]|\uD834[\uDD73-\uDD7A]|[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]|(?:[\uFE00-\uFE0F]|\uDB40[\uDD00-\uDDEF]){2,})'
# The same in a text of many lines, whose tabs and line breaks are kept
$script:HiddenInLines = $script:HiddenCharacter.Replace('-[', '-[\t\n\r')
# The tabs and line breaks of a text of one line, a run of which it shows as one space
$script:LineBreak = '[\t\n\v\f\r\u0085\u2028\u2029]+'
# All that Format-ShownText changes, to tell in one look a text that it leaves as it is, as most are. The invisible
# characters are format characters too, which HiddenCharacter already finds; they are named all the same, so that the
# look stays right should the list take another kind
$script:ShownTextChange = [regex]::new("$script:LineBreak|$script:InvisibleCharacter|$script:HiddenCharacter")

# A text from a message as the module shows it, on one line (see above): without the invisible characters, with each
# run of hidden ones as one U+FFFD, the replacement character of Unicode, which says that something was there, and
# with each run of tabs and line breaks as one space; cut, when longer than MaxLength, to MaxLength characters that end
# in an ellipsis (0: never cut). $null stays $null. Several texts, as an array, come back each in its place, in one
# call: a message has a dozen of them, and a call costs more than the work on them (some 20 us untyped, 40 us with a
# typed parameter, measured).
function Format-ShownText($Text, $MaxLength = $script:ShownTextLength) {
    # Most texts are left as they are, which one look at all of them tells: a space between two texts makes no match
    # that neither of them has, and none of them is longer than all of them
    $all = $Text -join ' '
    if (-not ($script:ShownTextChange.IsMatch($all) -or ($MaxLength -and $all.Length -gt $MaxLength))) { return $Text }
    foreach ($each in $Text) {
        if ([string]::IsNullOrEmpty($each) -or -not ($script:ShownTextChange.IsMatch($each) -or ($MaxLength -and $each.Length -gt $MaxLength))) {
            $each
            continue
        }
        $shown = (([string]$each -creplace $script:LineBreak, ' ') -creplace $script:InvisibleCharacter, '') -creplace "$script:HiddenCharacter+", "`u{FFFD}"
        if ($MaxLength -and $shown.Length -gt $MaxLength) {
            # Room for the ellipsis, and not between the two halves of a character outside the BMP
            $length = $MaxLength - 1
            if ($length -gt 0 -and [char]::IsHighSurrogate($shown[$length - 1])) { $length-- }
            $shown = $shown.Substring(0, $length) + "`u{2026}"
        }
        $shown
    }
}

# The text of a message as the module shows it: as Format-ShownText shows a text, but with its tabs and line breaks,
# and whole (Read-ImapMessage cuts it by -MaxLength)
function Format-ShownBody($Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return ([string]$Text -creplace $script:InvisibleCharacter, '') -creplace "$script:HiddenInLines+", "`u{FFFD}"
}
