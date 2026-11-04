# ElektoImapPosh

[![License](https://img.shields.io/github/license/elekto-com-br/ElektoImapPosh)](LICENSE)

A PowerShell module for reading email by IMAP, from several accounts on the same machine: list folders, search messages, read them as plain text and save their attachments, without marking anything as read. Gmail and Google Workspace come first. It is the reading companion of [ElektoMailPosh](https://github.com/elekto-com-br/ElektoMailPosh), which sends.

> [!NOTE]
> Under development: the first version, 0.1.0, is not on the PowerShell Gallery yet.

## Requirements

PowerShell 7.6 or later, on Windows, Linux or macOS. The module carries [MailKitLite and MimeKitLite](THIRD-PARTY-NOTICES.md), MailKit and MimeKit without BouncyCastle, so nothing else needs installing.

ElektoImapPosh cannot share a PowerShell session with a module that loads the full MailKit (such as Mailozaurr): both have the same namespaces, and the import stops when the full one is already loaded. Import ElektoImapPosh first, or use another session.

## Configuration

There are two ways to configure the IMAP settings:

- **Accounts**: named sets of settings, for machines that read more than one mailbox. Best for workstations and servers.
- **Environment variables**: one set of settings, for CI/CD pipelines, containers and machines that read a single mailbox.

When an account is in use (given with `-Account`, or the default account), the `IMAP_*` environment variables are ignored.

The accounts and passwords are not those of [ElektoMailPosh](https://github.com/elekto-com-br/ElektoMailPosh): each module keeps its own, so reading can have an app password of its own, apart from the one for sending. For the same reason, ElektoImapPosh never reads the `SMTP_*` variables.

### Accounts

Create an account with `Set-ImapAccount`, which asks for the password without showing it:

```powershell
Set-ImapAccount -Name work -Server imap.gmail.com -User me@example.com -Password (Read-Host -AsSecureString 'Password') -Default
Set-ImapAccount -Name personal -Server imap.gmail.com -User me@gmail.com -Password (Read-Host -AsSecureString 'Password')
```

`Set-ImapAccount` changes only the settings given (an empty value removes one), `Get-ImapAccount` lists the accounts and where each password comes from, and `Remove-ImapAccount` removes accounts and their stored passwords. Both take wildcards, and `Get-ImapAccount test* | Remove-ImapAccount -WhatIf` shows what would be removed. Account names complete with Tab.

| Setting | Required | Default | Description |
|---------|----------|---------|-------------|
| `Server` | Yes | - | IMAP server address |
| `Port` | No | `993` | IMAP server port |
| `User` | Yes | - | IMAP user name, usually the email address |

The settings are kept in `accounts.json`, in the folder `ElektoImapPosh` of your configuration folder (`%APPDATA%` on Windows, `~/.config` on Linux and macOS, or `$XDG_CONFIG_HOME` when set), or in the folder named by `IMAP_CONFIG_DIR`. It holds no passwords, so it can be read and edited by hand:

```json
{
  "Default": "work",
  "Accounts": {
    "work": { "Server": "imap.gmail.com", "User": "me@example.com" },
    "personal": { "Server": "imap.gmail.com", "Port": 993, "User": "me@gmail.com" }
  }
}
```

The file is read ignoring case, as PowerShell reads names: keys and settings can be written in any case, and `-Account WORK` reads from the account `work`. So two accounts whose names differ only in case are refused, since they would be the same account and share its password; and so are two whose names differ only in `.`, `-` and `_` (`work.prod` and `work-prod`), which would read their password from the same `IMAP_PASS_WORK_PROD`.

#### Where the passwords go

| Platform | Store | Protection |
|----------|-------|------------|
| Windows | Credential Manager, generic credential `ElektoImapPosh:<account>` | Encrypted with your logon (DPAPI), like any password Windows remembers |
| Linux, macOS | File `secrets/<account>` next to `accounts.json` | Readable only by you (mode 600, folder 700), as with msmtp, ssh or `.pgpass`; a file others can read is refused |

On any platform, the environment variable `IMAP_PASS_<ACCOUNT>` (the account name in upper case, other characters than letters and digits as `_`, e.g. `IMAP_PASS_WORK`) takes precedence over the stored password, for pipelines and services that get their secrets from the environment.

On Windows the credential can also be stored or seen with the system tools: `cmdkey /generic:ElektoImapPosh:work /user:me@example.com /pass` asks for the password, and the credentials appear in Control Panel > Credential Manager > Windows Credentials.

> [!WARNING]
> **Scheduled tasks and services:** accounts and their passwords belong to the user who created them, so a task or service that runs as another user (SYSTEM, a service account, root) doesn't see them. On Windows, a scheduled task set to run whether the user is logged on or not with *Do not store password* (logon type S4U) runs as you but can't read the Credential Manager, which needs your logon password to decrypt. Such tasks should use the environment variables.

### Environment Variables

Without accounts, set the IMAP settings via environment variables. This keeps secrets out of your scripts and works with CI/CD secret management.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `IMAP_USER` | Yes | - | IMAP user name, usually the email address |
| `IMAP_PASS` | Yes | - | IMAP password |
| `IMAP_SERVER` | No | `imap.gmail.com` | IMAP server address |
| `IMAP_PORT` | No | `993` | IMAP server port |

### Server Notes

- The connection is always encrypted: TLS from the start on port 993, and STARTTLS on any other port, required (a server that does not offer it is refused, rather than read in plain text).
- `-NoTls` connects in plain text, password included. It is meant for test servers on your own machine that have no TLS, such as [smtp4dev](https://github.com/rnwood/smtp4dev). Always use TLS with a real mailbox, and be responsible.
- Gmail and Google Workspace need an [app password](https://myaccount.google.com/apppasswords), which requires 2-Step Verification. In Google Workspace, the administrator can turn app passwords off, and IMAP must be enabled for the users in the Admin console.

## Usage

### Testing an Account

`Test-ImapAccount` connects and authenticates, and shows how the connection was secured, the authentication mechanisms the server offers and its capabilities. It reads nothing from the mailbox:

```powershell
Test-ImapAccount work            # the account "work"
Test-ImapAccount                 # the default account, or else the IMAP_* environment variables
Get-ImapAccount | Test-ImapAccount   # every account; one that fails is an error, and the others go on
```

Failures are errors with an id that tells them apart: `ConnectionFailed`, `AuthenticationFailed`, `AccountNotFound`, `PasswordMissing` and `NoConfiguration`. Each one is a single error, also in `-ErrorVariable` and `$Error`. Ctrl+C stops a command at once, even while it waits for a server that does not answer.

### Listing Folders

`Get-ImapFolder` lists the folders that can hold messages, with how many each holds and how many are unread. `-Account` takes several accounts and wildcards, and each folder carries the account it came from; an account that fails is an error, and the others go on:

```powershell
Get-ImapFolder                             # the folders of the default account
Get-ImapFolder -Account * -Folder Inbox    # the inbox of every account
Get-ImapFolder work | Where-Object Unread -gt 0
```

```
Account Folder                   SpecialUse Count Unread
------- ------                   ---------- ----- ------
work    INBOX                    Inbox        812      3
work    Clients                                40      0
work    [Gmail]/E-mails enviados Sent        1204      0
work    [Gmail]/Todos os e-mails All         9731      3
```

Gmail translates the names of its special folders, so `-Folder` also takes their special use, the same in any language: `Inbox`, `All`, `Archive`, `Drafts`, `Flagged`, `Important`, `Junk`, `Sent` and `Trash`. It stands for the folder the server marks so, or else, on a server that marks none, for the folder of that name. `-Folder` takes full folder names too (`'[Gmail]/Sent Mail'`, `Clients/2026`), ignoring case, and wildcards; a name that matches no folder is a `FolderNotFound` error, a pattern that matches none is not. Folders piped from `Get-ImapFolder` are taken by their exact full name, so a label of your own named `Sent` stays that label. Each command opens one connection per account and lists its folders once, however many folders it reads.

## Building from Source

Building needs the [.NET SDK](https://dotnet.microsoft.com/download) 10 or later, which restores the mail libraries from NuGet:

```powershell
git clone https://github.com/elekto-com-br/ElektoImapPosh.git
cd ElektoImapPosh
./Build.ps1
Import-Module ./ElektoImapPosh.psd1
```

`Build.ps1` restores the libraries into `lib`, runs the checks and the tests (with Pester 5 or later, when installed) and stages the package at `out/ElektoImapPosh`.

## License

MIT License - see [LICENSE](LICENSE) for details. The mail libraries are under their own MIT licenses: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Author

**JP Negri** - [Elekto Produtos Financeiros](https://github.com/elekto-com-br)
