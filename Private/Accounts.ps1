# Accounts: named sets of IMAP settings kept in accounts.json, like the accounts of ElektoMailPosh but not
# shared with them: each tool keeps its own, so reading can have an app password of its own. An account is
# self-contained: while one is in use, the IMAP_* environment variables are ignored (its password may still
# come from IMAP_PASS_<ACCOUNT>, see PasswordStore.ps1).

$script:AccountSettingNames = @('Server', 'Port', 'User')
$script:AccountNamePattern = '^[A-Za-z0-9][A-Za-z0-9_.-]*$'
$script:DefaultServer = 'imap.gmail.com'
$script:DefaultPort = 993
$script:EnvironmentVariableNames = @('IMAP_SERVER', 'IMAP_PORT', 'IMAP_USER', 'IMAP_PASS')

# Account names are keys of dictionaries, where PowerShell gives a key precedence over a property of the
# same name: an account called "Keys" would hide .Keys. So the names are always listed with .psbase.Keys.

# The folder of accounts.json (and, outside Windows, of the password files): IMAP_CONFIG_DIR, or else
# ElektoImapPosh in the user's configuration folder (%APPDATA% on Windows, ~/.config elsewhere)
function Get-AccountDirectory {
    # A relative IMAP_CONFIG_DIR is resolved here against the current location: the .NET file calls that
    # keep the passwords would resolve it against the process folder, which Set-Location does not change
    if ($env:IMAP_CONFIG_DIR) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($env:IMAP_CONFIG_DIR) }
    # Without DoNotVerify, a folder that does not exist yet (~/.config of a new Linux user, a container)
    # comes back as '', and even reading by the IMAP_* variables would fail
    return Join-Path ([Environment]::GetFolderPath('ApplicationData', 'DoNotVerify')) 'ElektoImapPosh'
}

function Get-AccountFilePath {
    return Join-Path (Get-AccountDirectory) 'accounts.json'
}

# The settings in the IMAP_* environment variables. There is no fallback to the SMTP_* variables of
# ElektoMailPosh: a mailbox opened with credentials meant for sending, or for another mailbox, is a
# mistake better reported than made.
function Get-EnvironmentConfiguration {
    $port = $script:DefaultPort
    if ($env:IMAP_PORT) {
        if (-not [int]::TryParse($env:IMAP_PORT, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            throw "The environment variable IMAP_PORT must be a number from 1 to 65535, not '$env:IMAP_PORT'."
        }
    }
    return @{
        Server   = if ($env:IMAP_SERVER) { $env:IMAP_SERVER } else { $script:DefaultServer }
        Port     = $port
        User     = $env:IMAP_USER
        Password = $env:IMAP_PASS
    }
}

# Reads the accounts file into Path, Default (an account name or $null) and Accounts (name -> settings,
# both looked up ignoring case). Returns $null when there is no file; throws when it is not valid.
# ConvertFrom-Json keeps the case of the keys, and keeps apart keys that differ only in case. The rest
# of the module ignores case (as do the Credential Manager and the IMAP_PASS_<ACCOUNT> variables), so
# the keys, account names and settings of the file are read ignoring case too, and two that differ only
# in case are an error rather than one of them lost.
function Read-AccountFile {
    $path = Get-AccountFilePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    try {
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        throw "The accounts file '$path' is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $json) { $json = @{} }
    if ($json -isnot [System.Collections.IDictionary]) { throw "The accounts file '$path' must hold a JSON object." }
    $data = @{}
    foreach ($entry in $json.GetEnumerator()) {
        $key = 'Default', 'Accounts' | Where-Object { $_ -eq $entry.Key }
        if (-not $key) { throw "Unknown key '$($entry.Key)' in the accounts file '$path'." }
        if ($data.ContainsKey($key)) { throw "The key '$key' is twice in the accounts file '$path', in different case." }
        $data[$key] = $entry.Value
    }

    $accounts = [ordered]@{}
    if ($null -ne $data.Accounts) {
        if ($data.Accounts -isnot [System.Collections.IDictionary]) { throw "'Accounts' in '$path' must be a JSON object." }
        foreach ($entry in $data.Accounts.GetEnumerator()) {
            $name = $entry.Key
            if ($name -notmatch $script:AccountNamePattern) {
                throw "Invalid account name '$name' in '$path': use letters, digits, '.', '-' and '_', starting with a letter or digit."
            }
            $sameName = @($accounts.psbase.Keys | Where-Object { $_ -eq $name })
            if ($sameName) { throw "The accounts '$($sameName[0])' and '$name' in '$path' differ only in case, which makes them the same account: rename or remove one." }
            if ($entry.Value -isnot [System.Collections.IDictionary]) { throw "Account '$name' in '$path' must be a JSON object." }

            $settings = [ordered]@{}
            foreach ($setting in $entry.Value.GetEnumerator()) {
                $key = $script:AccountSettingNames | Where-Object { $_ -eq $setting.Key }
                if (-not $key) {
                    throw "Unknown setting '$($setting.Key)' in account '$name' of '$path'. Settings: $($script:AccountSettingNames -join ', ')."
                }
                if ($settings.Contains($key)) { throw "The setting '$key' is twice in account '$name' of '$path', in different case." }
                $value = $setting.Value
                if ($key -eq 'Port') {
                    if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt 65535) { throw "Port of account '$name' in '$path' must be a number from 1 to 65535." }
                    $value = [int]$value
                } elseif ($value -isnot [string]) {
                    throw "$key of account '$name' in '$path' must be a string."
                }
                $settings[$key] = $value
            }
            if (-not $settings.Server -or -not $settings.User) { throw "Account '$name' in '$path' needs both Server and User." }
            $accounts[$name] = $settings
        }
    }

    $default = $data.Default
    if ($default) {
        $match = @($accounts.psbase.Keys | Where-Object { $_ -eq $default })
        if (-not $match) { throw "The default account '$default' is not one of the accounts in '$path'." }
        $default = $match[0]
    } else {
        $default = $null
    }

    return @{ Path = $path; Default = $default; Accounts = $accounts }
}

# Writes the accounts file, settings in a fixed order and without the empty ones
function Write-AccountFile([string]$Default, [System.Collections.IDictionary]$Accounts) {
    $path = Get-AccountFilePath
    $data = [ordered]@{}
    if ($Default) { $data.Default = $Default }
    $data.Accounts = [ordered]@{}
    foreach ($name in $Accounts.psbase.Keys) {
        $settings = [ordered]@{}
        foreach ($key in $script:AccountSettingNames) {
            $value = $Accounts[$name][$key]
            if ($null -eq $value -or "$value" -eq '') { continue }
            $settings[$key] = $value
        }
        $data.Accounts[$name] = $settings
    }

    # A failure stops the caller here, before it stores or deletes a password that would then not match
    New-Item -ItemType Directory -Path (Split-Path -Path $path) -Force -ErrorAction Stop | Out-Null
    Set-Content -LiteralPath $path -Value ($data | ConvertTo-Json -Depth 5) -Encoding utf8NoBOM -ErrorAction Stop
}

# The name of an account as the file spells it, or $null when the file has no such account
function Find-AccountName($File, [string]$Name) {
    if (-not $File) { return $null }
    return @($File.Accounts.psbase.Keys | Where-Object { $_ -eq $Name })[0]
}

# The accounts a command reads from, given its -Account: the accounts of the file that match each pattern,
# and each name without wildcards as given (Resolve-ImapConfiguration reports one that does not exist),
# once each; '' without -Account, for the default account or else the IMAP_* environment variables
function Resolve-ImapAccountName([string[]]$Account) {
    if (-not $Account) { return '' }
    $file = $null
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in $Account) {
        $found = if (-not [WildcardPattern]::ContainsWildcardCharacters($pattern)) { $pattern }
        else {
            if (-not $file) { $file = Read-AccountFile }
            $matching = @(if ($file) { $file.Accounts.psbase.Keys | Where-Object { $_ -like $pattern } })
            if (-not $matching) { Write-Verbose "No account matches '$pattern'." }
            $matching
        }
        foreach ($name in $found) {
            if (-not ($names | Where-Object { $_ -eq $name })) { $names.Add($name) }
        }
    }
    return $names
}

# The settings a command connects with: those of the account given, or of the default account of the
# file, or else the IMAP_* environment variables. Reports an error of the command ($Cmdlet is its
# $PSCmdlet) and returns $null when the account does not exist or has no password, or when there is no
# account and the variables lack the user or the password; throws when the file or the variables cannot
# be read.
function Resolve-ImapConfiguration($Cmdlet, [string]$Account) {
    $file = Read-AccountFile
    if (-not $Account -and $file) { $Account = $file.Default }

    if (-not $Account) {
        $settings = Get-EnvironmentConfiguration
        if (-not $settings.User -or -not $settings.Password) {
            Write-ImapError $Cmdlet 'There is no account to read from: create one with Set-ImapAccount, or set the environment variables IMAP_USER and IMAP_PASS.' 'NoConfiguration' ObjectNotFound $null
            return $null
        }
        $settings.Account = $null
        $settings.PasswordSource = 'IMAP_PASS'
        return $settings
    }

    $name = Find-AccountName $file $Account
    if (-not $name) {
        $message = if (-not $file) { "There is no account '$Account': the accounts file '$(Get-AccountFilePath)' does not exist." }
        else { "There is no account '$Account' in '$($file.Path)'. Accounts: $($file.Accounts.psbase.Keys -join ', ')." }
        Write-ImapError $Cmdlet $message 'AccountNotFound' ObjectNotFound $Account
        return $null
    }

    $password = Get-AccountPassword $name
    if (-not $password) {
        Write-ImapError $Cmdlet (Get-MissingPasswordMessage $name) 'PasswordMissing' ObjectNotFound $name
        return $null
    }

    $accountSettings = $file.Accounts[$name]
    return @{
        Account        = $name
        Server         = $accountSettings.Server
        Port           = if ($accountSettings.Port) { $accountSettings.Port } else { $script:DefaultPort }
        User           = $accountSettings.User
        Password       = $password.Password
        PasswordSource = $password.Source
    }
}
