<#
.SYNOPSIS
Restores the mail libraries, validates the module, runs the tests and stages the files that go to the
PowerShell Gallery.

.DESCRIPTION
The PowerShell equivalent of "does it compile and pass": MailKitLite and MimeKitLite are restored from
NuGet as Dependencies/packages.lock.json pins them, with the NuGet audit failing the restore on a known
vulnerability, and their assemblies copied to ./lib, from where the module loads them (so the module runs
from the source only after a first build). Then every script is parsed for syntax errors, the manifest is
validated, PSScriptAnalyzer runs (when installed) and the Pester tests run (when Pester 5 or later is
installed). If everything passes, the package is staged at ./out/ElektoImapPosh, with all the functions
in a single .psm1 and the assemblies in lib, and imported in a clean process to check that every function
in the manifest is exported and has its help. It is then ready for Publish-PSResource.

Needs the .NET SDK 10 or later, for the restore. Used by the GitHub workflows; can also be run locally
before committing or tagging.

.PARAMETER ExpectedVersion
When given (the publish workflow passes the tag version), fails unless the manifest declares this
version.

.PARAMETER SkipTests
Does not run the Pester tests.

.EXAMPLE
./Build.ps1

.EXAMPLE
./Build.ps1 -ExpectedVersion 0.1.0
#>
param (
    [string]$ExpectedVersion,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$moduleName = 'ElektoImapPosh'
$manifestPath = Join-Path $PSScriptRoot "$moduleName.psd1"
$packageFiles = @("$moduleName.psd1", "$moduleName.Format.ps1xml", 'lib', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md')
$libraries = @('MailKitLite', 'MimeKitLite')

# 1. The mail libraries: restored into out/packages, kept between builds, and copied to ./lib
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET SDK 10 or later is needed to restore the mail libraries: https://dotnet.microsoft.com/download'
}
$dependenciesDir = Join-Path $PSScriptRoot 'Dependencies'
$packagesDir = Join-Path (Join-Path $PSScriptRoot 'out') 'packages'
dotnet restore (Join-Path $dependenciesDir 'Dependencies.csproj') --locked-mode --packages $packagesDir | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Restoring the mail libraries failed (see above).' }
$lock = Get-Content -Path (Join-Path $dependenciesDir 'packages.lock.json') -Raw | ConvertFrom-Json -AsHashtable
$libDir = Join-Path $PSScriptRoot 'lib'
New-Item -ItemType Directory -Path $libDir -Force | Out-Null
$restored = foreach ($library in $libraries) {
    $version = $lock.dependencies['net10.0'][$library].resolved
    $source = Join-Path $packagesDir "$($library.ToLowerInvariant())/$version/lib/net10.0/$library.dll"
    $target = Join-Path $libDir "$library.dll"
    # A session that imported the module from the source holds the file open on Windows: copy only a change
    if (-not (Test-Path -LiteralPath $target) -or (Get-FileHash $source).Hash -ne (Get-FileHash $target).Hash) {
        Copy-Item -LiteralPath $source -Destination $target
    }
    "$library $version"
}
Write-Host "Mail libraries OK ($($restored -join ', '))."

# 2. Syntax: parse every PowerShell file
$scripts = Get-ChildItem -Path $PSScriptRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' |
    Where-Object { $_.FullName -notmatch '[\\/](out|obj|\.git)[\\/]' }
$syntaxErrors = foreach ($script in $scripts) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
    $parseErrors | ForEach-Object { "$($script.Name):$($_.Extent.StartLineNumber): $($_.Message)" }
}
if ($syntaxErrors) { throw "Syntax errors:`n$($syntaxErrors -join "`n")" }
Write-Host "Syntax OK ($($scripts.Count) files)."

# 3. Manifest, and version against the tag
$manifest = Test-ModuleManifest -Path $manifestPath
if ($ExpectedVersion -and $manifest.Version.ToString() -ne $ExpectedVersion) {
    throw "Tag means version '$ExpectedVersion', but the manifest declares '$($manifest.Version)'. Set them to the same value and re-tag."
}
Write-Host "Manifest OK (version $($manifest.Version))."

# 4. Static analysis: errors fail the build, warnings are only shown. In the tests, Pester's blocks share
#    variables in ways the analyzer cannot follow, and the helpers that write files need no ShouldProcess.
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $severity = 'Error', 'Warning'
    $sources = "$moduleName.psd1", "$moduleName.psm1", 'Build.ps1', 'Private', 'Public' | ForEach-Object { Join-Path $PSScriptRoot $_ }
    $findings = @(
        foreach ($source in $sources) { Invoke-ScriptAnalyzer -Path $source -Recurse -Severity $severity -ExcludeRule PSAvoidUsingWriteHost }
        Invoke-ScriptAnalyzer -Path (Join-Path $PSScriptRoot 'Tests') -Recurse -Severity $severity -ExcludeRule PSAvoidUsingWriteHost,
        PSUseDeclaredVarsMoreThanAssignments, PSUseShouldProcessForStateChangingFunctions
    )
    if ($findings) { $findings | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String | Write-Host }
    $analyzerErrors = @($findings | Where-Object Severity -EQ 'Error')
    if ($analyzerErrors) { throw "PSScriptAnalyzer found $($analyzerErrors.Count) error(s)." }
    Write-Host 'PSScriptAnalyzer OK.'
}
else {
    Write-Warning 'PSScriptAnalyzer not installed; skipping static analysis.'
}

# 5. Tests, on the source
if ($SkipTests) {
    Write-Warning 'Skipping the tests (-SkipTests).'
}
elseif ($pester = Get-Module -ListAvailable Pester | Where-Object Version -GE '5.0' | Sort-Object Version -Descending | Select-Object -First 1) {
    Import-Module $pester -Force
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $PSScriptRoot 'Tests'
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $result = Invoke-Pester -Configuration $configuration
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { throw "Tests failed: $($result.FailedCount) of $($result.TotalCount)." }
    Write-Host "Tests OK ($($result.PassedCount) passed, Pester $($pester.Version))."
}
else {
    Write-Warning 'Pester 5 or later not installed; skipping the tests.'
}

# 6. Stage the package. Its .psm1 is the source loader with every function in place of the region that
#    dot-sources them, in the same order: one file loads in about half the time of many, which counts for
#    scripts started every minute.
$outDir = Join-Path (Join-Path $PSScriptRoot 'out') $moduleName
if (Test-Path $outDir) { Remove-Item -Path $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null
foreach ($file in $packageFiles) {
    Copy-Item -Path (Join-Path $PSScriptRoot $file) -Destination $outDir -Recurse
}
$functions = foreach ($folder in 'Private', 'Public') {
    foreach ($script in Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1') {
        # The blank line keeps the region comment apart from the help comment that opens the file:
        # glued together, PowerShell reads them as one comment and the function loses its help
        "#region $folder/$($script.Name)"
        ''
        [IO.File]::ReadAllText($script.FullName).TrimEnd()
        '#endregion'
        ''
    }
}
$loader = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "$moduleName.psm1"))
$region = [regex]::Match($loader, '(?ms)^#region Functions\b.*?^#endregion[^\r\n]*')
if (-not $region.Success) { throw "$moduleName.psm1 has no '#region Functions' for Build.ps1 to replace." }
$merged = $loader.Substring(0, $region.Index) + ($functions -join [Environment]::NewLine) + $loader.Substring($region.Index + $region.Length)
[IO.File]::WriteAllText((Join-Path $outDir "$moduleName.psm1"), $merged, [Text.UTF8Encoding]::new($false))
Write-Host "Package staged at $outDir."

# 7. Import the package in a clean process: it loads the mail libraries it carries, and every function in
#    the manifest is exported and has its help
pwsh -NoProfile -NonInteractive -Command {
    param($Manifest, $Name, $Libraries)
    $module = Import-Module $Manifest -Force -ErrorAction Stop -PassThru
    $libDir = Join-Path $module.ModuleBase 'lib'
    foreach ($library in $Libraries) {
        $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $library }
        if (-not $loaded -or -not $loaded.Location.StartsWith($libDir)) { throw "$library was not loaded from $libDir." }
    }
    $functions = (Import-PowerShellDataFile $Manifest).FunctionsToExport
    $missing = $functions | Where-Object { -not (Get-Command $_ -Module $Name -ErrorAction SilentlyContinue) }
    if ($missing) { throw "Not exported: $($missing -join ', ')" }
    $withoutHelp = $functions | Where-Object { -not (Get-Help $_).Description }
    if ($withoutHelp) { throw "No help in the package for: $($withoutHelp -join ', ')" }
} -args (Join-Path $outDir "$moduleName.psd1"), $moduleName, $libraries
if ($LASTEXITCODE -ne 0) { throw 'Package import check failed.' }
Write-Host 'Package import OK.'
