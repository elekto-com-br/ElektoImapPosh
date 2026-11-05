# Account passwords. The environment variable IMAP_PASS_<ACCOUNT> comes first (CI, containers, systemd);
# otherwise the password is kept where the platform keeps such secrets:
# - Windows: the Credential Manager, as the generic credential "ElektoImapPosh:<account>", encrypted by
#   DPAPI with the user's logon, like any password Windows remembers.
# - Linux and macOS: the file secrets/<account> in the accounts folder, readable only by its owner
#   (mode 600, the folder 700), as msmtp, ssh and .pgpass do on machines without a desktop keyring.
#   A file that others can read is refused.

$script:CredentialTargetPrefix = 'ElektoImapPosh:'

function Get-PasswordVariableName([string]$Account) {
    return 'IMAP_PASS_' + ($Account.ToUpperInvariant() -creplace '[^A-Z0-9]', '_')
}

function Get-PasswordFilePath([string]$Account) {
    return Join-Path (Join-Path (Get-AccountDirectory) 'secrets') $Account.ToLowerInvariant()
}

# How to give an account its password, for the error raised when it has none
function Get-MissingPasswordMessage([string]$Account) {
    return "Account '$Account' has no password. Store it with: Set-ImapAccount -Name $Account -Password (Read-Host -AsSecureString 'Password')" +
        " (or set the environment variable $(Get-PasswordVariableName $Account))."
}

# Compiles, once per session, the calls to the Windows Credential Manager
function Initialize-CredentialManager {
    if ('ElektoImapPosh.CredentialManager' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ElektoImapPosh
{
    public static class CredentialManager
    {
        private const int CRED_TYPE_GENERIC = 1;
        private const int CRED_PERSIST_LOCAL_MACHINE = 2;
        private const int ERROR_NOT_FOUND = 1168;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, int type, int flags);

        [DllImport("advapi32.dll")]
        private static extern void CredFree(IntPtr buffer);

        // The password of the generic credential, or null when there is none
        public static string Read(string target)
        {
            IntPtr pointer;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out pointer))
            {
                int error = Marshal.GetLastWin32Error();
                if (error == ERROR_NOT_FOUND) return null;
                throw new Win32Exception(error);
            }
            try
            {
                CREDENTIAL credential = Marshal.PtrToStructure<CREDENTIAL>(pointer);
                if (credential.CredentialBlobSize == 0) return string.Empty;
                return Marshal.PtrToStringUni(credential.CredentialBlob, credential.CredentialBlobSize / 2);
            }
            finally
            {
                CredFree(pointer);
            }
        }

        // Creates or replaces the generic credential; the password is stored as UTF-16, as cmdkey does
        public static void Write(string target, string userName, string password)
        {
            CREDENTIAL credential = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = target,
                UserName = userName,
                CredentialBlobSize = password.Length * 2,
                CredentialBlob = Marshal.StringToCoTaskMemUni(password),
                Persist = CRED_PERSIST_LOCAL_MACHINE
            };
            try
            {
                if (!CredWrite(ref credential, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally
            {
                Marshal.ZeroFreeCoTaskMemUnicode(credential.CredentialBlob);
            }
        }

        // False when there was no such credential
        public static bool Delete(string target)
        {
            if (CredDelete(target, CRED_TYPE_GENERIC, 0)) return true;
            int error = Marshal.GetLastWin32Error();
            if (error == ERROR_NOT_FOUND) return false;
            throw new Win32Exception(error);
        }
    }
}
'@
}

# The stored password of the account, or $null when none is stored
function Read-StoredPassword([string]$Account) {
    if ($IsWindows) {
        Initialize-CredentialManager
        return [ElektoImapPosh.CredentialManager]::Read($script:CredentialTargetPrefix + $Account)
    }

    $path = Get-PasswordFilePath $Account
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $othersAccess = [IO.UnixFileMode]'GroupRead, GroupWrite, GroupExecute, OtherRead, OtherWrite, OtherExecute'
    if ([IO.File]::GetUnixFileMode($path) -band $othersAccess) {
        throw "The password file '$path' can be read by other users. Restrict it with: chmod 600 '$path'"
    }
    # The file may be written by hand (echo, an editor), which ends it with a newline that is not part of the
    # password; one that really ends in CR or LF cannot be typed at Read-Host
    return ([IO.File]::ReadAllText($path)).TrimEnd("`r", "`n")
}

function Save-StoredPassword([string]$Account, [string]$User, [string]$Secret) {
    if ($IsWindows) {
        Initialize-CredentialManager
        [ElektoImapPosh.CredentialManager]::Write($script:CredentialTargetPrefix + $Account, $User, $Secret)
        return
    }

    $path = Get-PasswordFilePath $Account
    $ownerOnly = [IO.UnixFileMode]'UserRead, UserWrite'
    $directory = Split-Path -Path $path
    [IO.Directory]::CreateDirectory($directory, $ownerOnly -bor [IO.UnixFileMode]::UserExecute) | Out-Null
    [IO.File]::SetUnixFileMode($directory, $ownerOnly -bor [IO.UnixFileMode]::UserExecute)
    # The mode is set before anything is written, so the password is never in a file others can read
    if (Test-Path -LiteralPath $path) { [IO.File]::SetUnixFileMode($path, $ownerOnly) }
    $options = [IO.FileStreamOptions]@{ Mode = 'Create'; Access = 'Write'; UnixCreateMode = $ownerOnly }
    $stream = [IO.FileStream]::new($path, $options)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Secret)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
}

# False when no password was stored
function Clear-StoredPassword([string]$Account) {
    if ($IsWindows) {
        Initialize-CredentialManager
        return [ElektoImapPosh.CredentialManager]::Delete($script:CredentialTargetPrefix + $Account)
    }

    $path = Get-PasswordFilePath $Account
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    # A file that stays is an error that stops the caller, not a password reported as deleted
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    return $true
}

# The password of the account and where it came from (Environment, CredentialManager or File), or
# $null when it has none
function Get-AccountPassword([string]$Account) {
    $password = [Environment]::GetEnvironmentVariable((Get-PasswordVariableName $Account))
    if ($password) { return @{ Password = $password; Source = 'Environment' } }

    $password = Read-StoredPassword $Account
    if ($password) { return @{ Password = $password; Source = if ($IsWindows) { 'CredentialManager' } else { 'File' } } }
    return $null
}
