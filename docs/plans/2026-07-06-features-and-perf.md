# PerfectMail: Perf Optimizations + Priority Inbox, Quick Look, Auto-Advance

## Context

PerfectMail is a native macOS Gmail client (SwiftUI, Gmail REST API, GRDB/SQLCipher). ~10k lines Swift under `Sources/PerfectMail/`. Central state lives in `Sources/PerfectMail/App/MailStore.swift` (~1,700 lines, ObservableObject, 40+ @Published). Sync in `Sources/PerfectMail/Gmail/SyncEngine.swift`; schema in `Sources/PerfectMail/Store/Database.swift` (GRDB migrations v1–v9).

This plan: three performance fixes, three UX features, one behavior-preserving decomposition refactor. Executed sequentially, one task per subagent, in this worktree.

## Global Constraints

- Build/test via xcodegen Makefile: `make gen` regenerates the `.xcodeproj`; `make test` runs the suite. The test target is hostless — it compiles specific `Sources/` files listed in `project.yml` (`PerfectMailTests` target sources). **Any new Sources file exercised by a unit test MUST be added to that list in `project.yml`, then `make gen` re-run.**
- Any new local-only column on the `thread` table must be carried forward in `SyncEngine.deriveThread` (alongside `snoozeUntil`/`reminderAt`/`reminderSetAt`) or every sync silently nulls it. `ThreadDerivationTests.testLocalStateSurvivesRederivation` guards this — extend it when adding such a column.
- Do NOT hardcode `DEVELOPMENT_TEAM` in `project.yml`. Do not touch `Config/Signing.xcconfig` / `Config/Local.xcconfig`.
- New DB schema changes go in a new migration (next is v10) in `Database.swift`; never edit shipped migrations. Migration tests live in `DatabaseMigrationTests`.
- Match existing code style: parameterized SQL, async/await, no third-party deps beyond GRDB. UI follows the existing Notion-Mail-like theme in `Support/Colors.swift` / `Styles.swift`.
- All Gmail label mutations must round-trip through the existing GmailClient paths; local-only features (snooze, reminders, scheduled send) stay local — follow those precedents.
- Every task ends with the full suite green: `make test` (run `make gen` first if project.yml changed).
- Commit after each task with a descriptive message.

## Task 1: Batch thread re-derivation in SyncEngine

**Problem:** During incremental sync, for every touched message the engine re-fetches all messages in that message's thread and re-derives the thread row (`SyncEngine` calls `deriveThread` per touched message). A sync touching N messages in the same thread derives the thread N times, each with a full `Message.filter(threadId).fetchAll` query — O(n) redundant queries per sync.

**Requirement:** Within one sync pass, collect the set of distinct thread keys affected by touched/deleted messages, and derive each thread exactly once after all message upserts/deletes for the batch are applied. Behavior must be byte-identical for the resulting thread rows (same subject/snippet/participants/label union/metadata, and local columns preserved — see Global Constraints).

**Where:** `Sources/PerfectMail/Gmail/SyncEngine.swift` (both incremental history path and backfill path if it has the same shape).

**Tests:** Extend `ThreadDerivationTests` (or add a SyncEngine-level test if one exists): syncing multiple messages of the same thread produces a correct, single derivation; local columns (`snoozeUntil`, `reminderAt`, `reminderSetAt`) survive. If practical, assert derivation count via an injected counter or by restructuring into a testable pure function `deriveThreads(for keys: Set<String>)`.

## Task 2: Incremental contact mining

**Problem:** `MailStore.rebuildContacts()` scans ALL message header columns (`SELECT fromHeader, toHeader, ccHeader, labelIds FROM message`) on startup, after every sync, and on account add. Full table scan every 60-second sync cycle.

**Requirement:** Make contact mining incremental: persist a high-water mark (e.g., max message rowid or last-mined date per account — pick whatever is simplest and correct given the schema) and only mine messages newer than the mark, merging counts into the existing in-memory/persisted contact ranking. A full rebuild must still happen when: an account is added/removed, or the mark is missing/invalid. Ranking semantics (frequency + recency, sent-mail weighted higher) must not change.

**Where:** contact mining code in `Sources/PerfectMail/App/MailStore.swift` (extract into `Sources/PerfectMail/Support/ContactMiner.swift` if that makes it testable — remember project.yml test-target list). Persistence of the mark: UserDefaults or a small DB table — implementer's choice, justify in report.

**Tests:** New test file `ContactMinerTests` (add to project.yml): incremental pass over new messages merges correctly with prior state; full rebuild on missing mark; sent-mail weighting preserved.

## Task 3: Debounce chip-filter reloads and cache AI categories

**Problem A:** Every change to `MailStore.chips` (filter chips) triggers a full `reloadThreads()` (up to 300-thread query) via a `didSet`. Rapid chip toggling causes redundant full reloads.
**Requirement A:** Debounce chip-triggered reloads (~150–250ms) so a burst of chip changes causes one reload. View switches and explicit refreshes stay immediate. Use a Task-based debounce on the MainActor (match existing async style); no Combine dependency if the codebase doesn't already use it.

**Problem B:** `loadAICategories()` fetches all `threadAI` rows from the DB on every thread reload.
**Requirement B:** Cache the category map in memory; invalidate/refresh only when a classification run completes or rows are mutated (classify, clear). Reloads between mutations must not hit the DB for categories.

**Where:** `Sources/PerfectMail/App/MailStore.swift`.

**Tests:** Debounce timing is hard to unit-test in hostless target — acceptable to test the cache logic only: new or extended test asserting `loadAICategories` (or its extracted cache type) hits the DB once until invalidated. If the cache is extracted to a small type, add it to project.yml.

## Task 4: Auto-advance after archive/trash

**Problem:** After archiving (`e`) or trashing (`#`) the selected thread, selection should move to the next thread in the visible list (Superhuman-style inbox-zero flow) instead of dropping selection / leaving a gap. `Sources/PerfectMail/Support/SelectionAdvance.swift` (12 lines) exists and is used in key navigation — check what it already does.

**Requirement:** After archive, trash, or spam-marking of the currently selected thread from the list or the reading pane, selection advances to the next thread below (or the previous one if the removed thread was last in the list). Works across grouped sections. If the list becomes empty, selection clears and the reading pane closes. Snooze should behave the same way. Undo (z) restoring the thread does not need to restore selection.

**Where:** `SelectionAdvance.swift`, call sites in `MailStore.swift` / `ThreadListView.swift` / key-command handling.

**Tests:** Extend the existing SelectionAdvance/keybinding tests: advancing from middle, from last item (falls back to previous), from only item (clears).

## Task 5: Priority split inbox with VIP senders

**The flagship feature.** The Inbox view gets a pinned **Priority** section at the top, containing threads that are: starred, OR carry Gmail's `IMPORTANT` label, OR are from a VIP sender. Everything else renders below under the existing grouping ("Everything else" when date-grouped).

**Requirements:**
1. New `vipSender` DB table (migration v10): `email TEXT PRIMARY KEY COLLATE NOCASE` (global across accounts; keep it simple). CRUD in Database/MailStore.
2. Thread qualifies as VIP if any participant-from address (the `fromHeader` of any message, or the thread's derived from) case-insensitively matches a VIP email.
3. Priority section: pinned at top of the Inbox view only (not Starred/Sent/etc.), sorted by date desc like the rest. Threads in Priority do NOT repeat in the sections below. Section header "Priority" with a subtle star/flag glyph consistent with theme.
4. Toggle: Settings → Appearance gets "Show Priority section in Inbox" (default ON), persisted in UserDefaults.
5. Managing VIPs: (a) thread context menu + reading-pane sender menu get "Add <sender> to VIPs" / "Remove from VIPs"; (b) Settings → new "VIP senders" list pane (add by email, remove) OR fold into an existing pane if a new pane is disproportionate — implementer judgment, note in report.
6. Command palette: "Add sender to VIPs" action for the selected thread.
7. Performance: VIP matching must not add per-row DB queries — load the VIP set into memory once, refresh on mutation.

**Where:** `Database.swift` (migration v10), `MailStore.swift` (VIP set, partition logic), `ThreadListView.swift` (pinned section), `SettingsView.swift`, `CommandPalette.swift`.

**Tests:** DatabaseMigrationTests extended for v10. New/extended partition tests: thread partitioning into priority vs rest given starred/IMPORTANT/VIP inputs; no duplication; case-insensitive VIP match. Add any new source files to project.yml test list.

## Task 6: Quick Look attachment previews

**Problem:** Attachments currently download to disk and open in the system app. No inline preview.

**Requirement:** Spacebar (and a context-menu "Quick Look" item) on an attachment chip in the reading pane opens the native Quick Look panel (`QLPreviewPanel` via Quartz framework). The file is downloaded to a temp/cache location first if not already downloaded (reuse the existing attachment download path, including filename sanitization and quarantine attribute). Multiple attachments on a message: panel supports arrow-key navigation across all that message's attachments. Panel dismisses with spacebar/Esc per platform convention.

**Where:** attachment UI in `ThreadDetailView.swift` (or its attachment subview), new small `Support/QuickLookPreview.swift` NSViewRepresentable/controller bridge as needed. Add Quartz framework linkage in `project.yml` if required.

**Tests:** Quick Look is UI-bound; unit-test what's testable — the temp-path resolution/reuse logic and that download-before-preview reuses the sanitized filename path. UI behavior verified by build + manual smoke instructions in the report.

## Task 7: Behavior-preserving decomposition (simplification)

**Problem:** `MailStore.swift` (~1,706 lines, 91+ methods) mixes sync orchestration, filtering, contacts, AI, notifications. `ThreadListView.swift` (1,032) embeds all grouping logic. This is a maintainability refactor — NO behavior change.

**Requirements (scoped, in order of value):**
1. Extract thread-grouping/partitioning pure functions from `ThreadListView.swift` into `Sources/PerfectMail/Support/ThreadGrouping.swift` (they're already pure — move + rename only). Add to project.yml test list; move/point existing grouping tests at it.
2. Extract AI/classification concerns from MailStore into `Sources/PerfectMail/Support/AIService.swift` (summarize/draft/classify orchestration + the Task-3 category cache), keeping MailStore as a thin forwarder where UI needs it.
3. Extract contact mining (if Task 2 didn't already) into `ContactMiner.swift`.
4. Only if the above go smoothly and tests stay green: extract notification/badge logic into `NotificationService.swift`. Do NOT attempt a full SyncCoordinator extraction in this pass — too risky; leave a `// MARK:` organization pass in MailStore instead.

**Constraint:** zero behavior change; every extraction compiles and passes `make test` before the next begins; separate commit per extraction so any one can be reverted.

**Tests:** existing suite must stay green throughout; moved tests keep coverage. No new behavior = no new behavior tests, but add a basic unit test for any newly-public pure function that lacked one.
