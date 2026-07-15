# Changelog

All notable changes to MishMail are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); the project is pre-1.0, so
minor versions may still change behavior.

## [Unreleased]

### Added
- **Default email app** — Settings → Appearance can make MishMail the system
  default for `mailto:` links (browsers and other apps open compose here).
  Registers the `mailto` URL scheme and prefills To/Cc/Bcc/subject/body.
- **Per-account snippet scope** — snippets default to all accounts; optionally
  limit a snippet to one or more mailboxes (Settings → Snippets editor, same
  per-account idea as Gmail filters). The compose `/` picker and Snippets
  panel only show snippets available for the current From account.
- **Draft saved status** — compose autosaves after you pause typing and shows
  Saving… / Draft saved in the footer (Notion Mail-style). Header ✕ / Esc still
  dismiss and keep the draft; the old footer "Close" label is gone. Send /
  Discard / undo-send use the live autosave draft id (no orphan Gmail drafts).
- **Inline reply** — Reply / Reply all / Continue draft for the open thread
  docks compose on the reading column so the conversation stays readable.
  New mail and Forward stay floating; **Pop out** promotes inline → card.
- **Thread focus (⌘↩)** — with a conversation selected (and compose not
  claiming Send), ⌘↩ fills the app with the reading pane. Esc exits focus.
  Toolbar: Focus Conversation. Documented on the `?` shortcuts sheet.

### Changed
- **Snippets settings list scrolls clearly** — list is height-constrained with
  always-visible scroll indicators and a “Scroll for more” fade when content
  overflows.
- **Design/AppIcon.svg** — source artwork updated to the MishMail apricot
  (no Perfect Mail checkmark badge). Shipping PNGs were already apricot.

### Changed
- **Taller inline reply compose** — card height 380→460; collapsed-quote body
  editor floor 120→180 so short replies get a real writing surface.

### Fixed
- **Message-card "…" hides plain `>` history** — quote collapse now treats a
  run of ≥2 `>`-prefixed lines to EOF (and peels a trailing `>` block above a
  later "On … wrote:") as the trail, so nested history without a bare
  attribution no longer stays always-visible. HTML without structured
  gmail_quote falls back to the plain-text head when collapsed. Heuristic
  tradeoff (documented in tests): multi-line trailing shell/docs snippets
  that look like `> cmd` collapse behind "…" too; single-line citations do not.
  CRLF bodies are normalized first (Swift treats `\r\n` as one Character).
- **Slash snippet picker ranking / stale rows** — `/bball` ranks exact and
  prefix name matches first, selection tracks snippet identity (not a recycled
  list index), and the picker re-scrolls when the query narrows so Enter and
  the highlighted row stay on the same snippet.
- **Snippet scope for removed accounts** — signed-out mailbox emails stay
  editable as removable “Removed account” rows (list shows a warning) so a
  solely-orphaned snippet isn’t stuck invisible with no UI path to fix it.
  Import reports unknown `accountIds` in the result string.
- **Delete under `is:unread` advances to the next thread** — opening an unread
  conversation pins it via read-state stickiness so the reading pane doesn't
  blank; trash/archive/spam now still remove the row optimistically so
  Gmail-style auto-advance lands on the next conversation instead of clearing
  selection. Undo under an unread filter re-pins the row so it reappears.
- **Keybinding overrides beat new defaults** — a stored rebind (e.g. archive →
  `x`) is not stolen by a newly added catalog default on the same key;
  colliding defaults are migrated onto a free key.
- **Collapsed quote height no longer leaves a dead gap** — HTML body measure
  uses visible child bottoms instead of `scrollHeight` (which often mirrored
  the WKWebView frame when content was shorter), so the "…" pill sits under
  the authored text.
- **Reply / reply-all / forward ignore draft messages everywhere** — shared
  `ForwardComposer.newestSentMessage` resolver used by keyboard `r`/`a`/`f`, the
  command palette, and the reading-pane toolbar (not toolbar-only).
- **Empty reply drafts no longer preview the quote trail** — quote-only bodies
  (reply opened, saved without typing) show the empty-draft state instead of
  dumping "On … wrote:" into the card.
- **Per-message Continue / Discard** — multi-draft threads edit/delete the card
  that was clicked, not always the newest draft in the thread.
- **Scroll-on-open anchors the newest sent message** — matches which card is
  expanded; drafts no longer steal the scroll position.
- **Date-section bucketing honors injected `now`** — `ThreadDateSections`
  no longer uses `Calendar.isDateInToday` / `isDateInYesterday` (wall clock),
  so pinned-time tests and any as-of grouping stay correct.
- **Send button no longer truncates to "Se…"** — the label is exempt from
  compression when the compose footer gets crowded.
- **Compose "Cancel" is now "Close"** — the button always saved your work as a
  draft (same as the header ✕); the label now says so. Trash remains the
  destructive discard.

### Changed
- **Schedule send uses the snooze picker** — the chevron next to Send opens
  the same natural-language date sheet as snoozing (type "tomorrow 9am",
  "mon", "aug 12", or pick a preset; fully keyboard-driven) instead of a menu
  plus calendar sheet. Past dates are filtered out.

### Added
- **Reply all button** — on multi-recipient messages (extra To/Cc beyond a
  plain reply), the reading pane shows Reply all next to Reply (toolbar,
  header icons, and message action bar). Keyboard `a` was already wired.
- **⌘↩ saves a snippet** — in Settings → Snippets create/edit, Cmd-Return
  saves (plain Return still inserts a newline in the body editor).
- **Multi-select** — `x` toggles a checkbox on the focused conversation
  (rebindable); row checkboxes (Notion-style, visible on hover or when any are
  selected); Shift-click a checkbox to select a range; bulk Archive / Trash /
  Star / Read-Unread / Spam via shortcut or the selection bar; Esc clears
  checks. Bulk mutations reload the list once.
- **Draft cards in the thread** — unsent Gmail drafts render as a dedicated
  card (orange "Draft" pill, "Not sent", left accent, compact authored
  preview without the quote trail). Continue / Discard sit on the card at the
  bottom of the conversation; a slim top banner offers Continue only on long
  threads (>3 messages) so short conversations aren't double-cued.

## [0.3.0] - 2026-07-11

### Added
- **Reading-pane ⋯ menu** — always multi-item: mark read/unread, snooze, mark
  as spam / not spam, block/unblock sender, open in Gmail (plus forward-all when
  multi-message). Spam shortcut `!` (rebindable in Settings → Keyboard shortcuts;
  toggles not-spam when already in Spam).
- **Matching Gmail filters under each message** — collapsible disclosure when a
  filter's criteria match; shared cache with Settings → Gmail filters. Best-effort
  local match (`OR`, unary `-term`, structured criteria).
- **Gmail web deep links** — `authuser=` with correct encoding (including `+` in
  addresses) for thread and filters-settings URLs.
- **Remote image policy** — Settings → Appearance: Ask each time (default),
  VIP senders, or Always. Load images click loads this message; the menu
  offers this conversation. Cleartext image URLs stay blocked either way.
- **Copy / Save thread as Markdown** — thread ⋯ menu: copy the conversation
  to the clipboard or save a `.md` file (bodies, Markdown links from HTML
  anchors, attachment filenames). Save failures alert and fall back to the
  clipboard.
- **Sponsorship** — README Support section, `.github/FUNDING.yml` (GitHub
  Sponsors + ETH), and a clickable "Support MishMail" line in the About panel.

### Notes
- **Report phishing** deliberately not shipped — no public Gmail API path; see
  `docs/plans/2026-07-11-report-phishing-deferred.md`.

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
  and row timestamps keep `lastDate` = newest message. Date-section grouping
  ("Today" / "Yesterday" / …) uses the same activity key as the list sort, so
  a reply does not re-hoist a thread into "Today" under the default Group by
  Date view. "Remind if no reply" cancels only when `lastInboundDate`
  advances (own follow-ups on pure-outbound threads no longer clear the
  reminder).
- **Slash snippets mid-message** — caret-based detection so `/` works more
  than once and not only at the end of the body; settings rows open on click;
  safer programmatic body rewrites keep the caret in sync.

### Changed
- **Renamed to MishMail** — the app, bundle identifiers, Xcode project, targets,
  release artifacts, and GitHub repository references now use the MishMail name.
  The new bundle identifiers intentionally create fresh app containers and
  Keychain namespaces for this pre-1.0 rename.

### Also since 0.2.0
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
