# The mail libraries, MimeKitLite and MailKitLite, which Build.ps1 restores from NuGet into ./lib (from the
# source, run it once before importing). The full MailKit and MimeKit have the same namespaces, and a type
# literal such as [MailKit.Net.Imap.ImapClient] resolves to the assembly loaded first: when another module
# (Mailozaurr, for one) has loaded them, the commands would run on them without a word, so the import stops.
# Loaded first, the Lite ones keep the type literals even if the full ones come later.
foreach ($name in 'MailKit', 'MimeKit') {
    $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $name } | Select-Object -First 1
    if ($loaded) {
        throw "ElektoImapPosh uses MailKitLite and MimeKitLite, but this session has already loaded the full $name ($($loaded.Location)), probably through another module. Import ElektoImapPosh first, or in a new session."
    }
}
foreach ($name in 'MimeKitLite', 'MailKitLite') {
    $path = Join-Path (Join-Path $PSScriptRoot 'lib') "$name.dll"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "'$path' is missing. From the source, run ./Build.ps1 once: it restores the mail libraries."
    }
    # .NET keeps the version loaded first, and the assembly version names only major and minor: a session
    # that imported an older ElektoImapPosh would run this one on the older library
    $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $name } | Select-Object -First 1
    if ($loaded) {
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion
        $loadedVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($loaded.Location).FileVersion
        if ($version -ne $loadedVersion) {
            throw "This session has already loaded $name $loadedVersion ($($loaded.Location)), and this ElektoImapPosh needs $version. Import it in a new session."
        }
        continue
    }
    Add-Type -Path $path
}

#region Functions: in the package, Build.ps1 puts the functions themselves in place of this loader
foreach ($folder in 'Private', 'Public') {
    Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}
#endregion

# Tab completion of account names
$accountCompleter = {
    # Of the arguments a completer gets (command, parameter, word, ...), only the word matters here
    $wordToComplete = $args[2]
    $file = try { Read-AccountFile } catch { $null }
    if ($file) { $file.Accounts.psbase.Keys | Where-Object { $_ -like "$wordToComplete*" } }
}
Register-ArgumentCompleter -CommandName Test-ImapAccount, Get-ImapFolder -ParameterName Account -ScriptBlock $accountCompleter
Register-ArgumentCompleter -CommandName Get-ImapAccount, Set-ImapAccount, Remove-ImapAccount -ParameterName Name -ScriptBlock $accountCompleter

# Tab completion of policy names
$policyCompleter = {
    $wordToComplete = $args[2]
    $file = try { Read-AccountFile } catch { $null }
    if ($file) { $file.Policies.psbase.Keys | Where-Object { $_ -like "$wordToComplete*" } }
}
Register-ArgumentCompleter -CommandName Get-ImapPolicy, Set-ImapPolicy, Remove-ImapPolicy -ParameterName Name -ScriptBlock $policyCompleter
Register-ArgumentCompleter -CommandName Set-ImapAccount -ParameterName Policy -ScriptBlock $policyCompleter

# Tab completion of the special uses, the names of folders that work on any server and in any language
Register-ArgumentCompleter -CommandName Get-ImapFolder -ParameterName Folder -ScriptBlock {
    $wordToComplete = $args[2]
    $script:SpecialUseNames | Where-Object { $_ -like "$wordToComplete*" }
}
