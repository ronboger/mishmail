# Changelog

All notable changes to PerfectMail are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); the project is pre-1.0, so
minor versions may still change behavior.

## [Unreleased]

### Added
- **Formatted forwards** — forwarding now uses a Gmail-style
  "---------- Forwarded message ---------" block and, when the quoted text is
  left untouched, sends a `multipart/alternative` message that carries the
  original HTML formatting alongside the plain text. Editing inside the quote
  falls back to plain text so the two versions never disagree. The original's
  attachments come along too (shown as removable chips; Send waits until
  they've downloaded).
- **Forward focuses To** — pressing the forward shortcut opens compose with the
  cursor in the To field, ready to type a recipient.
- **On-device AI triage** — "Sort Inbox with AI" (Cmd-K) classifies threads into
  local buckets (Reply needed / FYI / Newsletter / Receipt / Other) via Ollama;
  results show as row tags, a new "AI category" grouping, and persist in their
  own table. Nothing leaves the machine.
- **AI thread summaries** — a streamed, local TL;DR on longer threads.
- **AI drafting** now streams token-by-token and works for new mail and
  forwards, not just replies.
- **Richer search operators** — `to:`, `subject:`, `is:unread`/`is:read`,
  `is:starred`, `after:`/`before:` (dates) join the existing `from:`, `label:`,
  `has:attachment`.
- **Lossless saved views** — "Save as view" now captures the full filter set
  (to/cc/bcc, subject, date window, calendar, exclude modes), not just the
  handful the form exposed.
- **Snippet variables** — `{{first_name}}`, `{{name}}`, `{{email}}`, `{{date}}`
  fill from the first recipient on insert.
- **Command palette v2** — fuzzy matching and context actions on the selected
  thread (archive, trash, star, snooze, reply, label).
- **First-run onboarding** — a guided Google-setup wizard with deep links to the
  exact console pages and drag-and-drop of the downloaded `client_secret.json`.
- **Sender avatars** in the thread list; **non-modal error banner** replacing the
  blocking alert; subtle list-row animations; a `PMTheme` design-token seed.

### Security
- WKWebView now uses a **default-deny navigation policy**: only the initial
  document load and user-clicked links are allowed. Meta-refresh, form
  submission, redirects, and iframe loads in crafted email can no longer reach
  the network (which had defeated remote-image/tracking-pixel blocking) or
  replace the message body with a phishing page.
- HTML email renders in an **ephemeral (non-persistent) web data store**.
- Downloaded/opened **attachments are tagged with `com.apple.quarantine`** and
  namespaced by message id (no filename collisions).
- Keychain items (refresh tokens, DB key) now pin
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-bound, excluded
  from backups/migration.
- Ollama: refuses to send message content to a non-loopback endpoint over plain
  HTTP.
- OAuth: surfaces Google's actual error (e.g. `access_denied`) instead of a
  generic "malformed redirect".
- **Hardened Runtime** is enabled (engages when signed with a real identity).

### Packaging / open source
- Added `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, this changelog, and a
  GitHub Actions CI workflow (build + test on `macos-14`).
- Signing moved to `Config/Signing.xcconfig` with a portable ad-hoc default and
  an optional git-ignored `Local.xcconfig` for a personal team — the repo now
  builds for anyone without an Apple Developer account.
- `.gitignore` covers `.claude/`, `DerivedData/`, `xcuserdata/`, and the local
  signing override.

## [0.1.0]
- Initial local-first Gmail client: multi-account sync, unified inbox, saved
  views & live filters, keyboard-first navigation, compose with drafts,
  scheduled/undo send, snooze, follow-up reminders, snippets, command palette,
  full-text search, SQLCipher-encrypted cache, and optional on-device AI
  drafting via Ollama.
