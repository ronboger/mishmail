# Backlog items: snippet hot-reload, Cmd+K bare-URL links, inbox reorder

Three independent quality-of-life fixes from the MishMail kanban backlog,
executed sequentially on branch `backlog-fixes`.

## Global Constraints

- `make test` must pass after every task (runs xcodegen + the hostless
  MishMailTests target).
- The test target is hostless: it compiles specific `Sources/` files listed
  explicitly in `project.yml` under the MishMailTests target. Any source file
  a new test depends on must be in that list. UI files (ComposeView,
  ContentView, SettingsView) and MailStore are NOT in the list and cannot be
  unit-tested directly — put testable logic in `Sources/MishMail/Support/`
  files that are (or can be added).
- Animation style (Ron's standing preference): snappy — fade in place,
  durations ≤ ~0.1s, no slide-in/slide-out theatrics.
- Match surrounding code style: doc comments explain constraints, not
  narration; `// MARK:` sections; 4-space indent.
- One commit per task, message ends with
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

## Task 1: New snippets appear without restarting the app

**Bug:** Creating a snippet (Settings → Snippets, or "save draft as snippet"
in compose) doesn't show up in the compose `/` picker or Snippets panel until
the app restarts.

**Root cause:** Snippet consumers read the DB through computed properties —
`store.snippets()` at `Sources/MishMail/UI/ComposeView.swift:968` (slash
matches) and `Sources/MishMail/UI/ComposeAccessories.swift:115` (SnippetsPanel)
— and `MailStore.snippets()` (`Sources/MishMail/App/MailStore.swift:2819`) is
a bare GRDB read. Nothing `@Published` changes when a snippet is written, so
SwiftUI never re-evaluates those views. SettingsView works around it with
manual `all = store.snippets()` reloads (SettingsView.swift:583-609).

**Fix:**
- Add a published snippet list to `MailStore` (e.g.
  `@Published private(set) var allSnippets: [Snippet]`), loaded at startup
  and refreshed by every snippet mutation: `saveSnippet`, `deleteSnippet`,
  `updateSnippet`, `importSnippets`, and `seedDefaultSnippetsIfNeeded`
  (all in MailStore.swift, MARK: - Snippets around line 2817, seed at 791).
- Point ComposeView slash matches, SnippetsPanel, and SettingsView at the
  published list; delete SettingsView's manual reload plumbing if it
  collapses cleanly (keep the sheet-dismiss refresh if it edits in place).
- Keep ordering identical to today (`ORDER BY name`).

**Verification:** `make test` passes. Manual check description in the report:
with the app running, add a snippet in Settings while a compose window is
open; the `/` picker must show it without reopening anything.

---

## Task 2: Cmd+K on a selected URL links it immediately

**Ask (verbatim from kanban):** "Command k when composing on something that's
already a link should just make it blue."

**Current behavior:** `openLinkSheet()`
(`Sources/MishMail/UI/ComposeView.swift:1018`) always opens the link sheet
when there's a non-empty selection, even when the selected text IS a URL —
the user then has to retype/paste the URL into the sheet.

**Fix:**
- New pure helper in `Sources/MishMail/Support/ComposeLinks.swift`, e.g.
  `static func selfLink(forSelection selected: String) -> String?` — returns
  the normalized href when the selection is a bare URL/email and nil
  otherwise. A selection qualifies when: trimmed, non-empty, contains no
  internal whitespace/newlines, is not already inside a markdown link, and
  `normalizeURL` accepts it AND the input plausibly looks like a
  URL/email (has a recognized scheme, contains a dot, or contains `@`) —
  plain words like "hello" must NOT qualify even though `normalizeURL`
  would turn them into `https://hello`.
- In `openLinkSheet()`: when the selection is non-empty and qualifies,
  call `ComposeLinks.applyLink(in:selection:text:url:)` directly with
  text = the selected text as typed, url = the selection — producing
  `[foo.com](https://foo.com)`-style markdown that renders as a link
  ("blue") — and return without showing the sheet.
- Unchanged: empty selection with caret inside an existing markdown link
  still opens the edit sheet; ordinary text selections still open the sheet.
- If the selection overlaps but doesn't exactly cover an existing markdown
  link's span, fall back to the sheet (don't try to be clever).

**Tests:** Extend `Tests/MishMailTests/ComposeLinksTests.swift` for the new
helper: http/https URLs, bare host (`foo.com`), bare email, `mailto:`,
rejects plain words, rejects multi-word selections, rejects
javascript:/data: schemes, rejects text already inside `[..](..)`.

**Verification:** `make test` passes, including new cases.

---

## Task 3: Drag to reorder inboxes

**Ask (verbatim):** "be able to drag/reorder the inboxes, ie i could swap
space of first and 2nd inbox."

**Current behavior:** `@Published var accounts: [Account]`
(`Sources/MishMail/App/MailStore.swift:212`) renders in load order; no
user-controlled ordering. The account switcher UI lives in
`Sources/MishMail/UI/ContentView.swift` (~lines 930-1090, `allInboxesIcon`
and account rows).

**Fix:**
- Investigate how `Account` rows are stored/loaded first (GRDB record vs
  in-memory), then pick the simplest durable ordering: a `sortOrder` column
  via a new GRDB migration (follow the existing migration pattern in
  `Sources/MishMail/Store/Database.swift`) if accounts are DB rows,
  otherwise an ordered account-id list in UserDefaults.
- `accounts` is always sorted by the persisted order; newly added accounts
  append at the end; removing an account leaves the rest stable.
- Reorder logic (apply a move to an ordered list + persistence round-trip)
  goes in a small pure helper in `Sources/MishMail/Support/` so the hostless
  test target can cover it (add the file to project.yml's test source list).
- UI: drag-to-reorder on the account rows in ContentView (SwiftUI `.onMove`
  if they're in a List, otherwise `.onDrag`/`.onDrop` with
  `NSItemProvider`). Keep feedback snappy per Global Constraints.
- Unified "all inboxes" entry stays pinned first — only real accounts
  reorder.

**Tests:** New test file for the ordering helper (move semantics, append of
unknown ids, dropped stale ids). Add both helper and test file to
`project.yml`.

**Verification:** `make test` passes. Manual check description in the report:
drag account 1 below account 2 in the switcher, restart the app, order
persists.
