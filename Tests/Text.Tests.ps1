# Text compared alike in every culture and in every form of Unicode (Private/Text.ps1): Test-Wildcard and the check of
# a pattern; the code of the module, which compares text in no other way that the culture changes; and the names of
# accounts and policies in a session that starts in Turkish.

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

    It 'refuses a pattern that is not valid with the message of PowerShell, and takes one that is' {
        { InModuleScope ElektoImapPosh { Assert-WildcardPattern 'report[12' } } | Should -Throw -ExpectedMessage 'The specified wildcard character pattern is not valid: report`[12'
        { InModuleScope ElektoImapPosh { Assert-WildcardPattern 'report[12]' } } | Should -Not -Throw
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
