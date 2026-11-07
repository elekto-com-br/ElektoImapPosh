# Text compared alike in every culture and in every form of Unicode (Private/Text.ps1): Test-Wildcard and the check of
# a pattern; the code of the module, which compares text in no other way that the culture changes; and the names of
# accounts and policies in a session that starts in Turkish. Also a text from a message as the module shows it
# (Format-ShownText).

BeforeDiscovery {
    # Text written in the tags of Unicode, which whoever reads it does not see, and an AI reads all the same
    $tags = -join ('IGNORE ALL'.ToCharArray() | ForEach-Object { [char]::ConvertFromUtf32(0xE0000 + [int]$_) })
    # A man and a laptop, joined (ZWJ): one emoji
    $coder = [char]::ConvertFromUtf32(0x1F468) + "`u{200D}" + [char]::ConvertFromUtf32(0x1F4BB)
    # The flag of England: a black flag and the tags of its name, which go too
    $england = [char]::ConvertFromUtf32(0x1F3F4) + (-join ('gbeng'.ToCharArray() | ForEach-Object { [char]::ConvertFromUtf32(0xE0000 + [int]$_) })) + [char]::ConvertFromUtf32(0xE007F)
}

BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1') -Force

    # Runs a script with the thread in the culture given, as a session in that culture runs, and puts the culture back
    function Invoke-InCulture([string]$Culture, [scriptblock]$Script) {
        $before = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = $Culture
            & $Script
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $before
        }
    }
}

AfterAll {
    Remove-Module ElektoImapPosh -ErrorAction SilentlyContinue
}

Describe 'Matching a pattern' {
    BeforeAll {
        function Test-Match([string]$Text, [string]$Pattern) {
            InModuleScope ElektoImapPosh -Parameters @{ Text = $Text; Pattern = $Pattern } { param($Text, $Pattern) Test-Wildcard $Text $Pattern }
        }
    }

    # In Turkish, "I" is not the capital of "i"
    It 'ignores case alike in the Turkish culture, where -like does not' {
        $like, $matched = Invoke-InCulture 'tr-TR' {
            'X@CLIENT.EXAMPLE' -like '*@client.example'
            Test-Match 'X@CLIENT.EXAMPLE' '*@client.example'
            Test-Match 'INBOX/Invoices' 'inbox/*'
            Test-Match 'WORK-INBOX' 'work-inbox'
            Test-Match 'billing' 'BILL*'
        }

        $like | Should -BeFalse -Because 'that is what Test-Wildcard is for'
        $matched | Should -Be $true, $true, $true, $true
    }

    # macOS writes names decomposed (NFD), and WildcardPattern compares a pattern with wildcards character by character
    It 'takes a text and a pattern, written composed or decomposed, for the same' {
        $composed = "Relat`u{F3}rios/2026"
        $decomposed = "Relato`u{301}rios/2026"

        Test-Match $decomposed "*Relat`u{F3}rios*" | Should -BeTrue
        Test-Match $composed "*Relato`u{301}rios*" | Should -BeTrue
        Test-Match $decomposed "Relat`u{F3}rios/20?6" | Should -BeTrue
        Test-Match 'Relatorios/2026' "*Relat`u{F3}rios*" | Should -BeFalse -Because 'an accent still counts'
    }

    # -eq and -contains ignore format characters: an override of direction, a soft hyphen, a zero-width space
    It 'tells apart two texts that differ in a format character, which -eq takes for the same' {
        $same = Invoke-InCulture 'tr-TR' {
            InModuleScope ElektoImapPosh {
                Test-SameText 'MAIL.EXAMPLE' 'mail.example'
                Test-SameText "relat`u{F3}rio.example" "relato`u{301}rio.example"
                foreach ($character in [char]0x202E, [char]0xAD, [char]0x200B) { Test-SameText 'client.example' "cli${character}ent.example" }
            }
        }

        'client.example' -eq "cli`u{202E}ent.example" | Should -BeTrue -Because 'that is why Test-SameText exists'
        $same | Should -Be $true, $true, $false, $false, $false
    }

    # The results of a receiving server name the domain whose DMARC record it applied, a parent of the sender's on Gmail
    It 'tells a domain within another, alike in every culture and form, from one that only ends as it does' {
        $within = Invoke-InCulture 'tr-TR' {
            InModuleScope ElektoImapPosh {
                Test-WithinDomain 'EMAIL.CLIENT.EXAMPLE' 'client.example'
                Test-WithinDomain 'client.example' 'CLIENT.EXAMPLE'
                Test-WithinDomain "news.relat`u{F3}rio.example" "relato`u{301}rio.example"
                Test-WithinDomain "news.relato`u{301}rio.example" "relat`u{F3}rio.example"
                Test-WithinDomain 'evilclient.example' 'client.example'
                Test-WithinDomain 'client.example' 'news.client.example'
                Test-WithinDomain "news.cli`u{200B}ent.example" 'client.example'
                Test-WithinDomain 'client.example' ''
                Test-WithinDomain '' ''
            }
        }

        $within | Should -Be $true, $true, $true, $true, $false, $false, $false, $false, $false
    }

    It 'refuses a pattern that is not valid with the message of PowerShell, and takes one that is' {
        { InModuleScope ElektoImapPosh { Assert-WildcardPattern 'report[12' } } | Should -Throw -ExpectedMessage 'The specified wildcard character pattern is not valid: report`[12'
        { InModuleScope ElektoImapPosh { Assert-WildcardPattern 'report[12]' } } | Should -Not -Throw
    }

    # Composing changes some characters, U+232A among them (U+3009 composed): one range is reversed only once composed,
    # and the other only as written (Copilot on #14)
    It 'checks a pattern composed, as it is matched' {
        $reversed = '*[' + [char]0x232A + '-' + [char]0x3008 + ']*'
        $straight = '*[' + [char]0x3008 + '-' + [char]0x232A + ']*'

        { InModuleScope ElektoImapPosh -Parameters @{ Pattern = $reversed } { param($Pattern) Assert-WildcardPattern $Pattern } } | Should -Throw -ExpectedMessage 'The specified wildcard character pattern is not valid: *'
        { InModuleScope ElektoImapPosh -Parameters @{ Pattern = $straight } { param($Pattern) Assert-WildcardPattern $Pattern } } | Should -Not -Throw
        Test-Match ([string][char]0x232A) $straight | Should -BeTrue -Because 'a pattern taken matches as it was checked'
    }
}

# What a sender writes, shown without what drives a terminal, reorders the text or hides it, and cut when it would
# flood the context of an AI
Describe 'A text from a message as it is shown' {
    BeforeAll {
        # Format-ShownText, or with -Multiline Format-ShownBody, which keeps the lines and never cuts
        function Format-Shown($Text, [int]$MaxLength = 1000, [switch]$Multiline) {
            InModuleScope ElektoImapPosh -Parameters @{ Text = $Text; MaxLength = $MaxLength; Multiline = [bool]$Multiline } {
                param($Text, $MaxLength, $Multiline)
                if ($Multiline) { Format-ShownBody $Text } else { Format-ShownText $Text -MaxLength $MaxLength }
            }
        }
        # Compared character for character (-ceq takes a text and its decomposed form for equal); when they differ, the
        # codes of the characters around the first difference, since some texts here have two million of them
        function Assert-Shown($Shown, [string]$Expected) {
            $Shown = [string]$Shown
            if ([string]::Equals($Shown, $Expected, [StringComparison]::Ordinal)) { return }
            $at = 0
            while ($at -lt $Shown.Length -and $at -lt $Expected.Length -and [int]$Shown[$at] -eq [int]$Expected[$at]) { $at++ }
            $start = [Math]::Max(0, $at - 5)
            $codes = { param($Text) (@($Text.ToCharArray() | Select-Object -Skip $start -First 15) | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' ' }
            $false | Should -BeTrue -Because "from the character $start, $(& $codes $Shown) should be $(& $codes $Expected) (of $($Shown.Length) and $($Expected.Length) characters)"
        }
        $replacement = [string][char]0xFFFD
        # As in BeforeDiscovery, whose variables only the test cases see
        $tags = -join ('IGNORE ALL'.ToCharArray() | ForEach-Object { [char]::ConvertFromUtf32(0xE0000 + [int]$_) })

        # Every character of Unicode, by the categories .NET gives them, in C#: a loop over 1.1 million code points
        # takes some 20 s in PowerShell
        if (-not ('ElektoImapPoshTests.Characters' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Globalization;
using System.Text;

namespace ElektoImapPoshTests
{
    public static class Characters
    {
        // The characters of the BMP, or those outside it, each after the separator: the hidden ones (control and
        // format characters, but for the joiners ZWNJ and ZWJ), or every other one but the halves of characters
        // and the separators of lines and of paragraphs
        public static string Join(bool hidden, bool outsideBmp, string separator)
        {
            var text = new StringBuilder();
            int first = outsideBmp ? 0x10000 : 0, last = outsideBmp ? 0x10FFFF : 0xFFFF;
            for (int code = first; code <= last; code++)
            {
                if (code >= 0xD800 && code <= 0xDFFF) continue;
                var category = CharUnicodeInfo.GetUnicodeCategory(code);
                bool isHidden = (category == UnicodeCategory.Control || category == UnicodeCategory.Format) && code != 0x200C && code != 0x200D;
                if (hidden != isHidden) continue;
                if (!hidden && (category == UnicodeCategory.LineSeparator || category == UnicodeCategory.ParagraphSeparator)) continue;
                text.Append(separator).Append(char.ConvertFromUtf32(code));
            }
            return text.ToString();
        }
    }
}
'@
        }
    }

    It 'shows <Case>' -TestCases @(
        @{ Case = 'line breaks and tabs as one space'; Text = "Hi`r`n`tthere"; Expected = 'Hi there' }
        @{ Case = 'the separators of lines of Unicode as a space'; Text = "a`u{2028}b`u{85}c"; Expected = 'a b c' }
        @{ Case = 'a separator of lines of Unicode alone, which is no control character, as a space'; Text = "a`u{2028}b"; Expected = 'a b' }
        @{ Case = 'an escape sequence that clears the screen without its escape'; Text = "a`e[2Jb"; Expected = "a`u{FFFD}[2Jb" }
        @{ Case = 'an escape sequence that writes to the clipboard (OSC 52) without its controls'; Text = "a`e]52;c;aGk=`ab"; Expected = "a`u{FFFD}]52;c;aGk=`u{FFFD}b" }
        @{ Case = 'a control character of the C1 set (CSI) as replaced'; Text = "a`u{9B}2Jb"; Expected = "a`u{FFFD}2Jb" }
        @{ Case = 'an override of direction, which shows fdp.exe as exe.pdf, as replaced'; Text = "photo`u{202E}gpj.exe"; Expected = "photo`u{FFFD}gpj.exe" }
        @{ Case = 'the isolates of direction as replaced'; Text = "a`u{2067}b`u{2069}c"; Expected = "a`u{FFFD}b`u{FFFD}c" }
        @{ Case = 'without the marks of direction, which can turn digits around'; Text = "a`u{200E}b`u{200F}c`u{61C}d"; Expected = 'abcd' }
        @{ Case = 'without a soft hyphen, a zero-width space, a word joiner and a BOM'; Text = "Ver`u{AD}si`u{200B}che`u{2060}rung`u{FEFF}"; Expected = 'Versicherung' }
        @{ Case = 'text hidden in the tags of Unicode as one replacement'; Text = "ok$tags!"; Expected = "ok`u{FFFD}!" }
        @{ Case = 'the flag of England without its tags, which only an emoji of flags uses'; Text = $england; Expected = [char]::ConvertFromUtf32(0x1F3F4) + "`u{FFFD}" }
        @{ Case = 'an invisible operator as replaced'; Text = "a`u{2062}b"; Expected = "a`u{FFFD}b" }
        @{ Case = 'a run of hidden characters as one replacement'; Text = "a`e`e`u{202E}`u{9B}b"; Expected = "a`u{FFFD}b" }
        @{ Case = 'variation selectors in a row, which carry hidden data, as one replacement'; Text = "x`u{FE00}`u{FE01}" + [char]::ConvertFromUtf32(0xE0100) + 'y'; Expected = "x`u{FFFD}y" }
        @{ Case = 'a half of a character without its other half as replaced'; Text = 'a' + [char]0xD800 + 'b' + [char]0xDC00 + 'c'; Expected = "a`u{FFFD}b`u{FFFD}c" }
        @{ Case = 'an emoji of several joined (ZWJ) as it is'; Text = $coder; Expected = $coder }
        @{ Case = 'the non-joiner of Persian (ZWNJ) as it is'; Text = "a`u{200C}b"; Expected = "a`u{200C}b" }
        @{ Case = 'an emoji with its variation selector as it is'; Text = "`u{2764}`u{FE0F} ok"; Expected = "`u{2764}`u{FE0F} ok" }
        @{ Case = 'a name written decomposed as it is'; Text = "Relato`u{301}rio"; Expected = "Relato`u{301}rio" }
        @{ Case = 'an empty text as it is'; Text = ''; Expected = '' }
    ) {
        Assert-Shown (Format-Shown $Text) $Expected
    }

    It 'keeps $null' {
        Format-Shown $null | Should -BeNullOrEmpty
        InModuleScope ElektoImapPosh { $null -eq (Format-ShownText $null); $null -eq (Format-ShownBody $null) } | Should -Be $true, $true
    }

    # A message has a dozen such texts, and a call of a function costs more than the work it does on them
    It 'shows several texts in one call, each in its place, $null and long ones included' {
        $shown = InModuleScope ElektoImapPosh { , @(Format-ShownText 'plain', $null, "a`e[2Jb", '', ('x' * 1001)) }

        $shown.Count | Should -Be 5
        $shown[0] | Should -BeExactly 'plain'
        $null -eq $shown[1] | Should -BeTrue
        Assert-Shown $shown[2] "a`u{FFFD}[2Jb"
        $shown[3] | Should -BeExactly ''
        Assert-Shown $shown[4] (('x' * 999) + "`u{2026}")
    }

    It 'keeps the tabs and line breaks of a text of many lines, and nothing else that drives a terminal' {
        Assert-Shown (Format-Shown "Line one`r`n`tIndented`e[31m red$tags`r`nLast`v`f" -Multiline -MaxLength 0) "Line one`r`n`tIndented`u{FFFD}[31m red`u{FFFD}`r`nLast`u{FFFD}"
    }

    It 'cuts a long text to 1000 characters that end in an ellipsis, after taking out what is hidden' {
        $cut = Format-Shown ('x' * 2000)
        $cut.Length | Should -Be 1000
        Assert-Shown $cut (('x' * 999) + "`u{2026}")
        # Not between the two halves of an emoji
        Assert-Shown (Format-Shown (('x' * 998) + [char]::ConvertFromUtf32(0x1F600) + 'yyy')) (('x' * 998) + "`u{2026}")
        Assert-Shown (Format-Shown ('x' * 1000)) ('x' * 1000)
        # 1800 characters, 900 of them removed: the 900 left are not cut
        Assert-Shown (Format-Shown ("x`u{200B}" * 900)) ('x' * 900)
        (Format-Shown ('x' * 2000) -Multiline -MaxLength 0).Length | Should -Be 2000
    }

    # .NET knows the categories of every character; the pattern names the format characters outside the BMP one by one
    It 'leaves no control character nor format character but the joiners, and every other character as it is' {
        $bmp = [ElektoImapPoshTests.Characters]::Join($true, $false, '')
        # Each after an x, so that each comes back as one replacement; and the others so that no two variation
        # selectors come in a row
        $outside = [ElektoImapPoshTests.Characters]::Join($true, $true, 'x')
        $others = [ElektoImapPoshTests.Characters]::Join($false, $false, 'x') + [ElektoImapPoshTests.Characters]::Join($false, $true, 'x')

        $bmp.Length | Should -BeGreaterThan 100
        $outside.Length | Should -BeGreaterThan 300
        Format-Shown $bmp -MaxLength 0 | Should -MatchExactly "^[ $replacement]+$"
        Format-Shown $bmp -MaxLength 0 -Multiline | Should -MatchExactly "^[`t`n`r$replacement]+$"
        Assert-Shown (Format-Shown $outside -MaxLength 0) ($outside -creplace '[^x]+', $replacement)
        Assert-Shown (Format-Shown $others -MaxLength 0) $others
    }

    # A sender writes the text, of any length, with any characters: hidden ones must not take the square of that
    It 'shows a long hostile text in a time that grows with its length only' {
        $hostile = "a`e[2J" + "`u{FE00}`u{FE01}" * 3 + $tags + "`u{202E}" + "`r`n"
        $milliseconds = InModuleScope ElektoImapPosh -Parameters @{ Hostile = $hostile } {
            param($Hostile)
            foreach ($run in @{ Copies = 100; Times = 100 }, @{ Copies = 10000; Times = 1 }) {
                $text = $Hostile * $run.Copies
                (Measure-Command { foreach ($time in 1..$run.Times) { $null = Format-ShownText $text -MaxLength 0 } }).TotalMilliseconds
            }
        }

        $milliseconds[1] | Should -BeLessThan ($milliseconds[0] * 5) -Because "10000 copies once ($($milliseconds[1]) ms) should take about as long as 100 copies 100 times ($($milliseconds[0]) ms)"
    }
}

Describe 'The code of the module' {
    BeforeAll {
        # The places of a script that compare text as the culture of the session does, each as "<name>:<line> <what>":
        # -like in every form (a pattern without wildcards is compared by the culture even telling case apart), and the
        # forms of -match, -replace and -split that ignore case; switch -Wildcard or -Regex, Where-Object -Like or
        # -Match, Select-String, Sort-Object -Unique and Group-Object, without -CaseSensitive; ToLower and ToUpper; a
        # name or a string that starts with CurrentCulture; options that ignore case without CultureInvariant; and
        # ValidatePattern without Options, which then ignores case as the culture does
        function Find-CultureDependentText([string]$Name, [string]$Script) {
            $tokens = $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty -Because "$Name should parse"
            foreach ($token in $tokens) {
                if ("$($token.Kind)" -in 'Ilike', 'Inotlike', 'Clike', 'Cnotlike', 'Imatch', 'Inotmatch', 'Ireplace', 'Isplit') { "${Name}:$($token.Extent.StartLineNumber) $($token.Text)" }
            }
            foreach ($node in $ast.FindAll({ $true }, $true)) {
                $what = $null
                if ($node -is [System.Management.Automation.Language.SwitchStatementAst]) {
                    $flags = $node.Flags
                    if (($flags -band [System.Management.Automation.Language.SwitchFlags]'Wildcard, Regex') -and -not ($flags -band [System.Management.Automation.Language.SwitchFlags]::CaseSensitive)) { $what = "switch -$flags" }
                } elseif ($node -is [System.Management.Automation.Language.CommandAst]) {
                    $command = $node.GetCommandName()
                    $parameters = @($node.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName)
                    $caseSensitive = $parameters -contains 'CaseSensitive'
                    if ($command -in 'Where-Object', 'where', '?') {
                        $by = @($parameters | Where-Object { $_ -in 'Like', 'NotLike', 'ILike', 'INotLike', 'CLike', 'CNotLike', 'Match', 'NotMatch', 'IMatch', 'INotMatch' })
                        if ($by) { $what = "$command -$($by[0])" }
                    } elseif ($command -in 'Select-String', 'Group-Object' -and -not $caseSensitive) { $what = $command }
                    elseif ($command -eq 'Sort-Object' -and $parameters -contains 'Unique' -and -not $caseSensitive) { $what = 'Sort-Object -Unique' }
                } elseif ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    if ("$($node.Member)" -in 'ToLower', 'ToUpper' -and -not $node.Arguments) { $what = "$($node.Member)()" }
                } elseif ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    # Strings, and the names of members (CurrentCultureIgnoreCase) and of options
                    $value = $node.Value
                    if ($value -cmatch '(?<![A-Za-z])IgnoreCase(?![A-Za-z])' -and $value -cnotmatch 'CultureInvariant') { $what = $value }
                    elseif ($value.StartsWith('CurrentCulture', [StringComparison]::Ordinal)) { $what = $value }
                } elseif ($node -is [System.Management.Automation.Language.AttributeAst] -and $node.TypeName.Name -in 'ValidatePattern', 'ValidatePatternAttribute') {
                    $options = @($node.NamedArguments | Where-Object ArgumentName -EQ 'Options')
                    $text = if ($options) { "$($options[0].Argument)" } else { 'IgnoreCase' }
                    if ($text -cmatch 'IgnoreCase' -and $text -cnotmatch 'CultureInvariant') { $what = 'ValidatePattern ignoring case' }
                }
                if ($what) { "${Name}:$($node.Extent.StartLineNumber) $what" }
            }
        }
    }

    # A form the search missed, or one it took for another, would let the test of the module pass without finding anything
    It 'finds each form that compares text as the culture does, and none of those that do not' {
        $culture = @'
$a -like 'x*'
$a -notlike 'x*'
$a -ilike 'x*'
$a -clike 'x*'
$a -match 'x'
$a -inotmatch 'x'
$a -replace 'x'
$a -split 'x'
switch -Wildcard ($a) { 'x*' { } }
switch -Regex ($a) { 'x' { } }
$a | Where-Object Name -Like 'x*'
$a | Where-Object Name -Match 'x'
$a | Select-String 'x'
$a | Sort-Object -Unique
$a | Group-Object
$a.ToLower()
$a.ToUpper()
[string]::Equals($a, $b, [StringComparison]::CurrentCultureIgnoreCase)
[regex]::IsMatch($a, 'x', 'IgnoreCase')
function f { param([ValidatePattern('^x$')]$y) }
'@
        $alike = @'
$a -cmatch 'x'
$a -cnotmatch 'x'
$a -creplace 'x'
$a -csplit 'x'
$a -eq 'x'
$a -in 'x', 'y'
switch ($a) { 'x' { } }
switch -Regex -CaseSensitive ($a) { 'x' { } }
$a | Where-Object Name -CMatch 'x'
$a | Select-String 'x' -CaseSensitive
$a | Sort-Object -Unique -CaseSensitive
$a | Sort-Object
$a | Group-Object -CaseSensitive
$a.ToLowerInvariant()
[regex]::IsMatch($a, 'x', 'IgnoreCase, CultureInvariant')
[StringComparer]::OrdinalIgnoreCase
[string]::Equals($a, $b, [StringComparison]::InvariantCultureIgnoreCase)
function f { param([ValidatePattern('^x$', Options = 'None')]$y) }
'@

        $found = @(Find-CultureDependentText 'culture' $culture)
        $found | ForEach-Object { [int]($_ -creplace '^culture:(\d+) .*$', '$1') } | Should -Be (1..20) -Because "each line has one such form: $($found -join '; ')"
        Find-CultureDependentText 'alike' $alike | Should -BeNullOrEmpty
    }

    It 'compares text alike in every culture outside Private/Text.ps1' {
        $root = Split-Path $PSScriptRoot
        $files = @(Get-ChildItem -LiteralPath (Join-Path $root 'Private'), (Join-Path $root 'Public') -Filter '*.ps1' | Where-Object Name -NE 'Text.ps1') + (Get-Item -LiteralPath (Join-Path $root 'ElektoImapPosh.psm1'))
        $files.Count | Should -BeGreaterThan 10

        $found = foreach ($file in $files) { Find-CultureDependentText "$($file.Directory.Name)/$($file.Name)" ([IO.File]::ReadAllText($file.FullName)) }

        $found | Should -BeNullOrEmpty -Because 'Private/Text.ps1 has the only ways to compare text that the culture changes'
    }
}

# PowerShell keeps the regexes it built, with the culture they were built in: a session set to Turkish once it runs
# would check names with those of its start, so this one starts in Turkish
Describe 'Names in a session that starts in Turkish' {
    It 'refuses a name with a dotless i for an account or a policy, as in any other culture, and takes the others' {
        $config = Join-Path $TestDrive 'turkish'
        $null = New-Item -ItemType Directory -Path $config
        $result = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -Command {
            param($Manifest, $Config)
            [cultureinfo]::CurrentCulture = 'tr-TR'
            $env:IMAP_CONFIG_DIR = $Config
            Import-Module $Manifest
            # A name taken is written; one refused throws, as a parameter or read from the file
            function Test-Taken([scriptblock]$Script) { try { $null = & $Script; $true } catch { $false } }
            $dotless = [string][char]0x131 + 'tem'
            $file = Join-Path $Config 'accounts.json'
            [pscustomobject]@{
                Culture        = [cultureinfo]::CurrentCulture.Name
                Account        = Test-Taken { Set-ImapAccount -Name 'WORK-INBOX' -Server imap.example.com -User me@example.com -WarningAction SilentlyContinue }
                Policy         = Test-Taken { Set-ImapPolicy -Name 'INBOX-ONLY' -MaxMessages 1 }
                DotlessAccount = Test-Taken { Set-ImapAccount -Name $dotless -Server imap.example.com -User me@example.com -WarningAction SilentlyContinue }
                DotlessPolicy  = Test-Taken { Set-ImapPolicy -Name $dotless -MaxMessages 1 }
                AccountInFile  = Test-Taken { Set-Content -LiteralPath $file -Value ('{ "Accounts": { "' + $dotless + '": { "Server": "s", "User": "u" } } }'); Get-ImapAccount -ErrorAction Stop }
                PolicyInFile   = Test-Taken { Set-Content -LiteralPath $file -Value ('{ "Policies": { "' + $dotless + '": { "MaxMessages": 1 } } }'); Get-ImapPolicy -ErrorAction Stop }
            }
        } -args (Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1'), $config

        $result.Culture | Should -Be 'tr-TR'
        $result.Account | Should -BeTrue
        $result.Policy | Should -BeTrue
        $result.DotlessAccount | Should -BeFalse
        $result.DotlessPolicy | Should -BeFalse
        $result.AccountInFile | Should -BeFalse
        $result.PolicyInFile | Should -BeFalse
    }
}
