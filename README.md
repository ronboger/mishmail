# PerfectMail

A native, local-first Gmail client for macOS. SwiftUI, Gmail REST API, SQLite.
No server, no telemetry — nothing leaves your Mac except calls to Google's own
API (and, optionally, a local Ollama model that also never leaves the machine).

> **Status:** early but usable (v0.x). Built for people who want a fast,
> keyboard-driven, Notion-Mail-style inbox that runs entirely on their own
> hardware. Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

<!-- Add a screenshot or short GIF here — it's the single most useful thing a
     UI project's README can have. e.g. ![PerfectMail](Design/screenshot.png) -->

## Features

- **Unified multi-account inbox** — connect several Google accounts; view them
  together or scoped to one, with per-account nicknames and send-as names.
- **Saved views & live filters** — build a filtered inbox from ~18 dimensions
  (label, category, from/to/cc/bcc, subject, date, calendar-invite, read
  state…) and save it as a reusable view.
- **Keyboard-first** — archive, trash, star, snooze, reply, navigate, and a
  `Cmd-K` command palette without touching the mouse.
- **Local-first sync** — mail is cached in an encrypted SQLite database with
  FTS5 full-text search; the app is fast and works offline for cached mail.
- **Compose that gets out of the way** — recipient chips with autocomplete from
  mined contacts, Cc/Bcc, quote-on-reply, reply-all dedup, attachments, and
  drafts that round-trip to Gmail.
- **Scheduled send, undo send, snooze, follow-up reminders, snippets.**
- **Optional on-device AI** — draft and summarize with a local
  [Ollama](https://ollama.com) model. Nothing is uploaded; it works in airplane
  mode. Off unless you turn it on.
- **Private by construction** — see [Security](#security).

## Requirements

- **macOS 14.0+**
- **Xcode 15.3+** (Swift 5.10) to build
- **[xcodegen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen`
- A **free Google account** and a personal OAuth client (see below)
- *(optional)* **Ollama** for on-device AI drafting/summaries

## One-time Google setup (~5 minutes)

The app uses **your own** free Google OAuth client, so no third party ever sees
your mail. (See [Why bring your own client?](#why-bring-your-own-oauth-client)
for the reasoning.)

1. Go to https://console.cloud.google.com/ and create a project (e.g. "PerfectMail").
2. **APIs & Services → Library** → search "Gmail API" → **Enable**.
3. **APIs & Services → OAuth consent screen**:
   - User type: **External**, fill in app name + your email, save.
   - Under **Audience / Test users**, add every Google account you want to
     connect. (Testing mode allows up to **100** test users — plenty for
     personal use.)
   - Leave it in **Testing** mode (no Google verification needed; refresh tokens
     for desktop clients don't expire in testing for Gmail scopes — if one ever
     does, just re-sign-in).
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID**:
   - Application type: **Desktop app**.
   - Copy the **Client ID** and **Client Secret** (or download the
     `client_secret_*.json`).
5. Launch PerfectMail → **Settings (Cmd-,) → Google API** → paste both.
6. Sidebar → **Add Google Account…** → your browser opens → sign in → done.
   Repeat for each account.

> During sign-in Google shows a **"Google hasn't verified this app"** screen
> because it's your own unverified test client. That's expected — click
> **Advanced → Continue**. The requested scope is `gmail.modify` plus your basic
> profile (email/name); PerfectMail never sees a password.

### Why bring your own OAuth client?

Shipping a shared client ID would make PerfectMail a data broker for every
user's mailbox and would drag the project through Google's restricted-scope
verification (a CASA security assessment for `gmail.modify`). Bring-your-own
client keeps your mail flowing only between your Mac and Google — nobody else,
including the author, is ever in the loop. It costs you five minutes once.

## Build & run

```sh
brew install xcodegen        # once
xcodegen generate
xcodebuild -project PerfectMail.xcodeproj -scheme PerfectMail -configuration Release build
```

Or, with the included Makefile:

```sh
make build    # generate + build the app
make test     # generate + run the unit tests
make hooks    # install a pre-commit hook that runs the tests
```

Or open `PerfectMail.xcodeproj` in Xcode and hit Run.

### Signing

By default the app is **ad-hoc signed** ("Sign to Run Locally"), so it builds
and runs on any Mac with no Apple Developer account. Signing settings live in
[`Config/Signing.xcconfig`](Config/Signing.xcconfig).

To sign with your own Apple Developer team — required for **notarization**, and
handy for a stable identity that stops the Keychain re-prompting on every
rebuild — create `Config/Local.xcconfig` (git-ignored):

```
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = XXXXXXXXXX
CODE_SIGN_IDENTITY = Apple Development
```

### Releases & updates

PerfectMail publishes binaries to GitHub Releases (`ronboger/perfectmail`). The
app checks once a day; when a newer version exists, an **Update app** button
appears at the bottom of the sidebar and in **Settings → Updates** — clicking it
downloads the release zip, then drag the new PerfectMail into Applications to
replace the old copy.

To cut a release: bump `MARKETING_VERSION` in `project.yml`, then

```sh
make release    # runs tests, builds Release, zips, gh release create v<version>
```

See [docs/RELEASING.md](docs/RELEASING.md) for the full step-by-step checklist,
tag/version rules, Developer ID signing + notarization, and troubleshooting.

For a distributable binary, sign with a Developer ID, keep
`ENABLE_HARDENED_RUNTIME` on (it already is), and notarize with `notarytool`.
Each user still needs their own Google OAuth client (see above), so building
from source stays a first-class path.


## Keyboard shortcuts

| Key | Action |
|---|---|
| e | Archive |
| # | Trash |
| s | Star/unstar |
| u | Toggle read |
| h | Snooze until tomorrow 8 AM |
| j / k | Next / previous thread |
| r | Reply |
| Cmd-N | Compose |
| Cmd-K | Command palette |
| Cmd-Enter | Send |
| Cmd-Shift-R | Sync all |
| Cmd-, | Settings |

## On-device AI (optional)

Install [Ollama](https://ollama.com) and pull a small model:

```sh
ollama pull llama3.2
```

Then in **Settings → AI** point PerfectMail at your local Ollama (default
`http://127.0.0.1:11434`). You get "Draft with AI" in compose and thread
summaries — all computed locally. PerfectMail refuses to send message content
to a non-loopback endpoint over plain HTTP, so your mail can't be exfiltrated
by a mis-typed URL.

## Where things live

- Mail cache (SQLCipher-encrypted): `~/Library/Containers/dev.ronboger.PerfectMail/Data/Library/Application Support/PerfectMail/mail.sqlite`
- OAuth refresh tokens, client secret, and the DB key: macOS Keychain (`dev.ronboger.PerfectMail`)

## Security

- **OAuth 2.0 Authorization Code + PKCE**, loopback redirect bound to
  `127.0.0.1` only (RFC 8252). Sign-in happens in your own browser; tokens go
  straight to the Keychain (device-bound, not synced to iCloud, excluded from
  backups).
- **Encrypted at rest** — the local mail cache is SQLCipher-encrypted with a
  256-bit key held only in the Keychain.
- **HTML email is sandboxed** — rendered with JavaScript disabled, a strict CSP
  (`default-src 'none'`), remote images blocked until you opt in per message
  (no tracking pixels), an ephemeral web data store, and a default-deny
  navigation policy so crafted mail can't redirect, auto-submit forms, or reach
  the network. Links open in your default browser.
- **Attachments** written to disk are tagged with the quarantine attribute, so
  Gatekeeper's first-open checks still apply.
- **App Sandbox** enabled with a minimal entitlement set (network client, the
  transient loopback listener for sign-in, and user-selected file access).
- **No secret logging**, parameterized SQL throughout, CRLF-folded MIME headers,
  and path-traversal-safe attachment filenames.
- Snooze and reminders are local-only (Gmail's API has no snooze); everything
  else — archive, trash, star, read state, send/reply — syncs to Gmail
  immediately.

See [SECURITY.md](SECURITY.md) for how to report a vulnerability.

## License

[MIT](LICENSE) © 2026 Ron Boger. Depends on
[GRDB.swift](https://github.com/duckduckgo/GRDB.swift) (SQLCipher build, MIT).
