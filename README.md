# PerfectMail

A native, local-only Gmail client for macOS. SwiftUI, Gmail REST API, SQLite.
No server, no telemetry — nothing leaves your Mac except calls to Google's own API.

## One-time Google setup (~5 minutes)

The app uses **your own** free Google OAuth client, so no third party ever sees your mail.

1. Go to https://console.cloud.google.com/ and create a project (e.g. "PerfectMail").
2. **APIs & Services → Library** → search "Gmail API" → **Enable**.
3. **APIs & Services → OAuth consent screen**:
   - User type: **External**, fill in app name + your email, save.
   - Under **Audience / Test users**, add every Google account you want to connect.
   - Leave it in **Testing** mode (no verification needed; refresh tokens for
     desktop clients don't expire in testing for Gmail scopes — if one ever
     does, just re-sign-in).
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID**:
   - Application type: **Desktop app**.
   - Copy the **Client ID** and **Client Secret**.
5. Launch PerfectMail → **Settings (Cmd-,) → Google API** → paste both.
6. Sidebar → **Add Google Account…** → your browser opens → sign in → done.
   Repeat for each account.

## Build & run

```sh
brew install xcodegen        # once
xcodegen generate
xcodebuild -project PerfectMail.xcodeproj -scheme PerfectMail -configuration Release build
```

Or open `PerfectMail.xcodeproj` in Xcode and hit Run.

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
| Cmd-Enter | Send |
| Cmd-Shift-R | Sync all |
| Cmd-, | Settings |

## Where things live

- Mail cache: `~/Library/Containers/dev.ronboger.PerfectMail/.../Application Support/PerfectMail/mail.sqlite`
- OAuth refresh tokens + client secret: macOS Keychain (`dev.ronboger.PerfectMail`)

## Security notes

- OAuth 2.0 Authorization Code + PKCE, loopback redirect (RFC 8252); sign-in
  happens in your own browser, tokens go straight to the Keychain.
- HTML email renders with JavaScript disabled and a CSP that blocks all remote
  content (no tracking pixels). Links open in your default browser.
- App Sandbox enabled; network access limited to client + the loopback listener
  used during sign-in.
- Snooze is local-only (Gmail's API has no snooze); everything else — archive,
  trash, star, read state, send/reply — syncs to Gmail immediately.
