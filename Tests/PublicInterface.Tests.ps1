# The public interface against the one recorded in PublicInterface.txt. A parameter that loses its
# position, its pipeline binding or a value it accepted breaks the scripts that use it, and the diff of
# the change rarely shows it: adding a parameter set to Send-Mail took the positions of 1.x away.

BeforeAll {
    # Each parameter line with its command and parameter set in front, so that a difference reads alone
    function Get-QualifiedLine([string[]]$Lines) {
        $command = $parameterSet = $null
        foreach ($line in $Lines | Where-Object { $_ -and $_ -notmatch '^#' }) {
            if ($line -match '^\S') { $command = $line }
            elseif ($line -match '^  \S') { $parameterSet = $line.Trim() }
            else { "$command [$parameterSet] $($line.Trim())" }
        }
    }
}

Describe 'Public interface' {
    It 'is the one recorded in PublicInterface.txt' {
        $recorded = @(Get-Content -Path (Join-Path $PSScriptRoot 'PublicInterface.txt'))
        $current = @(& (Join-Path $PSScriptRoot 'Get-PublicInterface.ps1'))

        # Sorted by parameter, so the recorded line and the current one of each parameter come together
        $differences = Compare-Object @(Get-QualifiedLine $recorded) @(Get-QualifiedLine $current) -CaseSensitive |
            Sort-Object { $_.InputObject -replace '^(.*? -\S+).*', '$1' }, SideIndicator | ForEach-Object {
                $(if ($_.SideIndicator -eq '<=') { 'recorded: ' } else { 'now:      ' }) + $_.InputObject
            }

        ($differences | ForEach-Object { "`n$_" }) -join '' | Should -BeNullOrEmpty -Because 'scripts call these commands as recorded. If the change is intended, regenerate the file (see Tests/Get-PublicInterface.ps1) and commit it with the change'
        ($current -join "`n") | Should -BeExactly ($recorded -join "`n")
    }
}
