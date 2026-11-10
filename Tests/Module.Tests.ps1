# The module as a whole: the manifest, the mail libraries it loads (and those it refuses to share the
# session with), what it exports, and the help of each exported command.

BeforeAll {
    $manifestPath = Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1'
    $module = Import-Module $manifestPath -Force -PassThru
}

AfterAll {
    Remove-Module ElektoImapPosh -ErrorAction SilentlyContinue
}

Describe 'Module' {
    It 'has a valid manifest for PowerShell 7.6' {
        $manifest = Test-ModuleManifest -Path $manifestPath
        $manifest.PowerShellVersion | Should -Be ([version]'7.6')
        $manifest.CompatiblePSEditions | Should -Be @('Core')
    }

    It 'exports exactly the functions in the manifest' {
        $expected = (Import-PowerShellDataFile $manifestPath).FunctionsToExport | Sort-Object
        $exported = (Get-Command -Module ElektoImapPosh).Name | Sort-Object
        $exported | Should -Be $expected
    }
}

Describe 'Mail libraries' {
    It 'resolves the <TypeName> type literal to <Library> in the lib folder of the module' -TestCases @(
        @{ TypeName = 'MailKit.Net.Imap.ImapClient'; Library = 'MailKitLite' }
        @{ TypeName = 'MimeKit.MimeMessage'; Library = 'MimeKitLite' }
    ) {
        $assembly = ($TypeName -as [type]).Assembly
        $assembly.GetName().Name | Should -Be $Library
        $assembly.Location | Should -Be (Join-Path (Join-Path $module.ModuleBase 'lib') "$Library.dll")
    }

    # The full MailKit has the same namespaces: whichever is loaded first takes the type literals
    It 'refuses to share a session with the full <Library>' -TestCases @(
        @{ Library = 'MailKit' }
        @{ Library = 'MimeKit' }
    ) {
        # An empty assembly with the name of the full library stands for it
        $message = pwsh -NoProfile -NonInteractive -Command {
            param($Library, $Manifest)
            $null = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly([Reflection.AssemblyName]::new($Library), 'Run')
            try { Import-Module $Manifest -ErrorAction Stop; 'imported' } catch { $_.Exception.Message }
        } -args $Library, $manifestPath

        $message | Should -BeLike "*already loaded the full $Library*"
    }
}

Describe 'Help of <_>' -AllowNullOrEmptyForEach -ForEach @((Import-PowerShellDataFile (Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1')).FunctionsToExport) {
    BeforeAll {
        $help = Get-Help $_ -Full
    }

    It 'has a synopsis, a description and examples' {
        $help.Synopsis | Should -Not -BeLike "*$_*[[]*"  # not the auto-generated syntax line
        $help.Description.Text | Should -Not -BeNullOrEmpty
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }

    It 'documents every parameter' {
        $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
        @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
        $parameters = (Get-Command $_).Parameters.Keys | Where-Object { $_ -notin $common }
        foreach ($parameter in $parameters) {
            $description = ($help.Parameters.Parameter | Where-Object Name -EQ $parameter).Description.Text
            $description | Should -Not -BeNullOrEmpty -Because "-$parameter needs a description"
        }
    }
}

# Since .NET 9, [Environment]::SetEnvironmentVariable given $null, which PowerShell passes as "", leaves the variable
# defined and empty (measured on PowerShell 7.6, found by the ElektoMailPosh session): a test that cleared a variable,
# or put back one that was not there, left it behind, empty, for the files after it. The tests clear with Remove-Item
# on env:, and put back with Set-Item on env:, which removes a variable given $null.
Describe 'The test scripts' {
    It 'set and clear environment variables on env:, not with SetEnvironmentVariable' {
        function Find-SetEnvironmentVariable([string]$Code) {
            $tree = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)
            , @($tree.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Static -and "$($node.Member)" -eq 'SetEnvironmentVariable'
                    }, $true))
        }

        (Find-SetEnvironmentVariable '[Environment]::SetEnvironmentVariable($name, $null)').Count | Should -Be 1 -Because 'the search finds the form it looks for'
        $found = foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -Recurse) {
            foreach ($node in (Find-SetEnvironmentVariable (Get-Content -LiteralPath $file.FullName -Raw))) { "$($file.Name):$($node.Extent.StartLineNumber)" }
        }
        $found | Should -BeNullOrEmpty
    }
}

# The names of variables ignore case: "foreach ($domain in ...)" in a function with the parameter $Domain writes that
# parameter, and what follows the loop reads the last item for it. Test-DomainAuthenticated did so, and took a DKIM
# signature of any domain, named as header.d, for one of the domain of the From (found in the review before the first release).
Describe 'The functions of the module' {
    BeforeAll {
        # The variables that the left side of an assignment writes: $a, [string]$a, each of $a, $b; not $a.Name nor $a[0]
        function Get-AssignedVariable($Left) {
            if ($Left -is [System.Management.Automation.Language.VariableExpressionAst]) { $Left }
            elseif ($Left -is [System.Management.Automation.Language.AttributedExpressionAst]) { Get-AssignedVariable $Left.Child }
            elseif ($Left -is [System.Management.Automation.Language.ArrayLiteralAst]) { foreach ($element in $Left.Elements) { Get-AssignedVariable $element } }
        }

        # The places of a script that write a parameter of the function they are in by accident, each as
        # "<name>:<line> <function>: $<variable> is the parameter $<Parameter>": the variable of a foreach that is one of
        # its parameters, and an assignment to one in another spelling than the one it is declared in (in that very
        # spelling, a function gives a parameter of its own another value on purpose)
        function Find-ParameterOverwrite([string]$Name, [string]$Script) {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty -Because "$Name should parse"
            $writes = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.ForEachStatementAst] -or $node -is [System.Management.Automation.Language.AssignmentStatementAst]
                }, $true)
            foreach ($write in $writes) {
                # The nearest function around it: one defined inside another has parameters of its own
                $function = $write.Parent
                while ($function -and $function -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $function = $function.Parent }
                if (-not $function) { continue }
                $parameters = @(@($function.Parameters) + @($function.Body.ParamBlock.Parameters) | Where-Object { $_ } | ForEach-Object { $_.Name.VariablePath.UserPath })
                $loop = $write -is [System.Management.Automation.Language.ForEachStatementAst]
                $variables = if ($loop) { $write.Variable } else { Get-AssignedVariable $write.Left }
                foreach ($variable in $variables) {
                    $written = $variable.VariablePath.UserPath
                    foreach ($parameter in $parameters) {
                        if (-not [string]::Equals($written, $parameter, [StringComparison]::OrdinalIgnoreCase)) { continue }
                        if ($loop -or -not [string]::Equals($written, $parameter, [StringComparison]::Ordinal)) {
                            "${Name}:$($write.Extent.StartLineNumber) $($function.Name): `$$written is the parameter `$$parameter"
                        }
                    }
                }
            }
        }
    }

    # A form the search missed would let the test of the module pass without finding anything
    It 'finds a loop or an assignment that writes a parameter by accident, and none of those meant' {
        $accident = @'
function f($Results, [string]$Domain) { foreach ($domain in $Results) { } }
function f { param($Folder) process { foreach ($Folder in 1, 2) { } } }
function f($Name) { $name = 'x' }
function f($Name) { [string]$name = 'x' }
function f($Name) { $other, $NAME = 1, 2 }
function f($Count) { $count += 1 }
function f($Name) { 1 | ForEach-Object { $name = $_ } }
'@
        $meant = @'
function f($Name) { $Name = 'x' }
function f($Domain) { foreach ($signer in 1, 2) { $signer -eq $domain } }
function f($Name) { function g($Other) { foreach ($name in 1, 2) { } } }
function f($Settings) { $settings.Name = 'x'; $settings['Name'] = 'x' }
function f($Name) { $script:name = 'x' }
foreach ($name in 1, 2) { $Name = $name }
'@

        $found = @(Find-ParameterOverwrite 'accident' $accident)
        $found | ForEach-Object { [int]($_ -creplace '^accident:(\d+) .*$', '$1') } | Should -Be (1..7) -Because "each line has one such write: $($found -join '; ')"
        Find-ParameterOverwrite 'meant' $meant | Should -BeNullOrEmpty
    }

    It 'write none of their parameters by accident' {
        $root = Split-Path $PSScriptRoot
        $files = @(Get-ChildItem -LiteralPath (Join-Path $root 'Private'), (Join-Path $root 'Public') -Filter '*.ps1') + (Get-Item -LiteralPath (Join-Path $root 'ElektoImapPosh.psm1'))
        $files.Count | Should -BeGreaterThan 10

        $found = foreach ($file in $files) { Find-ParameterOverwrite "$($file.Directory.Name)/$($file.Name)" ([IO.File]::ReadAllText($file.FullName)) }

        $found | Should -BeNullOrEmpty -Because 'the names of variables ignore case, so such a write changes the parameter for the rest of the function'
    }
}
