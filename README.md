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
| `NoTls` | No | `false` | Connects in plain text, for test servers: see [Server Notes](#server-notes) |
| `SkipCertificateCheck` | No | `false` | Accepts any certificate from the server: see [Server Notes](#server-notes) |
| `AllowWrite` | No | `None` | The kinds of change allowed in the mailbox: see [Reading Without Changing Anything](#reading-without-changing-anything) |
| `Policy` | No | - | The policy followed when reading from the account: see [Policies](#policies) |

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
| `IMAP_NO_TLS` | No | `false` | `true` (or `1`) connects in plain text, for test servers: see [Server Notes](#server-notes) |
| `IMAP_SKIP_CERTIFICATE_CHECK` | No | `false` | `true` (or `1`) accepts any certificate from the server: see [Server Notes](#server-notes) |
| `IMAP_ALLOW_WRITE` | No | `false` | The kinds of change allowed in the mailbox, such as `Flags,Move`; `true` (or `1`) allows all: see [Reading Without Changing Anything](#reading-without-changing-anything) |
| `IMAP_POLICY` | No | - | The policy followed when reading, one of those in `accounts.json`: see [Policies](#policies) |

### Reading Without Changing Anything

Gmail has no read-only IMAP password, so ElektoImapPosh guards the mailbox itself: unless an account allows changes, it only reads.

- Commands that change the mailbox (not in this version yet) need the account's permission for each kind of change:

  | Kind | Changes |
  |------|---------|
  | `Flags` | Marking messages as read or unread, starring them |
  | `Move` | Moving messages to another folder, the trash included; nothing is ever deleted |
  | `Labels` | Adding and removing labels, on Gmail |

  `Set-ImapAccount work -AllowWrite Flags, Move` allows those two kinds, `-AllowWrite All` every kind (those that later versions add too), and `-AllowWrite None` takes the permission back. Without accounts, `IMAP_ALLOW_WRITE=Flags,Move`, or `true` for all. A command that would make a change of a kind not allowed stops with a `WriteNotAllowed` error, before it changes anything. In `accounts.json` the setting is a list, `"AllowWrite": ["Flags", "Move"]`, and `true` and `false` are read as all and none.
- Besides, folders are opened read-only (the IMAP command EXAMINE), so the server itself refuses changes to their messages, flags included, and MailKit refuses to send one. Reading a message never marks it as read. EXAMINE covers the folder opened, not the connection: that is why the permission above is checked for every change.

`Get-ImapAccount` shows which kinds of change each account allows.

### Policies

A policy says what the commands may read from the accounts that follow it. It is meant above all for mailboxes read by AI agents: it keeps the full text of some messages, and some attachments, from being read by accident, limits how much one command downloads, and makes your intent explicit. The commands that read messages (not in this version yet) follow it.

```powershell
Set-ImapPolicy agent -DenyFolders 'Finance/*', Junk -DenyReadFrom '*@bank.example' -MaxAgeDays 90 -MaxMessages 200 -MaxMessageSize 25MB
Set-ImapAccount work -Policy agent
Get-ImapPolicy                  # the policies, and the accounts that follow each
```

| Setting | What it does |
|---------|--------------|
| `DenyFolders` | Folders whose messages are listed but not read nor changed: full names, special uses (`Junk`, `Trash`...) or patterns, as `-Folder` takes them |
| `AllowReadFrom` | The senders whose messages may be read in full; those of any other sender are withheld |
| `DenyReadFrom` | The senders whose messages are withheld, even if `AllowReadFrom` names them |
| `AllowAttachmentsFrom` | The senders whose attachments may be saved |
| `AllowAttachmentTypes` | The attachments that may be saved, by MIME type (`application/pdf`, `image/*`) or by file name (`*.pdf`) |
| `DenyAttachmentTypes` | The attachments that may not be saved, even if `AllowAttachmentTypes` names them: denied when either the type or the name matches |
| `MaxAgeDays` | Older messages are not searched nor read |
| `MaxMessages` | How many messages one command may handle |
| `MaxMessageSize` | The largest message read in full, in bytes (`25MB`); of a larger one, only its metadata |
| `MaxAttachmentSize` | The largest attachment that may be saved, in bytes (`10MB`) |
| `TrustAuthenticationResults` | The receiving server whose `Authentication-Results` headers tell an authenticated sender: `mx.google.com` on Gmail |

- Senders are addresses or wildcard patterns (`jp@example.com`, `*@example.com`), read ignoring case. Anyone can write any address as the sender, so the allow lists match only a sender authenticated by the server named in `TrustAuthenticationResults` (the topmost of its headers says that DMARC passed for the domain of the sender); without it, they pass no sender. The deny lists match the sender as the message gives it, since a forged sender there only withholds more.
- An allow list, when given, withholds what it does not name, and a deny list wins over it. An account without a policy allows all reading.
- What a policy withholds is the body and the attachments. The metadata of every message (sender, recipients, subject, date, labels, the names and sizes of its attachments) can always be read, and a message withheld says so, rather than missing without a word.
- `Set-ImapPolicy` changes only the settings given (an empty list or value removes one, and `0` removes a limit), `Get-ImapPolicy` lists the policies and the accounts that follow each, and `Remove-ImapPolicy` removes those that no account follows. Several accounts may follow the same policy. Without accounts, `IMAP_POLICY` names the policy.
- An account whose policy does not exist (in a file edited by hand, say) reads nothing: its commands stop with a `PolicyNotFound` error.
- In `accounts.json`, the policies are kept apart from the accounts, as `"Policies": { "agent": { "DenyFolders": ["Junk"], "MaxMessages": 200 } }`, and an account follows one with `"Policy": "agent"`.

> [!IMPORTANT]
> A policy prevents accidents. It is no protection against an agent, or anyone, that runs commands as you: they can change the policy, edit `accounts.json` or read the stored passwords. Messages are untrusted input, and their senders can be forged. If you do not want to trust an agent with your mail, do not give it this tool.

### Server Notes

- The connection is always encrypted: TLS from the start on port 993, and STARTTLS on any other port, required (a server that does not offer it is refused, rather than read in plain text).
- `NoTls` (`Set-ImapAccount <name> -NoTls`, or `IMAP_NO_TLS=true`) connects in plain text, password included. It is meant for test servers on your own machine that have no TLS, such as [smtp4dev](https://github.com/rnwood/smtp4dev). Always use TLS with a real mailbox, and be responsible.
- The server's certificate is checked: issued by an authority the machine trusts, for the name of the server, and in date. `SkipCertificateCheck` (`Set-ImapAccount <name> -SkipCertificateCheck`, or `IMAP_SKIP_CERTIFICATE_CHECK=true`) accepts any certificate, for servers with one of their own and for test servers: the connection is still encrypted, but nothing proves that the other end is the server you meant. Gmail never needs it. Be responsible.
- Both are settings of the account, as they are of its server, so every command that reads from it connects the same way. `-NoTls:$false` and `-SkipCertificateCheck:$false` turn them off.
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
