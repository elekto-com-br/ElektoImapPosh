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
