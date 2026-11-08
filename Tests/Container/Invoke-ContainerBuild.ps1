<#
.SYNOPSIS
Runs Build.ps1 in a container, apart from the accounts and passwords of this machine.

.DESCRIPTION
The tests write accounts files and password files, in folders of their own, and some run the module in a
process of its own; a mistake there would reach the accounts of the user who runs them. This script, as the
one of ElektoMailPosh, builds an image from the Containerfile beside it (Ubuntu 24.04, as the ubuntu-latest of
the CI, with PowerShell, the .NET SDK, Pester, PSScriptAnalyzer, smtp4dev and the mail libraries restored from
NuGet) and runs Build.ps1 in it:
- as a user that is not root, since root reads and deletes files whatever their modes, and the tests that take
  a permission away would not test what they mean to;
- without network, with the repository mounted read-only and copied inside, without what an earlier build left
  (out, lib, obj), so that nothing the build or the tests do reaches this machine, and nothing of this machine
  but the repository reaches them: not its accounts, passwords or IMAP_* variables. Each run starts from the
  image as it was built. The tests start smtp4dev on the loopback, which a container without network keeps.

Needs Podman or Docker. With rootless Podman the user of the container is a subordinate user of this machine,
which reads the repository only if others can read its files, as git checks them out unless the umask says
otherwise. The image stays, as elektoimapposh-test:<version>, so the next run starts at once; remove it with
"podman rmi" (or "docker rmi").

.PARAMETER Version
The versions of PowerShell to run on, of those listed in this script. Default: all of them.

.EXAMPLE
./Tests/Container/Invoke-ContainerBuild.ps1
#>
param (
    [string[]]$Version
)

$ErrorActionPreference = 'Stop'

# Each version with the SHA-256 of its linux-x64 tarball, as GitHub lists it with the release. The manifest takes
# PowerShell 7.6 and later.
$releases = [ordered]@{
    '7.6.9' = '1da6d6d6035d651f20e70ddee7c4c15ac6ab8b9fb40ee92240d91263f28a884b'
}
# The .NET SDK that restores the mail libraries, with the SHA-512 of its linux-x64 tarball, as the release metadata of
# .NET lists it (builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json)
$sdkVersion = '10.0.403'
$sdkSha512 = 'b7b3d8461cf98b07d2552ce9199702fa3ad010ac2671a5f8cd5136f7534e50f6855ba7bbb02b11494563f1d04156276a31cda1103b900e5eecd0d9473dc7b9c5'

if (-not $Version) { $Version = @($releases.Keys) }
$unknown = @($Version | Where-Object { -not $releases.Contains($_) })
if ($unknown) { throw "No SHA-256 for PowerShell $($unknown -join ', '): add the version to `$releases in $PSCommandPath." }

$engine = @('podman', 'docker' | Where-Object { Get-Command $_ -CommandType Application -ErrorAction Ignore })[0]
if (-not $engine) { throw 'Needs Podman or Docker.' }
$repository = Split-Path (Split-Path $PSScriptRoot)

# Inside: the repository copied, without what a build on this machine left, and the libraries of the image in place of
# those it would restore from NuGet
$run = 'Copy-Item -Path /src -Destination ~/work -Recurse; Set-Location ~/work; ' +
"Remove-Item -Recurse -Force -ErrorAction Ignore out, lib, bin, obj, Dependencies/obj; " +
'New-Item -ItemType Directory -Path out | Out-Null; Copy-Item -Path ~/packages -Destination out/packages -Recurse; ./Build.ps1'

$failed = [System.Collections.Generic.List[string]]::new()
foreach ($each in $Version) {
    $image = "elektoimapposh-test:$each"
    Write-Host "Building $image with $engine..."
    & $engine build --quiet --tag $image --file (Join-Path $PSScriptRoot 'Containerfile') `
        --build-arg "PWSH_VERSION=$each" --build-arg "PWSH_SHA256=$($releases[$each])" `
        --build-arg "DOTNET_SDK_VERSION=$sdkVersion" --build-arg "DOTNET_SDK_SHA512=$sdkSha512" `
        (Join-Path $repository 'Dependencies') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not build $image." }

    Write-Host "Running Build.ps1 on PowerShell $each..."
    & $engine run --rm --network none --volume "${repository}:/src:ro" $image pwsh -NoProfile -NonInteractive -Command $run | Out-Host
    if ($LASTEXITCODE -ne 0) { $failed.Add($each) }
}
if ($failed) { throw "Build.ps1 failed on PowerShell $($failed -join ', ')." }
Write-Host "Build.ps1 passed on PowerShell $($Version -join ', ')."
