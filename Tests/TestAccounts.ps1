# Accounts for the tests that read from a server of their own, smtp4dev or the fake Gmail: an accounts file in a
# folder of the test drive, with the passwords in the environment.

# Writes an accounts file in a folder of its own, every account on the port given, with its password in the
# environment; returns the names of the password variables, for AfterAll to remove. The values they had before go
# into $SavedEnvironment, which the AfterAll of the test file restores.
function Set-TestAccount([string]$Folder, [int]$Port, [hashtable]$Accounts, [hashtable]$Policies = @{}, [string]$Default, [hashtable]$SavedEnvironment) {
    $env:IMAP_CONFIG_DIR = Join-Path $TestDrive $Folder
    New-Item -ItemType Directory -Path $env:IMAP_CONFIG_DIR -Force | Out-Null
    $file = @{ Accounts = @{}; Policies = $Policies }
    if ($Default) { $file.Default = $Default }
    foreach ($entry in $Accounts.GetEnumerator()) {
        $account = @{ Server = '127.0.0.1'; Port = $Port; User = 'tester'; NoTls = $true }
        foreach ($setting in $entry.Value.GetEnumerator()) { $account[$setting.Key] = $setting.Value }
        $file.Accounts[$entry.Key] = $account
        $variable = "IMAP_PASS_$($entry.Key.ToUpperInvariant())"
        if (-not $SavedEnvironment.ContainsKey($variable)) { $SavedEnvironment[$variable] = [Environment]::GetEnvironmentVariable($variable) }
        [Environment]::SetEnvironmentVariable($variable, 'not-a-password')
    }
    Set-Content -Path (Join-Path $env:IMAP_CONFIG_DIR 'accounts.json') -Value ($file | ConvertTo-Json -Depth 5)
    return @($Accounts.Keys | ForEach-Object { "IMAP_PASS_$($_.ToUpperInvariant())" })
}
