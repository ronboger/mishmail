# Changelog

All notable changes to MishMail are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); the project is pre-1.0, so
minor versions may still change behavior.

## [Unreleased]

### Fixed
- **Reply HTML matches Gmail** — untouched replies now send a multipart HTML
  alternative with a real `gmail_quote` / `gmail_attr` / nested `blockquote`
  and the original message's HTML inside (same pattern as forwards). Previously
  the plain `> ` quote trail was run through markdown, which flattened nested
  history, leaked literal `>` prefixes, and looked broken in Gmail and other
  clients. Quote matching uses a pinned date formatter; quoted HTML strips
  `cid:` images and document chrome (`style`/`html`/`head`) so the trail
  doesn't ship broken inline images or restyle the authored head. Scheduled
  sends hydrate the reply parent body (post-v24 off-row storage); reopened
  reply drafts recover the parent for In-Reply-To + HTML upgrade.
- **Own reply no longer bumps inbox position** — schema v25 adds
  `lastInboundDate` (nullable). Inbox / promotions / social / per-account
  inbox order by `COALESCE(lastInboundDate, lastDate)`; Sent, Drafts, search,
  row timestamps, and date buckets keep `lastDate` = newest message. "Remind
  if no reply" cancels only when `lastInboundDate` advances (own follow-ups
  on pure-outbound threads no longer clear the reminder).

### Changed
- **Renamed to MishMail** — the app, bundle identifiers, Xcode project, targets,
  release artifacts, and GitHub repository references now use the MishMail name.
  The new bundle identifiers intentionally create fresh app containers and
  Keychain namespaces for this pre-1.0 rename.

### Added
- **Compose markdown** — write `**bold**`, `*italic*`, `~~strike~~`, `` `code` ``,
  `#`/`##`/`###` headings, lists, `>` quotes, and `$math$` / `$$display$$` in the
  compose body. Live syntax highlighting, footer format buttons, and shortcuts
  (⌘B / ⌘I / ⌘⇧X / ⌘E / ⌘⇧M / ⌘⌥1–3 / …). Source stays plain-text markdown
  (drafts, snippets, slash picker unchanged); send attaches an HTML alternative
  so recipients see the formatting. Math is lightly prettified for email (no
  full LaTeX engine).
- **Compose hyperlinks (⌘K)** — select text in the compose body and press
  ⌘K (or the link button in the footer) to insert a Gmail-style link. Links
  are stored as markdown `[label](url)` in the plain-text editor and converted
  to real `<a href>` anchors on send; bare `https://…` URLs are auto-linked
  too. Outside compose, ⌘K still opens the command palette.
- **Forward all** — thread ⋮ menu packages every message in the conversation
  into one Gmail-style forward body (oldest first). Still starts a **new**
  conversation (no `threadId` / `In-Reply-To`), matching gmail.com and Notion
  Mail. Single-message Forward (`f`, message actions) is unchanged.
- **Forward composer copy** — banner says “Starts a new conversation” so the
  source thread is not expected to absorb the send.
- **Richer forward HTML** — untouched forward packages (single or all) upgrade
  to multipart HTML using each part’s original markup; plain text prefers the
  HTML-derived body so it matches the reading pane. Forward-all is matched
  before single-message at send (suffix-order fix). Unsent DRAFT rows are
  excluded from Forward all so they never leak to recipients.
- **⌘K links a selected URL immediately** — with a `https://…` URL selected
  in the compose body, ⌘K links it directly instead of opening the link
  sheet.
- **Drag to reorder accounts** — drag an account row in the inbox switcher
  to reorder it; the order persists across restarts. With 2+ accounts, each
  row shows a grip and a “Drag to reorder” caption so the affordance is
  discoverable.

### Fixed
- **Dark-mode inline highlighter strips** — Word / Google Docs / some campus
  mail wrap body copy in `<span style="background:#fff">` (or similar). Those
  pure-inline light fills paint per-line white fragment boxes over the dark
  reading pane (black-on-white “highlighter” bars). Strip the fill on
  `display:inline` light surfaces (and attribute-matched `span`/`font`/… on
  first paint, excluding self-declared `inline-block`/`inline-flex` pills) so
  force-light text sits on the chrome; keep block cards and CTAs as real
  light surfaces with dark text. Inline-tag exclusion uses `:not(:where(…))`
  so JS fg classes keep source-order override for dark-on-dark nested sections.
- **Dark-mode HTML contrast from effective background** — force-light text
  over dark chrome, dark text only where the nearest opaque fill is light
  (Notion Calendar white canvas, cream panels, sig cards). Nested dark
  sections inside a white wrapper (Google welcome mail, blue CTAs) get light
  text again instead of dark-on-black. A `WKUserScript` at document-end stamps
  per-element fg classes from computed `background-color`; attribute selectors
  remain a self-only first-paint fast path. (Solid fills only — light
  `background-image` over transparent color is still a known gap.)
- **⌘K self-link trims stuck punctuation** — linking a selection like
  `(foo.com)`, `foo.com.`, or `foo.com,` now links the URL itself instead of
  producing a broken `https://(foo.com)`-style href. Balanced parens inside a
  path (`…/path(1)`) are kept, and parens in hrefs are percent-encoded so the
  markdown link re-parses cleanly.
- **Expired/revoked sign-ins now prompt reauthorization** — when Google
  rejects a stored refresh token (`invalid_grant`) or none is stored, the
  affected account shows a warning icon and a "Reauthorize…" button in
  Settings → Accounts instead of a raw token-exchange error.
- **New snippets now appear in compose immediately** — the `/` picker and
  Snippets panel pick up newly created snippets right away, without
  restarting the app.
- **Promotions/Social no longer show spam or archived mail** — lists and
  sidebar badges now match gmail.com (inbox + category, excluding SPAM and
  trash). Added denormalized `inSpam` (schema v19); mark-as-spam updates
  labels/denorm like the blocklist. Sidebar unread uses local denorm counts
  only (Gmail `CATEGORY_*` label totals include spam/archived and are not
  merged on top).

## [0.2.0] - 2026-07-09

### Security
- **OAuth loopback hardening** — 5-minute timeout tears down the catcher if
  sign-in is abandoned; only `/oauth2/callback` (and bare `/`) is accepted;
  wrong-state probes are ignored instead of aborting a legitimate flow.
- **HTML CSP tightened** — `base-uri 'none'`, explicit `form-action` /
  `frame-src` / `object-src 'none'`; remote images are HTTPS-only when enabled.
- **Update verification** — "Update App" downloads the release zip, verifies
  published **SHA-256** (`SHA256SUMS` from `make release`), code signature,
  **Team ID** continuity, and **notarization** for Developer ID builds, then
  reveals the app in Finder; failed checks open the GitHub release page.
- **Remote Ollama opt-in** — non-loopback endpoints need an explicit Settings
  toggle (and HTTPS) before mail content is sent.
- **Distribution entitlements** — `make release` / `make install` switch to
  `MishMail.Distribution.entitlements` (library validation on) when
  `Config/Local.xcconfig` sets `DEVELOPMENT_TEAM`.
- **Risky attachment prompt** — Open warns before launching app/script/installer
  filenames (still quarantined for Gatekeeper).

### Added
- **Slash-trigger snippets** — type `/` in the compose body (Notion Mail-style)
  to pop a snippet picker; keep typing to filter, ↑/↓ to choose, Return to
  insert, Esc to dismiss. `⌘/` toggles the snippets panel.
- **Single-brace snippet variables** — `{first_name}` now works alongside
  `{{first_name}}`, plus new variables: `{my_name}` / `{my_first_name}` (the
  sending account) and `{bcc_name}` / `{bcc_first_name}` / `{bcc_email}` (the
  person a move-to-Bcc snippet moved out of To).
- **Snippet editor upgrades** — `{variables}` highlight live as you type
  (accent for ones the app fills, orange for fill-in-yourself prompts like
  `{key_point_1}`), and typing `{` pops an autocomplete of every variable.
- **Snippet import** — Settings → Snippets → Import… reads a JSON file
  (`[{"name", "body", "movesToBcc"}]`), skipping names you already have —
  an easy landing pad for a Notion Mail snippet export.
- **Move-to-Bcc snippets** — a per-snippet toggle for intro etiquette:
  inserting the snippet moves To (the introducer) to Bcc and promotes Cc to
  To, so "Thanks {bcc_first_name} for the intro! Hi {first_name}, …" fills in
  both people correctly. Marked with a "→ Bcc" badge in snippet lists.
- **Formatted forwards** — forwarding now uses a Gmail-style
  "---------- Forwarded message ---------" block and, when the quoted text is
  left untouched, sends a `multipart/alternative` message that carries the
  original HTML formatting alongside the plain text. Editing inside the quote
  falls back to plain text so the two versions never disagree. The original's
  attachments come along too (shown as removable chips; Send waits until
  they've downloaded).
- **Forward focuses To** — pressing the forward shortcut opens compose with the
  cursor in the To field, ready to type a recipient.
- **Drafts keep their attachments** — closing compose (save-as-draft) now
  uploads the attached files with the draft, and reopening a draft brings its
  attachments back as chips, so nothing is silently dropped on a re-save.
- **Drafts keep HTML formatting** — a forward saved as a draft stores the
  original's HTML alongside the plain text (it looks right in Gmail too), and
  any draft re-saved or sent with an unedited body keeps its stored HTML —
  including rich drafts started in Gmail on the web.
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
- **Per-view ephemeral WKWebView store** — HTML email views no longer share a
  single data store; each new view gets its own non-persistent store (JS still
  off), so remote-image cookies/cache cannot bleed across messages. Recycled
  views clear the DOM before re-use.

### Performance
- **Lazy message bodies** — the reading pane opens on headers only and hydrates
  a body when its card expands (last message always hydrated). AI summary still
  pulls full bodies for the whole thread.
- **Label-only Gmail history** — label add/remove on already-cached messages
  applies as a local delta (one write transaction per batch) instead of a full
  `getMessage` download; unknown local messages still full-fetch.
- **Thread denorm columns** (schema v16) — `inSent` / `inDrafts` /
  `inPromotions` / `inSocial` / `fromEmail` keep sidebar counts, mailbox
  filters, and VIP/blocklist short-circuits off the main-thread list path.
  VIP and blocklist still match *any* message From (denorm is a positive
  short-circuit only), so a reply cannot drop Priority or skip a block.
- **Parallel multi-account sync** — each account's `SyncEngine` runs in its own
  task; MainActor reloads (threads, blocklist, contacts) run once at the end.
- **FTS trim** (schema v17) — `message_fts` indexes subject + fromHeader only;
  body search falls back to server search. Prefix indexes kept.

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
