# Text compared alike in every culture and in every form of Unicode. PowerShell compares text as the culture of the
# session does: -like, -match, -replace and -split ignore case as it does, and in Turkish "I" is not the capital of
# "i", so "*@client.example" missed "X@CLIENT.EXAMPLE" in a deny list of senders, and "inbox/*" the folder
# "INBOX/Invoices" (measured in a session in tr-TR), as switch -Wildcard and -Regex, Where-Object -Like, Select-String,
# Sort-Object -Unique, Group-Object and ToLower do. And a name may come written composed or decomposed (NFD), as macOS
# writes names. So every match of a pattern goes through Test-Wildcard, and every check of one through
# Assert-WildcardPattern; elsewhere the module uses only the forms that tell case apart (-cmatch, -creplace, -csplit),
# which no culture changes. Tests/Text.Tests.ps1 reads the code of the module and fails on any other.

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

# Throws when a pattern is not a valid wildcard pattern ("report[12"), so that it is refused where it is given rather
# than where it is applied, with the message of PowerShell itself: -like only reads the pattern here, matching nothing,
# where a method of .NET would wrap the message ('Exception calling "IsMatch"...', measured). Checked composed, as
# Test-Wildcard matches it: composing changes some characters (U+232A is U+3009 composed), so a range taken here as
# written failed once composed when applied, and another refused here would have matched (Copilot on #14, measured).
function Assert-WildcardPattern([string]$Pattern) {
    $null = '' -like (ConvertTo-ComposedText $Pattern)
}
