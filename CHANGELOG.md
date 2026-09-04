# Changelog

- **Compose links now read naturally** — links with display text render as the
  blue underlined label in the editor; MishMail no longer exposes the backing
  `[label](URL)` syntax while drafting. Draft storage, ⌘K editing, and sent HTML
  remain unchanged.

All notable changes to MishMail are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); the project is pre-1.0, so
minor versions may still change behavior.

## [Unreleased]

### Fixed
- **A mailto: link no longer opens a second MishMail window.** Email links
  from other apps (browsers, Notion Calendar) now land in the window that is
  already open. A duplicate delivery of the same link within two seconds is
  ignored while its card is still up, so no second compose card is queued;
  re-clicking a link after dismissing the card still composes.

### Changed
- **MailStore command work is split out of the observable hub.** Sync,
  mutations, compose/drafts, reminders, AI triage, and account lifecycle live
  in `MailStore+…` files and Support policy types. The main class keeps UI
  state.
- **CI runs on every pull request and every push to main.** Unit tests and
  the app build are one job; the UI smoke suite is a separate job so a UI
  hang cannot hide unit-test results.
- **README privacy copy matches hosted AI.** Mail stays on this Mac except
  Gmail API traffic; a hosted model you assign can receive that task's mail
  text after host consent. Silent auto-sort still refuses cloud providers.
- **The unit-test target includes domain sources by directory.** New
  Gmail/Store/Auth/Support files no longer need a `project.yml` line. App-only
  files stay on an exclude list.
- **Ask Mish hides stale models in the picker.** Grok 4.2, Grok 2/3, image
  and non-reasoning ids, and Gemini 1.x/2.x no longer fill the browse list.
  Grok defaults to Grok 4.6. Gemini defaults to 3.7 Flash. A stored stale
  assignment (drafts, summaries, triage, Ask Mish) moves to that default.
  Search still finds the full list.
- **Compose From is a keyboard control.** ⇧Tab from To lands on the sending
  address. ↑↓ change it in place, Space or ↩ open the list, type a letter to
  jump, Esc closes the list without closing the draft. Rows show the display
  name, the mailbox it sends through, and a Default badge.
- **Ask Mish confirms show the draft body.** Create-draft and send-draft cards
  include a body preview. Return no longer confirms those actions. Send aborts
  if the draft changed after you confirmed.
- **Auto-sort stays on this Mac or the LAN.** If Triage is a cloud model,
  auto-sort skips so new-mail snippets are not uploaded. Ollama on a private
  LAN still runs. Settings says so.
- **Custom model hosts need a confirm.** A base URL that is not a shipped
  preset must be acknowledged in Settings before mail is sent there. Consent
  matches scheme, host, and port.
- **Long Ask Mish chats compact old tool results.** Later turns no longer
  resend every search and list payload. List tools keep a leading page.
- **mcp.json no longer stores the MCP bearer token.** The token stays in the
  Keychain. Helper scripts read it from `MISHMAIL_MCP_TOKEN` or
  `~/.config/mishmail/mcp-token`.

### Added
- **Moving from Notion Mail.** Settings opens with a migration pane: what
  to save before 22 Sep 2026, how drafts/scheduled mail stay in Gmail, and
  a JSON/CSV snippet importer that reads Notion exports (`shortcut`/`content`,
  `{ "snippets": […] }`, `{{First Name}}`). Cmd-K has “Moving from Notion
  Mail…”. README has the same steps.
- **Sign in with OpenRouter.** Settings → AI → Subscriptions can open a
  browser login and mint an API key for this app, the same PKCE flow Pi
  uses. You can still paste a key. The minted key stays in the Keychain.
- **Ask Mish shows its work.** Tool calls stream as live status rows you can
  expand (query, result, and clickable threads). Empty chats offer three
  starting prompts. After an answer, follow-up chips continue the turn. The
  open-thread chip names the subject. Local models get a Think control on the
  panel. Hosted chats get Fast vs Default. Confirm cards can open the draft
  in compose. Compose AI edits show a before/after strip with Keep and Undo.
- **⌘L copies a Gmail web link to the focused conversation**, Notion-style.
  The clipboard gets a `mail.google.com` URL that opens the conversation
  in the browser (with `authuser` so the right mailbox is selected). Also
  on the conversation ⋯ menu, the thread-list context menu, and in the
  command palette. Yields to typing in search, compose, and Settings;
  works while reading the conversation.
- **Unsubscribe from mailing lists, Gmail-style.** Messages that advertise
  RFC 2369 `List-Unsubscribe` show an Unsubscribe control next to From and in
  the ⋯ menu. After confirm, MishMail prefers RFC 8058 one-click HTTPS POST,
  then a mailto: send through Gmail, then the sender's unsubscribe page in
  the browser. Existing mail without stored headers is filled on open via a
  metadata fetch. Demo newsletters include sample headers.
- **⌘A selects every thread currently loaded in the list** — Gmail-style
  select-all for the existing checkbox multi-select, so the bulk-action bar
  (archive/trash/star/etc.) can act on the whole list at once instead of
  clicking or shift-clicking every row by hand. Only checks what's already
  loaded (the list is infinite-scroll); scrolling in more rows afterward
  doesn't retroactively check them. Never intercepts ⌘A where it already
  means "select all text" — search, compose, Settings, the selectable
  conversation text, and the message body itself all keep native
  select-all, so reading an email and hitting ⌘A still selects the email.

### Changed
- **From picker leads with the email.** Every linked identity used the same
  display name, so the menu was a wall of "Ron Boger — …" and hid the
  domain. Rows now start with the address, drop the name when it does not
  distinguish anyone, and only add "(via mailbox)" when the same address
  exists on another account. Duplicate addresses sort primary first. The
  open menu shows a checkmark on the current identity.

### Fixed
- **Google Gemini shows its mark in the model picker.** Matching uses the
  API host and OAuth vendor, not only the provider label.
- **Attachment chips open from a click anywhere on the chip, not only the
  filename.** Padding and the gray fill sat outside the Quick Look button,
  so clicks on the icon, size, or empty chrome did nothing. The whole chip
  is now the hit target. Eye and Save keep their own buttons.
- **↓ in Ask Mish no longer opens the next email.** Arrow keys first scroll
  the chat (or the conversation beside it). If there is nothing to scroll,
  they only move the list highlight. Enter still opens the thread.
- **Opening a thread from search could show the same image twice and hide
  the PDF.** A full re-fetch (CID inline / attachment recovery) fed the
  chip list parsed rows whose SQLite `id` was still nil. SwiftUI ForEach
  then treated every chip as one view. Chips now key off a stable part
  identity, and the re-fetch returns the inserted rows. Clicking a file
  chip Quick Looks it; Esc closes that preview instead of the thread.
- **Changing From after the first autosave still sent through the original
  mailbox.** New compose pins the Gmail API to the selected identity, not
  the autosave draft's account. The old pin made a From change (e.g. to
  berkeley after inserting `/bball`) send via the default mailbox, and
  Gmail rewrote From to that mailbox's default send-as (`ron@ronboger.com`).
  Replies still stay on the thread's mailbox. Changing From also dirties
  the draft so the next save migrates it.
- **Multi-select `h`/`b` snooze only snoozed the last-focused thread, not
  the whole selection.** Every other bulk action (archive, trash, star,
  read/unread, spam) already checked the multi-select before falling back
  to the single focused thread; snooze never got that treatment. Picking a
  date now applies to every checked thread at once, with one combined
  undo toast.
- **Side-by-side compose opens every message in the conversation.** The
  reading pane still keeps one live body renderer (WebKit cost), but ⇧⌘↩
  expands all sent cards so you can read the full thread while drafting.
  Quoted trails stay behind each card's "…" pill. The conversation column
  is also hosted in a `NavigationStack` so the detail toolbar (exit split,
  archive/star, reply, ⋯ More) mounts again.
- **Switching mailboxes on a narrow window no longer dumps you into a
  conversation.** On windows below the three-pane width (~1080pt), clicking a
  sidebar mailbox could land with the top conversation auto-opened, replacing
  the list you asked for. Cause: a consumed-twice selection intent — when a
  SwiftUI selection-change fire found no pending intent it was treated as a
  click, and the "click" opened the quietly pre-highlighted top row. Unmatched
  fires are now treated as quiet (select only, never open). This is also what
  made the SidebarNav UI test fail on every CI run since it was added
  (issue #3) — the runner's window is 1000pt wide.
- **Thread list repaints no longer query the database per row** — building
  each row's right-click menu looked up the newest sender with a synchronous
  encrypted-SQLite query, and SwiftUI evaluates that menu for every visible
  row on every list update, so each repaint paid N queries on the main
  thread. The menu now reads the sender address already denormalized on the
  thread row. Label chips are also computed once per layout rebuild instead
  of re-allocated and re-sorted per row on every pass.
- **"Today" and "Yesterday" sections roll over at midnight** — date buckets
  and the Priority recency window captured "now" only when the list layout
  was rebuilt, so a list left open overnight kept yesterday's mail under
  "Today". The list now recomputes on day change (and time-zone changes),
  and the Labels view refreshes its section order when accounts are added
  or removed.

## [0.4.14] - 2026-08-02

### Added
- **MCP server** — an opt-in, in-process MCP endpoint (Streamable HTTP on
  127.0.0.1) so external AI agents can read and search threads, list and
  create drafts, write persisted per-thread AI summaries (shown in the
  reading pane with model attribution), and manage VIP senders (suggestions
  land in a "Suggested" group). Off by default; Settings → AI → MCP has the
  toggle, a fixed port (default 41888, 0 = random per launch), and copyable
  connect commands for Claude Code, Codex CLI, Gemini CLI, and any
  mcp-remote-capable client. Auth is a Keychain-held bearer token; a
  discovery file (mcp.json) is written next to the database while running.
  No send/archive/trash tools in this first version — drafts stay reviewable.

### Changed
- **Shift+I on an already-read conversation marks it unread** — Gmail's chord
  still marks unread threads read; when every focused or multi-selected
  conversation is already read, Shift+I flips them to unread instead of a
  no-op. Shift+U still always marks unread.

## [0.4.6] - 2026-07-27

### Fixed
- **The update restarts the app. The cause was never the sandbox.** Three
  releases shipped three different relaunch mechanisms, all failing with the
  same LaunchServices -10810, and the real reason was one the earlier fixes
  couldn't have addressed: **every file a sandboxed process writes is
  force-quarantined by the kernel, and the sandbox denies `removexattr` on
  `com.apple.quarantine`** — silently, since the call compiles and just
  returns -1. So the "clear quarantine" step added in 0.4.5 never cleared
  anything, the freshly installed update stayed quarantined, and macOS
  refuses to launch a quarantined bundle that isn't notarized. That includes
  the embedded relauncher, which is why it couldn't start.

  Two changes make it work. The relauncher is now signed **without** the
  sandbox entitlement, so it can actually strip the attribute; the app's
  entitlements are selected through a build variable rather than an
  xcodebuild command-line setting, which applied to every target and was how
  the helper silently inherited the sandbox. And MishMail starts the helper
  **before** the swap, from its own registered, unquarantined bundle — after
  the swap the only copy on disk is the update's, which cannot be launched
  until something unquarantines it.

  `make install` and `make release` now refuse to ship a sandboxed
  relauncher, since the failure is otherwise invisible until an update is
  attempted.

## [0.4.5] - 2026-07-27

### Fixed
- **The restart works — the real cause was quarantine, not the sandbox.**
  0.4.4's embedded relauncher failed to launch with LaunchServices -10810, the
  same error the two earlier attempts hit. It was never a sandbox restriction:
  `ditto` stamps `com.apple.quarantine` onto *every* file it extracts from the
  downloaded zip, and the update only cleared it from the bundle root. The
  embedded relauncher is an app bundle in its own right, so it stayed
  quarantined — and macOS refuses to launch a quarantined bundle that isn't
  notarized, which these builds never are. 33 items in a freshly updated
  0.4.4 were still tagged. Quarantine is now cleared across the whole bundle,
  which is what the earlier root-only version should always have done.

## [0.4.4] - 2026-07-27

### Fixed
- **The update restarts the app, verified end to end.** Two previous attempts
  failed on real hardware: asking LaunchServices for a second instance of the
  bundle we're running from returns -10810, and the sandbox blocks spawning a
  shell to do it instead. MishMail now embeds a tiny second app,
  `MishMailRelauncher`, at `Contents/Library/`. A separate bundle id makes it
  an ordinary "open another app", which the sandbox allows, and it waits for
  MishMail to disappear before reopening it — so nothing conflicts and nothing
  stale is resolved. It has no Dock icon and no UI.

  The helper is built with the app's entitlements and is therefore sandboxed,
  which mattered: a sandboxed process can't `kill(pid, 0)` another one, so the
  first version read "already gone" immediately, reopened MishMail while it
  was still running, and exited before the quit it was waiting for. Liveness
  is asked through `NSRunningApplication` instead.
- **The failure dialog can no longer strand the app.** If the restart does
  fail, MishMail comes to the front before showing the alert — it once sat
  unseen on another Space while the app hung behind it on a closed database —
  and a backstop exits the process if termination is blocked past five
  seconds. Everything is already flushed by then; staying on screen only
  misleads.

## [0.4.3] - 2026-07-27

### Fixed
- **The update actually restarts the app now.** Updating 0.4.1 → 0.4.2 through
  the app worked right up to the restart: the permission panel appeared, the
  grant stuck, and the swap landed — but LaunchServices refused the relaunch
  with "a miscellaneous error occurred" (-10810). Asking it for a second
  instance of our own bundle from inside that bundle doesn't work, and
  replacing the bundle first makes it worse, because the registration it has
  cached points at the copy that was just deleted. The relaunch is now handed
  to a detached shell that waits for the app to exit before opening it: by
  then nothing is running to conflict with, and opening by path re-reads the
  bundle that's actually there.
- **Updates are checked on every launch.** The launch check went through the
  same once-a-day gate as the background tick, and that timestamp lives in
  preferences which survive an update — so relaunching straight into a
  brand-new release surfaced nothing until you pressed Check for Updates by
  hand. A launch is rare and one request is cheap; the hourly tick still
  covers a window left open for days.

## [0.4.2] - 2026-07-27

The first release that existing installs can take through the new in-place
updater, and cut partly to exercise it end to end.

### Fixed
- **`scripts/update-mishmail.sh` no longer prints an `xattr` usage dump**
  mid-install. The recursive form it used doesn't exist on this macOS; the
  quarantine attribute Gatekeeper reads lives on the bundle root anyway, which
  is what the app's own `clearQuarantine` clears.

### Changed
- **`make release` refuses to run unless `HEAD` is exactly `origin/main` and
  the tree is clean.** `gh release create` tags the *remote's* main, not local
  HEAD, so cutting a release with the version bump unpushed publishes a
  correct zip under a tag whose source still carries the old version — which
  is what happened to v0.4.1 and cost a `--cleanup-tag` redo. One comparison
  catches unpushed, behind, diverged, and released-off-a-side-branch alike;
  the clean-tree half covers changes that would land in the zip but not the
  tag.

## [0.4.1] - 2026-07-27

### Changed
- **Updates install themselves** — "Update App" used to download the release
  zip, extract it into a temp folder, and open Finder on it so you could drag
  the app into Applications yourself, with a Gatekeeper warning waiting at the
  end because the verified bundle was still tagged as quarantined. It is now
  one button, **Install and Relaunch**: the same download and verification
  (SHA-256, nested code signature, Team ID continuity, notarization for
  Developer ID builds), then an atomic swap over the installed app and a
  restart. Because MishMail is sandboxed it cannot write its own install
  folder unaided, so the first update asks once for permission to that folder
  and remembers it as a security-scoped bookmark; every later update is a
  single click. The quarantine tag is gone from this path — the update has
  already cleared stronger checks than Gatekeeper applies to an Apple
  Development build, and keeping it would make macOS refuse to launch the
  update at all. A declined grant, a failed swap, or an app running from a
  temporary location still reveals the verified app in Finder, quarantined,
  exactly as before. If a draft is open, the restart asks first.
- **Updates are pinned to the version they claim to be** — signatures prove
  identity, not freshness, so anyone who took over the GitHub account could
  have republished an old, validly signed, vulnerable build under a higher tag
  and rolled the app backwards past every other check. The extracted bundle's
  `CFBundleShortVersionString` now has to match the release it was offered as.

### Added
- **`scripts/update-mishmail.sh`** — updates an existing install from the
  terminal, running the same checks the app does. Mainly for crossing *to*
  0.4.1: builds older than this tag every download as quarantined, and macOS
  refuses to launch a quarantined build that isn't notarized, so updating
  through the old in-app flow ends in a Finder drag and a trip through System
  Settings. Also a recovery path if an in-place update ever fails.

## [0.4.0] - 2026-07-27

### Fixed
- **Instant reading pane on delete-advance** — trashing a conversation took
  ~180 ms to show the next one. The payload was already cached; the cost was
  the `await` reaching it. `ThreadDetailRepository` is an actor, so every read
  costs a MainActor → actor → MainActor round-trip, and the return hop waits on
  the very SwiftUI work the delete just queued (measured: cache *hits* cost the
  same as misses, which ruled out the lookup). Payloads the prefetch already
  produced are now mirrored on the main actor, so the pane paints with no hop
  at all — `open.ready` went from 176–209 ms to 0.0–0.1 ms. `ThreadDetailView`
  also seeds its state at `init`: `.id(thread.id)` remounts it per
  conversation, so `@State` started empty and the pane painted blank for a
  frame before `.task` could run, however fast the data arrived.
- **Single-key shortcuts work while reading a conversation** — `g i`, `j`/`k`,
  `e`, and every other Gmail-style key went dead once focus landed on the
  message text, so a full-window conversation had no keyboard way back to the
  inbox. The key monitor stood down whenever the first responder was an
  `NSTextField`/`NSTextView` — but SwiftUI renders selectable `Text` as a
  *read-only* `NSTextField`, and a conversation is built out of them, so simply
  reading an email disarmed the shortcuts. It now stands down only for
  **editable** text (search, compose, the label-picker query), which is the
  case the check was actually for. Esc no longer wastes its first press
  blurring selectable text either.
- **`g i` (and other go-to shortcuts) leave full-window conversations** — in
  Superhuman-style open, same-mailbox go-to used to no-op and leave you stuck
  inside the thread; it now returns to the list like Esc / the back button
  (cross-mailbox go-to already did via the view switch).
- **Reading-pane cache survives triage** — the payload cache and neighbor
  prefetch were keyed on a global content version that `reloadThreads()` bumped
  on every call. Since trash/archive/star/mark-read each schedule a reload, one
  keystroke evicted all ten cached conversations — including the prev/next
  neighbors the prefetch had warmed 50 ms earlier — so rapid triage always
  landed on a cold payload and the prefetch's work was always discarded.
  Cache validity is now a per-thread `ThreadContentRevision` that only moves
  when a sync actually rewrites that thread's message rows; label-only
  mutations leave every cached body valid. The open pane likewise refreshes
  in place only when its *own* conversation changed, instead of on any DB
  activity anywhere.
- **Gmail Shift+I / Shift+U mark read/unread** — those chords were swallowed
  without effect (`charactersIgnoringModifiers` keeps Shift on letters). They
  now mark the focused (or multi-selected) conversation read / unread. Letter
  single-key shortcuts are also case-insensitive so Caps Lock no longer breaks
  them.

### Added
- **Full-window conversations (Superhuman-style, now the default)** — clicking
  a conversation (or pressing ↩) opens it across the whole window instead of a
  reading pane beside the list; Esc, `g i` (or any go-to), or the back button
  returns to the list. Settings → Appearance → "Opening a conversation"
  switches back to the reading-pane layout.
- **Sidebar on arrow keys** — ← hides the sidebar, → shows it (persisted, and
  now hidden by default). `/` still works with a hidden sidebar: it reveals
  the sidebar and focuses search.
- **Top row pre-selected** — on launch, when switching mailboxes, and when
  refocusing the app, the top conversation is highlighted automatically
  (without opening or marking it read), so ↩ opens it immediately — no
  priming ↑/↓ or click needed.
- **Side-by-side compose (⇧⌘↩)** — view a draft next to the conversation it
  answers. Any thread-bound compose (reply, forward, or a reopened reply
  draft) can expand to a full-window split: the source conversation fills the
  left column, the draft the right. Toggle with ⇧⌘↩, the split button in the
  compose header, or the toolbar exit control; Esc steps back to the previous
  inline/floating placement first, then closes the draft. The same composer
  instance moves between placements, so typed text is never lost.

### Changed
- **Instant triage handoff** — archive, trash, spam, and snooze now publish
  their row/count changes before encrypted-database and Gmail work, and replace
  the reading pane with the next conversation in the same update. Repeated
  actions share a serial persistence tail and one coalesced reconciliation
  instead of blocking the UI and fully reloading after every key press.
- **Faster conversation opening** — reading-pane headers, initial bodies, and
  attachments load off the main actor in one database snapshot. A bounded LRU
  retains actual neighbor payloads, so prefetch work is reused instead of
  discarded and message cards no longer query attachments while rendering.
- **Finder-speed keyboard browsing** — list focus lives on a dedicated
  `ListFocusState` (not a MailStore `@Published`), so holding ↓ / j no longer
  re-renders the reading pane, sidebar, or every thread row. The expensive
  `openedThreadId` still follows after a 150 ms settle (longer under load so
  key-repeat does not hydrate intermediate conversations). Neighbor header/body
  prefetch arms only when a conversation actually opens. Display-order moves
  use an O(1) id→index map. `ThreadRow` takes an equatable model (no
  `EnvironmentObject`) so unfocused rows skip body work on each repeat. The
  first keyboard selection still opens correctly in compact and three-pane
  layouts instead of requiring a priming click or Enter.
- **Lower HTML-mail idle memory** — MishMail retains one warm WebView instead
  of three, keeps only one sent message body expanded at a time, uses a smaller
  quote-analysis cache, builds the CSP fallback only when needed, and releases
  idle WebViews under macOS memory pressure.
- **Aligned participant headers** — compact and expanded message details use
  the same FROM/TO grid; bare addresses truncate in the middle and the
  disclosure chevron has a fixed optical frame.

### Fixed
- **Signing / demo hardening follow-ups** — the signing check only accepts
  certificates backing a currently valid identity (expired/revoked certs no
  longer count); `make release` notarizes and staples before publishing;
  `make run DEMO=0` refuses ad-hoc signing before building instead of after;
  UI-test fixture processes can no longer connect real accounts (same guard
  as the demo); the Settings Google API pane explains instead of silently
  dropping credentials in demo/UI-test processes; and "make default mail app"
  waits out the user-paced system confirmation before reporting failure.
- **Thread list clicks work again after the pre-select open fix** — the
  already-selected-row open affordance no longer mounts a permanent
  `contentShape` + gesture on every row (that hijacked `List` selection on
  macOS). Unselected rows select/open normally; the pre-highlighted top row
  still opens on click via a selected-only overlay.
- **Esc exits side-by-side compose while drafting** — ContentView owns an
  explicit Esc priority ladder (slash picker → command palette → search focus →
  exit split → save & close draft) that runs before the compose-typing
  passthrough, so Esc works with the body editor focused and never relies on
  local-monitor install order. Search focus blurs the sidebar field without
  closing a floating/inline draft; second Esc still saves & closes after
  leaving split.
- **Inline reply scroll no longer fights the thread** — opening Reply keeps a
  stable top `scrollPosition` and one-shot bottom-scrolls the reply target
  above the reserved compose card (re-sticks on late WKWebView growth, disarms
  if you scroll away via content-offset / trackpad). Dismiss restores the
  pre-compose position, including single-message threads via the subject
  scroll id. Pathologically short panes float compose instead of a zero-height
  dock.
- **Personal replies re-surface archived promo threads in Primary** — tab
  placement (`inPromotions` / `inSocial`) now follows the newest *INBOX-bearing*
  message instead of the union of every historical label. A human reply on an
  archived no-reply invite (which still carries `CATEGORY_PROMOTIONS`) returns
  the conversation to Primary instead of staying hidden under Promotions.
  Existing caches recompute on migration v27; optimistic label mutations no
  longer clobber tab flags from the labelIds union.
- **Clicking the pre-highlighted top row now opens it** — the auto-selected
  row produced no selection change, so the very first click in a mailbox did
  nothing. Rows now request an explicit open when the click lands on the
  already-selected thread. The quiet highlight also no longer counts as "a
  conversation is open" for narrow windows, which used to boot the
  reading-pane layout into the wrong column.
- **Inline reply no longer livelocks the app** — the reading pane's measured
  frame fed the inline composer's reserved bottom inset while being measured
  *inside* that inset, so at window heights under ~1050 pt the two values had
  no fixed point: layout oscillated ~50×/s, pegging the main thread and
  growing memory without bound the moment a reply opened. The pane is now
  measured outside the inset, and a UI regression test drives
  reply → side-by-side → back and fails on any recurrence.
- **Source rebuilds no longer trigger recurring Keychain prompts by default** —
  the fictional developer demo uses an isolated, non-secret database key and
  never touches Keychain. Real-inbox launch/install commands now refuse an
  unstable ad-hoc signature and point to Apple's free Personal Team signing
  path; no paid Developer Program membership is required for personal use.
- **Inline reply no longer springs the thread viewport upward** — composer
  motion is scoped to the card, the reading-pane inset changes without
  animation, and short panes continuously resize the card or fall back to a
  floating composer. Growing the pane restores inline presentation rather
  than leaving a sticky one-way demotion.
- **Draft cards disappear during Undo Send** — the Gmail draft remains safely
  available for Undo, but its thread card, banner, and Drafts-list row are
  suppressed until Undo, failure, or successful send resolves. A sibling
  draft in the same conversation keeps the Drafts-folder row visible.
- **Keychain access failures no longer masquerade as missing authorization** —
  locked or temporarily unavailable Keychain items remain retryable instead
  of marking the account for reauthorization. OAuth setup guidance now
  correctly explains Google Testing-mode's seven-day token lifetime. Database
  and OAuth-client secrets also fail closed instead of generating or sending
  replacement values after a transient read failure.
- **HTML mail no longer collapses when remote images are blocked** — blocked
  or failed `<img>` tags keep capped authored width/height (max 1200×2000) so
  table-based transactional layouts (e.g. 2FA) keep vertical structure under
  Ask policy; successful loads restore any author inline styles that were
  temporarily overridden (never wipe unrelated `style` props). Placeholders
  reflow proportionally to the reading-pane width on resize. Height tracking
  uses a ResizeObserver plus image load/error events instead of a fixed ~1.2s
  poll. Complete HTML documents keep author head styles; CSP/CSS are injected
  via an HTML-aware scanner that skips comments and raw-text elements and ends
  open tags only at unquoted `>` (so decoy `<!-- <head> -->` or
  `data-decoy=">"` cannot disable CSP). Ask-mode privacy is independently
  enforced by a WebKit content rule installed before navigation, with a trusted
  CSP wrapper as a fail-closed fallback. Fragments still wrap.
  Message cards gain a manual **Show plain text** control for the multipart
  alternative. Recycled WebViews tear down observers and script handlers.

### Added
- **Default email app** — Settings → General can make MishMail the system
  default for `mailto:` links (browsers and other apps open compose here).
  Registers the `mailto` URL scheme and prefills To/Cc/Bcc/subject/body.
  An expanded in-progress compose is not clobbered; the link opens when that
  draft is closed. Opening `.eml` / `message/rfc822` files is not supported yet.
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
- **Mark-as-read waits ~1s on open** — skimming the inbox with j/k or
  click-select no longer clears every unread badge on contact. Stay on a
  conversation for about a second (or press `u`) to mark read. **Archive
  (`e`) marks read immediately** so a quick archive does not leave the
  thread unread in All Mail.
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
