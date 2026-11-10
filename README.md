# ElektoImapPosh

[![License](https://img.shields.io/github/license/elekto-com-br/ElektoImapPosh)](LICENSE)

A PowerShell module for reading email by IMAP, from several accounts on the same machine: list folders, search messages and Gmail conversations, read their text, save their attachments or a message whole, without marking anything as read. Gmail and Google Workspace come first. It is the reading companion of [ElektoMailPosh](https://github.com/elekto-com-br/ElektoMailPosh), which sends.

> [!NOTE]
> Under development: the first version, 0.1.0, is not on the PowerShell Gallery yet.

## Before Giving It to an AI Agent

> [!WARNING]
> If you give this module to an AI agent, you do so at your own risk: **the responsibility for whatever comes of it rests entirely with you, and in no way with Elekto or the authors of this module.** It is provided as is, with no warranty of any kind (see the [license](LICENSE)). Caveat emptor.

This is no prohibition: the policies were made for agents (see [Policies](#policies)). But think it through, and be careful:

- **Your mail leaves your machine.** Unless the model runs on your own machine, what an agent reads with this module goes to the provider of its model (Anthropic, OpenAI, Google, Microsoft or another), under that provider's terms and privacy policy: the senders, recipients and subjects of the messages it lists, the text of those it reads, the files it opens. Your mail holds the personal data of others too (clients, colleagues, family). Are you allowed to share it with that provider, by your contracts and by the law where you are (LGPD in Brazil, GDPR in Europe)?
- **Mail is untrusted input.** Anyone can send you a message, write in it text that an agent may take for instructions (prompt injection), and put any address in it as the sender. The module keeps out of what it returns the characters that would hide text from you or drive your terminal, but no tool can tell an instruction from a message. Look at what an agent means to do after reading mail before you let it act, above all when it would send, buy, pay or delete.
- **Never let instructions reach an agent by mail.** Do not set up an agent that reads a mailbox and does what its messages ask, not even those of a sender you trust: a sender can be forged, and a reply or a forward carries the words of others.
- **Keep private what should stay private.** Unlike a connector that hands an agent the whole mailbox, a policy keeps from it the text and the attachments of the senders and folders you choose (your bank, your doctor, a client's affairs), and limits how far back it searches and how much one command downloads. Start with a narrow policy, and widen it as you learn what the agent needs.
- **A policy prevents accidents, not misuse.** The metadata of every message (senders, recipients, subjects, the names of attachments) can always be read. An agent that runs commands as you can change the policy, edit the accounts file or read the stored passwords, and agents can be very creative in finding a way to carry out a task. If you do not want to trust an agent with your mail, do not give it this tool.

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

The file may be a link, as GNU stow makes one into a dotfiles repository: the file it points to is the one written, and the link stays.

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

A policy says what the commands may read from the accounts that follow it. It is meant above all for mailboxes read by AI agents: it keeps the full text of some messages, and some attachments, from being read by accident, limits how much one command downloads, and makes your intent explicit. The commands that read messages follow it: `Get-ImapMessage` and `Get-ImapThread` say of each message whether its body may be read, and why not, `Read-ImapMessage` refuses to read one it withholds, and `Save-ImapAttachment` and `Save-ImapMessage` refuse to save it.

```powershell
Set-ImapPolicy agent -DenyFolders 'Finance/*', Junk -DenyReadFrom '*@bank.example' -MaxAgeDays 90 -MaxMessages 200 -MaxMessageSize 25MB
Set-ImapAccount work -Policy agent
Get-ImapPolicy                  # the policies, and the accounts that follow each
```

| Setting | What it does |
|---------|--------------|
| `DenyFolders` | Folders whose messages are listed but not read nor changed: full names, special uses (`Junk`, `Trash`...) or patterns, as `-Folder` takes them (only `*` and `?` are wildcards: `'[Gmail]/*'` is every system folder of Gmail). On Gmail, also the messages with their label, wherever they are read from |
| `AllowReadFrom` | The senders whose messages may be read in full; those of any other sender are withheld |
| `DenyReadFrom` | The senders whose messages are withheld, even if `AllowReadFrom` names them |
| `AllowAttachmentsFrom` | The senders whose attachments may be saved, authenticated as for `AllowReadFrom` |
| `AllowAttachmentTypes` | The attachments that may be saved, by MIME type (`application/pdf`, `image/*`) or by the name of the file (`*.pdf`) |
| `DenyAttachmentTypes` | The attachments that may not be saved, even if `AllowAttachmentTypes` names them: denied when either the type or the name of the file matches |
| `MaxAgeDays` | Older messages are not searched nor read: every search is narrowed to these days |
| `MaxMessages` | How many messages of each account one command may handle, over all its folders |
| `MaxMessageSize` | The largest message read in full, in bytes (`25MB`); of a larger one, only its metadata |
| `MaxAttachmentSize` | The largest attachment that may be saved, in bytes (`10MB`), told before it is downloaded |
| `TrustAuthenticationResults` | The receiving server whose `Authentication-Results` headers tell an authenticated sender: `mx.google.com` on Gmail |
| `UseXOriginalFrom` | The allow lists judge the sender behind a message that a Google Group of your own domain relays (see below) |
| `TrustSameDomain` | The allow lists take for authenticated a colleague of your own domain, whose message comes with no `Authentication-Results`: off by default (see [Gmail and Google Workspace](#gmail-and-google-workspace)) |

- Senders are addresses or wildcard patterns (`jp@example.com`, `*@example.com`), read ignoring case. Anyone can write any address as the sender, so the allow lists match only a sender authenticated by the server named in `TrustAuthenticationResults`: the topmost of its headers says that DMARC passed for the domain of the sender, or for a domain it is part of (Gmail writes `header.from=example.com` for a sender at `news.example.com`), or, when it gives no DMARC result at all, that a DKIM signature of that very domain passed. Without it, they pass no sender. A pattern still names addresses: `*@example.com` does not match `news@news.example.com`, so give `'*@example.com', '*@*.example.com'` for a domain and its subdomains.
- The deny lists match the sender as the message gives it, and wherever it gives it: the From, the Sender, the Reply-To, and the `X-Original-From` of a Google Group. A forged sender there only withholds more.
- Your own messages, in the sent folder, have no such header: they count as authenticated, so an allow list that names your address lets them be read. The sent folder is the one the server marks so, or else, on a server that marks none, the folder named `Sent`; on Gmail, the messages with the label `\Sent` too.
- A Google Group writes its own address in the From of each message it relays (`'Client' via Support <support@example.com>`), and the sender's in `Reply-To` and `X-Original-From`. To an allow list, the sender is then the group: a list that names the group, or your whole domain (`*@example.com`, for your colleagues), passes whatever the group relays, whoever wrote it. With `UseXOriginalFrom` (`Set-ImapPolicy support -UseXOriginalFrom`), the allow lists judge the sender behind the group instead, but only when all of this holds, since anyone can write that header: the From is of the domain of the mailbox's user (a group of your own), it is authenticated, and the ARC result in the topmost `Authentication-Results`, which the group sealed when it took the message (`arc=pass (... dmarc=pass fromdomain=client.example)`), says that DMARC passed for the domain of `X-Original-From`, or for a domain it is part of. When a message misses any of it, its From is judged, as without the switch, and the list must name the sender in `X-Original-From` as well, so that a sender the group did not vouch for never passes as the group; `Withheld` says what it missed. It takes reading headers to set up; `Read-ImapMessage` does not show them, but Gmail's "Show original" does. It is meant for Google Workspace, whose domain is yours: on a `gmail.com` mailbox, every Gmail user is of your own domain, and only the ARC result tells a group's message from a forged one.
- An allow list, when given, withholds what it does not name, and a deny list wins over it. An account without a policy allows all reading.
- Patterns ignore case the same way in every culture, Turkish included, where `I` is not the capital of `i` (`*@client.example` matches `X@CLIENT.EXAMPLE` there too), and take a name written decomposed in Unicode, as macOS writes names, for the same name written composed. So do `-Folder`, `-Name`, `-ContentType` and `-Account`, and the names of accounts and policies.
- A message is saved whole (`Save-ImapMessage`) only when its body may be read and every one of its parts may be saved, by the rules below: the `.eml` carries them all.
- An attachment is saved only from a message whose body may be read, and only when the rules on attachments let it. So `MaxMessageSize` bounds the attachments too: a message larger than it has none saved, whatever `MaxAttachmentSize` says. They take the name the file is saved under, not the one the message gives: an attachment named `x.exe.` would be saved as `x.exe` (Windows drops the dot), and `*.exe` denies it. The MIME type is the one the sender declares, and clients name the same kind of file differently (Outlook sends a zip as `application/x-zip-compressed`, not `application/zip`), so a name says more of what a file is: `-AllowAttachmentTypes '*.pdf'` rather than `application/pdf` alone.
- What a policy withholds is the body and the attachments. The metadata of every message (sender, recipients, subject, date, labels, the names and sizes of its attachments) can always be read, and a message withheld says so, rather than missing without a word: `Get-ImapMessage` lists it, with the reason in its property `Withheld`, and `Read-ImapMessage` refuses it with a `MessageWithheld` error that gives the reason, having downloaded nothing of it but its metadata.
- On Gmail, a label is a folder, a message is in the folder of each of its labels, and All Mail holds them all. A message with the label of a denied folder is therefore withheld wherever it is read from: All Mail (where `-Query` searches), the inbox or another label. The system labels (`\Inbox`, `\Sent`, `\Important`...) stand for their special folders. Gmail marks no folder as the one of `\Important`, so name it by its special use: `DenyFolders Important` withholds the messages with that label, wherever they are read from, while the full name of that folder (`'[Gmail]/Important'`) withholds only what is read from it.
- A command never goes beyond the limits: `-Since` earlier than `MaxAgeDays` allows is narrowed to its days, with a warning, and `-First` is lowered to what `MaxMessages` leaves; when that leaves messages out, a warning says how many.
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
- The folders are those of your own namespaces, as the server gives them, and the inbox, also on a server whose folders all sit under it (`INBOX.Sent`, as Courier, Cyrus and the Dovecot of cPanel name them). Folders that others share with you, and those of other users, are not listed nor read.

### Gmail and Google Workspace

Gmail and Google Workspace come first, and their ways are followed where IMAP alone would mislead. What was seen on real mailboxes:

- They need an [app password](https://myaccount.google.com/apppasswords), which requires 2-Step Verification. In Google Workspace, the administrator can turn app passwords off, and IMAP must be enabled for the users in the Admin console.
- A label is a folder, a message is in the folder of each of its labels, and All Mail holds them all, but for the trash and the spam. The `Labels` of a message leave out the label of the folder it is read from, as Gmail gives them: read from the inbox, a message has no `\Inbox`; read from All Mail, it has them all. `-Query` searches All Mail, as the search box of Gmail does. The names of the special folders are translated (`[Gmail]/E-mails enviados`), so `-Folder` takes their special use (`Sent`, `All`...), the same in any language.
- Gmail marks no folder as the one of `\Important`: `-Folder Important` is a `FolderNotFound` error, and `Get-ImapFolder` shows that folder without a special use. Give its full name (`'[Gmail]/Important'`, translated as the others), or search it: `Get-ImapMessage -Query 'is:important'`. In a policy, `DenyFolders Important` withholds the messages with the label `\Important` (see [Policies](#policies)).
- The categories of the inbox (Primary, Social, Promotions, Updates, Forums, Purchases, Reservations) are no folders nor labels to IMAP: `Get-ImapFolder` does not list them, and the `Labels` of a message never name them. They can only be searched: `Get-ImapMessage -Query 'category:promotions'`, or `'category:updates is:unread'`. The search of Gmail also knows them by names of its own, undocumented (`label:^smartlabel_promo`). A policy has no rule by category, which is a guess of Gmail's, and `-Query` searches them freely.
- `has:attachment` counts the images that a message shows in its body (the snapshots a camera sends, the logos of a signature), while `HasAttachments` does not: `-Query 'has:attachment'` also lists messages whose `HasAttachments` is `$false`, whose images `Save-ImapAttachment -Inline` saves.
- Gmail writes its own `Authentication-Results` on top of each message it receives (`mx.google.com`, the name for `TrustAuthenticationResults`), above any that came with it, and none on the messages you send. Its DMARC result names the domain whose record it applied: `header.from=example.com` for a sender at `news.example.com`. One that came with the message and claims its name, it removes; those of other servers, and an `X-Original-Authentication-Results`, it keeps as the sender wrote them, below its own. So the policies read only the topmost `Authentication-Results` header, and only when it is of the server named, and never `X-Original-Authentication-Results`.
- On Google Workspace, the mail between users of the same domain comes with no `Authentication-Results` at all, so no colleague is authenticated, and an allow list withholds them. `TrustSameDomain` (`Set-ImapPolicy team -TrustSameDomain`, with `TrustAuthenticationResults`) takes for authenticated a sender of the domain of the account's user whose message carries no results of that server: Google stamps every message from outside, a forged one included, and those results then decide. It is off by default, since a server that does not stamp every message from outside would let a forged colleague through, and it was measured on Google Workspace only.
- Mail kept for years: most messages from before DMARC was common have no DMARC result and no DKIM signature of the sender's own domain, so an allow list of senders withholds most old mail, and its attachments. For a mailbox searched for its history, deny lists (`DenyReadFrom`, `DenyAttachmentTypes`) fit better. Mail migrated into Google Workspace keeps its dates, so `-Since` and `older_than:` find old messages by the day they came.
- A message that a Google Group relays is sealed with ARC by the group, which `UseXOriginalFrom` needs. Older messages, from before the groups sealed them and signed them with their domain, have no such seal, so the sender behind the group is not taken, and passes only when the list names it and the group: their `Withheld` says so.

## Usage

### Testing an Account

`Test-ImapAccount` connects and authenticates, and shows how the connection was secured, whether the server's certificate was checked (`CertificateChecked`, false with `SkipCertificateCheck`, and with `NoTls`, where there is none), the authentication mechanisms the server offers and its capabilities. It reads nothing from the mailbox:

```powershell
Test-ImapAccount work            # the account "work"
Test-ImapAccount                 # the default account, or else the IMAP_* environment variables
Get-ImapAccount | Test-ImapAccount   # every account; one that fails is an error, and the others go on
```

Failures are errors with an id that tells them apart: `ConnectionFailed`, `AuthenticationFailed`, `AccountNotFound`, `PasswordMissing` and `NoConfiguration`. Each one is a single error, also in `-ErrorVariable` and `$Error`. Ctrl+C stops a command at once, even while it waits for a server that does not answer.

A connection that the server drops in the middle of any command is two errors: the one of what was being done (`FolderOpenFailed`, `MessageFetchFailed`...), and `ConnectionLost`. Whatever was left to do in that account is left out, with no error of its own, and the other accounts of `-Account` go on. Run the command again for that account.

### Listing Folders

`Get-ImapFolder` lists the folders that can hold messages, with how many each holds and how many are unread. `-Account` takes several accounts and wildcards, and each folder carries the account it came from; an account that fails is an error, and the others go on. The counts of every folder come in one request from a server with LIST-STATUS, as Gmail is; from one without it, they are asked of each folder, which takes a while on a mailbox with hundreds of folders, and a folder that does not give them is a `FolderStatusFailed` error while the others are listed:

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

Gmail translates the names of its special folders, so `-Folder` also takes their special use, the same in any language: `Inbox`, `All`, `Archive`, `Drafts`, `Flagged`, `Important`, `Junk`, `Sent` and `Trash`. It stands for the folder the server marks so, or else, on a server that marks none, for the folder of that name (Gmail marks no folder `Important`: see [Gmail and Google Workspace](#gmail-and-google-workspace)). `-Folder` takes full folder names too (`'[Gmail]/Sent Mail'`, `Clients/2026`), ignoring case, and wildcards: only `*` and `?`, since brackets are taken as written, so that `'[Gmail]/*'` is every system folder of Gmail; a name that matches no folder is a `FolderNotFound` error, a pattern that matches none is not. Folders piped from `Get-ImapFolder` are taken by their exact full name, so a label of your own named `Sent` stays that label. Each command opens one connection per account and lists its folders once, however many folders it reads.

### Listing Messages

`Get-ImapMessage` searches folders, on the server, and lists the newest messages that match, with their metadata: sender, recipients, subject, the date the server received them, size, flags, whether they have attachments and, on Gmail, their thread and labels. It downloads no body and marks nothing as read. Without `-Folder` it searches the inbox, and `-First` (50 by default) says how many messages of each folder it returns, the newest first:

```powershell
Get-ImapMessage                                      # the 50 newest messages in the inbox of the default account
Get-ImapMessage -Account * -Unread -Since (Get-Date).AddDays(-7)
Get-ImapMessage work -Folder Sent -Subject proposal -First 10
Get-ImapFolder work -Folder 'Clients/*' | Get-ImapMessage -From client.example
```

```
   Folder: INBOX (work)

  Uid Date             Marks                From                           Subject
  --- ----             -----                ----                           -------
12045 2026-11-04 09:12 unread               Ana Souza <ana@client.example> Proposal for 2027
12044 2026-11-04 08:40 attachments withheld Bank <alerts@bank.example>     Your statement
```

- `-From` and `-Subject` find part of the text, ignoring case, and `-Since` takes the day the server received the message. The server makes the search.
- `Date` is when the server received the message, which the sender cannot forge, and the day `-Since` and `MaxAgeDays` go by.
- On Gmail and Google Workspace, `-Query` takes a search as typed in the search box of Gmail, and searches All Mail unless `-Folder` says otherwise: `Get-ImapMessage work -Query 'from:bank.example has:attachment newer_than:30d'`. Elsewhere it is a `QueryNotSupported` error.
- Each message carries its `Account`, `Folder` and `Uid`, which identify it, and `UidValidity`, which changes when the server numbers the folder anew.
- `HasAttachments` says whether the message has a file attached, or shown in its body with a name of its own (as Apple Mail sends a PDF), unless that file is an image: most images shown in a body are logos and signatures. Gmail's `has:attachment` counts those images too (see [Gmail and Google Workspace](#gmail-and-google-workspace)).
- Under a policy, `Withheld` says why the body of a message may not be read: `Get-ImapMessage | Where-Object Withheld | Select-Object From, Subject, Withheld`.
- What the sender writes (the subject, the senders and recipients, the Message-IDs, the names of attachments) comes without what would drive a terminal, reorder the text or hide it from whoever reads it. Control characters (an escape sequence can clear the screen, or write to the clipboard), overrides of direction (which show `fdp.exe` as `exe.pdf`) and the tags of Unicode (text that an AI reads and a person does not see) show as U+FFFD, the replacement character, one for each run of them; a tab or line break shows as a space; the invisible characters that only change how a text is shown (soft hyphen, zero-width space, marks of direction) are removed. Each of those texts is cut to 1000 characters, ending in an ellipsis, but for the name of an address, cut on its own to 200, so that the address after it stays whole; and `From`, `To` and `Cc` keep their first 100 addresses, then an entry that says how many more there were (`... and 9900 more`, with the ellipsis U+2026), so that a message does not flood the context of an agent, and a script that answers everyone fails on that entry rather than leave people out unsaid. The whole message, as the server keeps it, stays in the mailbox.

### Following Gmail Conversations

On Gmail and Google Workspace, `Get-ImapThread` lists the messages of a conversation, as Gmail groups them (the `ThreadId` of each message `Get-ImapMessage` lists): from All Mail, since a conversation spans the inbox, the messages you sent and the labels, the oldest first, as Gmail shows it. Each message comes as `Get-ImapMessage` lists it, so it goes on to `Read-ImapMessage` or `Save-ImapAttachment`. It downloads no body and marks nothing as read:

```powershell
Get-ImapMessage work -Subject proposal -First 1 | Get-ImapThread         # the whole conversation, the replies sent included
Get-ImapThread work -ThreadId 1849112309876543210 | Read-ImapMessage     # its text, the oldest first
Get-ImapMessage work -Unread | Get-ImapThread | Where-Object Labels -Contains '\Sent'
```

- A conversation that comes more than once, as from several of its messages, is listed once. One with no message in All Mail is a `ThreadNotFound` error. The messages in the trash or the spam are not in All Mail, so they are not listed, and Gmail keeps a conversation to 100 messages.
- Under a policy, every message of the conversation is listed, with `Withheld` saying why its body may not be read, as `Get-ImapMessage` says it. `MaxAgeDays` narrows the search, and `MaxMessages` keeps the newest messages of a conversation, with a warning that says how many were left out.
- Conversations are Gmail's: on any other server, `Get-ImapThread` is a `ThreadNotSupported` error, once for each account.

### Reading Messages

`Read-ImapMessage` returns the text of messages, with their metadata and the list of their attachments. The messages usually come from `Get-ImapMessage`, which says where each one is:

```powershell
Get-ImapMessage -First 5 | Read-ImapMessage
Read-ImapMessage work -Folder Inbox -Uid 12045
Get-ImapMessage work -From bank.example -Since (Get-Date).Date | Read-ImapMessage | Where-Object Text -Match 'Total: ([\d.,]+)'
```

- `Text` is the plain text of the message or, when it has none, its HTML as it is; `Format` says which (`Text` or `Html`), and `-Html` gives the HTML first. The text is decoded (base64, quoted-printable, its character set), but HTML is never converted: pipe it to a converter of your choice, such as `pandoc -f html -t plain`.
- A message may have its text in several parts, as Apple Mail sends a file dragged into the middle of the text: `Text` holds all of them, one after another, with an empty line between them, as a mail client shows them. Of a message that has its text both plain and in HTML, `Text` is one of them, never both. A text file is an attachment, not text: a file with a name of its own (`notes.txt`, a log, a CSV) is listed in `Attachments`, and never read as `Text`, even when the message shows it in its body, so that the rules of the policy on attachments hold for it; a message whose only text is such a file has no `Text`, as one whose body is an image.
- The text comes as the subject does (see [Listing Messages](#listing-messages)), without what would drive a terminal or hide text, but with its tabs and line breaks, and whole.
- Only the text of the message is downloaded. Its attachments are listed in `Attachments`, and not downloaded: the name the message gives (`Name`), the name the file would be saved under (`FileName`), the type, the most the file takes (`Size`, told from the message), and why the policy keeps it from being saved, if it does (`Withheld`). A file shown in the body with a name of its own is an attachment too, unless it is an image; the other parts shown in the body, such as prints pasted in it, are listed the same way in `InlineParts`. Nothing is marked as read, and nothing in the message is fetched from the network (images) nor followed (links).
- Messages from the pipeline are read in batches of up to 100: the metadata of the messages of each folder comes in one request to the server, then the text of each, in the order they came. Against Gmail, that takes half the time a message took (each request is a round trip of some 0.4 s), and the first text comes once the batch is complete, or the pipeline ends.
- `-MaxLength` cuts the text, and `Truncated` says so.
- A message that the policy of the account withholds is not read: a `MessageWithheld` error says why. `MaxMessages` limits how many messages of each account one command reads, with a warning that says how many were left out.
- When a folder was numbered anew since its messages were listed (another `UidValidity`), a `UidValidityChanged` error says so, rather than read another message with the same UID. A UID that is not in the folder is a `MessageNotFound` error, and a folder pattern that names more than one folder is `FolderAmbiguous`.

### Saving Attachments

`Save-ImapAttachment` saves the attachments of messages, decoded, as files in a directory, and returns the files. Only the attachments are downloaded, one part at a time:

```powershell
Get-ImapMessage -From bank.example -Since (Get-Date).Date | Save-ImapAttachment -Path ~/Statements -Name *.pdf
Save-ImapAttachment work -Folder Inbox -Uid 12045 -Path .
Get-ImapMessage work -From reports@client.example -First 1 | Save-ImapAttachment -Path ./Reports -Name CPTO.xlsx -Force | ForEach-Object { ./Import-Report.ps1 $_.FullName }
Get-ImapMessage work -From client.example | Save-ImapAttachment -Path ./Prints -Inline -ContentType image/* -UniqueName
```

- A file that a message shows in its body with a name of its own, as Apple Mail sends a PDF, or a client a CSV, is an attachment, unless it is an image. `-Inline` also saves the other parts shown in the body: prints pasted in it, images its HTML shows, photos that a camera sends that way, files without a name. Without it they are left out, since most messages carry logos and signatures so. `-ContentType` picks parts by MIME type, with wildcards: `-Inline -ContentType image/*` saves the images of a message, embedded or attached (signature logos among them).
- On Windows, each file carries the Mark of the Web, as Outlook and the browsers write it (`ZoneId=3` in its stream `Zone.Identifier`): SmartScreen warns before such a program runs, Office opens such a document in Protected View and blocks its macros, and PowerShell under `RemoteSigned` asks for the signature of such a script. A tool that saves attachments must not be the way in of an attack. `Unblock-File` takes the mark off, for a sender you trust: `... | Save-ImapAttachment -Path ./Tools -Name *.ps1 | Unblock-File`. A volume that keeps no such mark (FAT32, exFAT, some network shares, the share of WSL) gets the files without it, and a warning says so.
- A name that comes more than once in a message is numbered, attachments first, then inline parts, each in the order of the message: Gmail names every print pasted in a message `image.png`, saved as `image.png`, `image (2).png`... A part whose content is the same as one saved before from the same message, as a message forwarded by Gmail carries an image both shown and attached, or as Outlook repeats the logos of a signature, is not saved again: `-Verbose` says so, and a warning when the file with that content was already in the directory. Empty files are no copies of each other: each is saved under its name. A part without a name is `attachment`, with the extension of its type (`attachment.jpg`). `-UniqueName` puts the UID of the message before each name (`12045-image.png`), so that files of the same name in several messages do not take each other's names. A UID is unique in its folder only: for messages of several folders or accounts, give each folder a `-Path` of its own.

- The name of an attachment comes from whoever sent the message, so the file gets a name that is safe on any platform: only the last part of the name (`../../x` is saved as `x`, in `-Path`), in the composed form of Unicode (NFC, so that a name macOS writes decomposed is the same name), without the characters Windows refuses, nor control characters, nor the dots and spaces Windows drops at the end, nor characters that reorder or hide text (an override of direction can show `exe.pdf` for `fdp.exe`), nor invisible ones such as the soft hyphen, with `_` before a name Windows keeps for a device (`_CON.txt`, `_NUL .txt`) and for the `~` of a name shaped as the short name Windows gives a long one (`REPORT~1.PDF` is saved as `REPORT_1.PDF`, since it could stand for another file of the directory), and `attachment` when nothing is left. `Read-ImapMessage` shows that name as `FileName`. A message attached is saved as the server keeps it, an `.eml`.
- Names that the shell of Windows acts on by their look alone are changed too, since the Mark of the Web does nothing for them. Explorer hides the extension of shortcuts and a few other types even when it shows the others, so `Invoice.pdf.lnk` shows as `Invoice.pdf`, with the icon the shortcut names, and `Invoice.pdf.pif` is a program; and showing a folder is enough for Explorer to read the icon of a shortcut, which may be on a server of the sender's that Windows then logs in to, giving away a hash of your password, and to read a `desktop.ini`, which customizes the folder. So a file ending in `.lnk`, `.url`, `.pif`, `.scf`, `.website`, `.library-ms`, `.search-ms`, `.searchConnector-ms`, `.appref-ms` and the like, in `.exe.local` (which changes where that program loads its libraries from) or in an extension `{CLSID}` gets `.download` after its name, as browsers name such a download (`Invoice.pdf.lnk.download`, which Explorer shows whole), and `desktop.ini` and `Thumbs.db` get `_` before theirs. The same on every platform, so that a file saved on Linux in a share keeps that name on Windows.
- `-Path` must be a directory of the file system that exists. A file that exists is not replaced without `-Force` (`AttachmentFileExists`); a directory of that name never is, nor a read-only file, nor a file the command saved, `-Force` or not, so that two messages that give the same name do not lose one of them. The sender picks the names, so give `-Force` only for a directory of their own: in a directory of scripts, or in the home directory, an attachment could replace a script or a profile. Each file is written under a temporary name ending in `.part` and then renamed, so whoever watches the directory never sees half a file under its name. A file that cannot be written, such as one another program keeps open, is an `AttachmentWriteFailed` error: only the files written are returned.
- `-Name` takes names or patterns, matched against the name the message gives and the name of the file. `-WhatIf` shows what would be saved, and where, without fetching any attachment.
- Each file carries the `Account`, `Folder` and `Uid` of its message, the name of the `Attachment` in the message, and whether it was `Inline`.
- Under a policy, the attachments of a message it withholds are not saved (`MessageWithheld`), and an attachment or inline part that the rules on attachments keep is an `AttachmentWithheld` error that says why; neither is downloaded. The rules on names take the name the file gets and, when a number or `-UniqueName` changes it, the name written too: both must pass, so a second `secret.pdf`, written as `secret (2).pdf`, is still a `secret.pdf`. So with a name the shell acts on: `DenyAttachmentTypes '*.url'` withholds `Invoice.url`, which would be saved as `Invoice.url.download`. The rules see each file as a whole: a message attached (`.eml`) carries the body and the attachments of another message, whatever its sender, and a zip file other files.
- Whatever name a file gets, it is written in `-Path` and nowhere else: the names are made safe first, and the final path is checked once more (`PathOutsideDirectory`).

### Saving a Message Whole

`Save-ImapMessage` saves one message as the server keeps it, byte for byte (its headers, its text and its attachments), as an `.eml` file that mail clients open, and returns the file. It is not the usual way to read mail, which `Read-ImapMessage` and `Save-ImapAttachment` are: it is for keeping a message as evidence, opening it in a mail client, or reading the headers that tell how it came (`Received`, `Authentication-Results`, `DKIM-Signature`). Nothing is marked as read.

```powershell
Save-ImapMessage work -Uid 12045 -Path .                                         # 12045-<its subject>.eml
Get-ImapMessage work -From bank.example -First 1 | Save-ImapMessage -Path ~/Evidence
Save-ImapMessage work -Folder All -MessageId '<CAF8kLm1x@mail.gmail.com>' -Path ./Messages
```

- It saves one message, and only one: by `-Uid`, or by `-MessageId`, with or without its angle brackets, matched exactly (the server finds the messages whose Message-ID has the text in it, and only the one whose Message-ID is that text is saved). When more than one message comes from the pipeline, or more than one message of the folder has the Message-ID, nothing is saved, nor downloaded: a `MoreThanOneMessage` error says so. So it is when the server finds more than 100 messages with the text in their Message-ID, as it would for a part of one (`gmail.com`): give it whole. To save the attachments of many messages, there is `Save-ImapAttachment`.
- `-Folder` is the inbox by default. On Gmail, `-Folder All` finds a message wherever it is, unless it is in the trash or the spam.
- The file is named after the UID and the subject (`12045-Proposal for 2027.eml`, or `12045.eml` without a subject), made safe as the name of an attachment is, since the sender writes the subject; a `/` in it is `_`. It is written as attachments are: under a temporary name, then renamed; on Windows with the Mark of the Web, as every file saved from a message, which tells Windows and the programs that read it that the file came from the internet; in place of another file only with `-Force` (`MessageFileExists`), and never in place of a directory or a read-only file. Ctrl+C while it is written saves nothing. `-WhatIf` shows the file it would be, without downloading the message.
- Under a policy, the message is saved only when the policy lets it be read, and lets every one of its parts be saved, attachments and inline parts alike, as `Save-ImapAttachment -Inline` would save them: the file carries them all. Otherwise a `MessageWithheld` error says why, and nothing is downloaded. `MaxMessageSize` holds the message by the size the server tells, before it is downloaded, and by its own after. A search by Message-ID, as every search, finds only the messages of the days that `MaxAgeDays` allows.

## Building from Source

Building needs the [.NET SDK](https://dotnet.microsoft.com/download) 10 or later, which restores the mail libraries from NuGet:

```powershell
git clone https://github.com/elekto-com-br/ElektoImapPosh.git
cd ElektoImapPosh
./Build.ps1
Import-Module ./ElektoImapPosh.psd1
```

`Build.ps1` restores the libraries into `lib`, runs the checks and the tests (with Pester 5 or later, when installed) and stages the package at `out/ElektoImapPosh`.

The tests write accounts files and password files, in folders of their own, and never your accounts: they run with `IMAP_CONFIG_DIR`, and `HOME` on Linux and macOS, in a temporary folder, and `Build.ps1` fails if the accounts of your machine changed, comparing the names, sizes and times of their files (and on Windows of the credentials of the module), never what they hold. To keep the tests apart from your machine altogether, `./Tests/Container/Invoke-ContainerBuild.ps1` runs `Build.ps1` in a container (Podman or Docker): without network, as a user that is not root, with the repository mounted read-only and copied inside.

## License

MIT License - see [LICENSE](LICENSE) for details. The mail libraries are under their own MIT licenses: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Author

**JP Negri** - [Elekto Produtos Financeiros](https://github.com/elekto-com-br)
