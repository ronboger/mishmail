---
date: 2026-07-26 16:04
kind: review
reviewer: Fable 5 (Claude Code subagent, not a /codex:* command)
target: commit 7b85f6f "Cut database, main-actor, and SwiftUI invalidation costs"
verdict: needs-attention (0 blockers, 5 should-fix, 2 nits)
codex_session_id: n/a
job_id: n/a
duration: ~16m
invoked_from: /Users/ronboger/berkeley/ron_perfect_email/.claude/worktrees/app-performance-optimization-03c669
git_branch: claude/app-performance-optimization-03c669
git_head: 7b85f6f
diff_size: 21 files, 692 insertions / 181 deletions
focus: >
  @ObservationIgnored reachability audit; lost invalidation from the
  ObservableObject → @Observable switch; database lifecycle and pool-close
  races; correctness of the sync early-out; SQLite/SQLCipher pragma and
  VACUUM specifics; startup and polling behavioral regressions.
---

# Review of 7b85f6f — "Cut database, main-actor, and SwiftUI invalidation costs"

Build (`make gen && make build`) and the full test suite (`make test`) pass at this commit. Findings in priority order; each is marked **verified** (traced through the code) or **suspected**.

## 1. should-fix (verified) — partial-sync errors defeat the early-out: synced mail becomes invisible

`Sources/MishMail/App/MailStore.swift:2959` — the task-group catch returns `(id, error, .none)`, fabricating `.none` for an engine that may well have rewritten thread rows. `SyncEngine.incrementalSync` runs `deriveThreads` **before** throwing `partialFetch` (`Sources/MishMail/Gmail/SyncEngine.swift:429-439`), and the generic-error paths (prune/starred-backfill failures after a successful derive) behave the same. So on any partial pass, `anyThreadsChanged` stays false and the guard at `MailStore.swift:2993` skips `reloadThreads`, `notifyNewMail`, `rebuildContacts`, and `autoClassifyNewMail` — even though the thread table changed.

This directly contradicts the still-present comment at `MailStore.swift:2970-2971` ("Still run post-sync so successful upserts appear"): pre-commit that promise was kept by the unconditional `reloadThreads`; post-commit it is not. Note the single-account `sync(accountId:)` path *does* handle this correctly (`MailStore.swift:3032` drains the engine on partialFetch) — `syncAll` just never got the same treatment.

Impact: new mail lands in the DB but the list, badges, and notifications don't update for at least one more poll interval; under persistent Gmail rate-limiting (the very condition that produces `partialFetch`) the staleness repeats each tick. It does self-heal once a pass completes cleanly, because the engine accumulator is only cleared by `drainContentChange()` (`SyncEngine.swift:53-60`), so the retained keys ride along with the next successful drain — but "next clean pass" may be minutes away at the backed-off 3–5 min cadence.

Fix: drain in the catch — `return (id, error, await engine.drainContentChange())` — so partial work flows into both `applyThreadContentChange` and `anyThreadsChanged`.

## 2. should-fix (verified) — new untracked DB work can outlive shutdown; the shutdown comments now overclaim

The tracked-task list in `executeTermination` (`MailStore.swift:1597-1604`) covers six tasks plus the persistence tail. The commit adds DB work in unstructured tasks outside that list, in a codebase whose documented crash mode is exactly "live reader/writer outlives pool close" (`Database.swift:1209-1210`, `close()`'s own SQLITE_BUSY note at `Database.swift:451-454`):

- **The startup task** (`MailStore.swift:1292`) is untracked, and its tail is the worst case: `await AppDatabase.shared.reclaimSpaceOffMain()` (`:1323`) — a detached, untracked task running a **tens-of-seconds VACUUM**. `runDeferredStartupWork` checks `isShuttingDown` only at entry (`:1302`); there is no re-check before the VACUUM, and `reclaimSpaceIfNeeded` checks only `isClosed`, which is still false while close is pending. Interleaving: quit during the first minute after first launch on a big mailbox → `executeTermination` suspends (flushPendingSend / shutDown awaits), the startup task resumes on the freed main actor, dispatches the VACUUM, and `dbPool.close()` then either fails `SQLITE_BUSY` (process exits with a live writer → the historical SQLCipher-atexit EXC_BAD_ACCESS class) or the quit stalls behind the write. The commit's own retry comment ("interrupt during termination…") anticipates the VACUUM being aborted, but `interrupt()` only aborts statements already executing — it does nothing for one that starts after.
- **The timer-tick task body** now suspends across `applyBlocklist` / `notifyNewMail` / `autoClassifyNewMail` / `fireDueReminders` / `fireDueSnoozes` / `checkpointIfNeededOffMain` pool accesses. Pre-commit these were synchronous main-actor reads that could never interleave with `executeTermination` (also main-actor); now each can be mid-`pool.read` when close runs. Most check `isShuttingDown` only at entry; `fireDueReminders`/`notifyNewMail` not at all.
- `blockSender`'s `Task { await applyBlocklist() }` (`:929`) — same class, plus a per-hit remote task.
- `seedUnreadBaseline`'s read (`:3119`).

Two comments the commit adds are therefore inaccurate as claims: `MailStore.swift:1626-1629` ("Runs after every background reader has been cancelled and awaited") and `:2823-2826` ("Termination cancels and awaits every background reader"). Only tracked tasks are awaited.

Fairness note: engine syncs inside the tick task were already untracked pre-commit, so the *class* of hazard existed; but this commit meaningfully widens the window (previously-main-actor reads went async) and adds the single longest-running offender (VACUUM). Fix: store the init task in an `@ObservationIgnored` property and add it (and a handle for the tick body) to the tracked list; re-check `isShuttingDown` immediately before `reclaimSpaceOffMain`; consider an `isShuttingDown` gate on `AppDatabase` that makes `checkpoint`/`reclaimSpace` refuse to start once termination begins.

## 3. should-fix (verified, narrow window) — `loadAICategories` sets its loaded flag before the data arrives

`MailStore.swift:515-521`: `aiCategoriesLoaded = true` precedes the awaited read. A second caller during the in-flight read — `autoClassifyNewMail` (`:549`) racing the reload tail's call (`:2056`) — passes the guard and proceeds with an **empty** `aiCategories`, so `classify(candidates.filter { aiCategories[$0.id] == nil })` re-runs up to 100 already-classified threads through Ollama (minutes of model calls, "Sorting with AI… n/100" status churn, rewritten category rows). The late wholesale assignment at `:520` can also clobber map entries `classify` wrote in the interim. Impossible pre-commit (the function was synchronous, flag+map updated atomically on the main actor). Window is small — first load in flight plus a concurrent sync — but the failure is expensive when hit. Fix: single-flight (store the load `Task`, second callers `await` it) instead of a boolean.

## 4. should-fix (verified) — one-time VACUUM marker is a defaults key shared across three different databases

`Database.swift:481` (`db.vacuumed.v24bodies` in `UserDefaults.standard`) vs `supportDirectory()` (`:415-432`), which selects *different database files* (MishMail / MishMailDemo / MishMailUITests) while all three run modes share the same defaults domain. A `make run DEMO=1` or UITest run that executes first vacuums the tiny fixture DB and sets the global marker — the real 350 MB mailbox then **never** gets its one-time VACUUM, and because its `auto_vacuum` stays NONE, `incremental_vacuum(1000)` in `checkpoint()` is a permanent no-op there, so the file re-bloats with no recovery path. Same silent dead-end after `setAsideUnreadable` replaces a corrupted DB (marker stays set for a fresh file). End users with a single DB are fine; Ron's dev machine (which per the commit message is the actual 350 MB target, and which runs demo/UITest builds) is exactly the risky configuration. Fix: scope the key by database directory name, drop a marker file next to the DB, or just check `PRAGMA auto_vacuum` at startup instead of defaults.

## 5. should-fix, perf-only (verified) — the early-out doesn't stop per-tick SwiftUI invalidation

`applyAccounts` (`MailStore.swift:1770-1796`) reassigns `labelsByAccount` on every pass; its `didSet` rebuilds and reassigns `labelsById`/`labelsByName`. `@Observable` signals on assignment regardless of equality, so every ThreadListView body (which reads `labelsById` via `labelChip` per visible row — the exact work the dictionaries were added to cheapen), the FilterBar, and the sidebar re-render on **every** poll tick, `.none` or not. `accounts` legitimately changes each pass (`lastSyncAt` feeds the "last sync" display at `ThreadListView.swift:1022`), but labels almost never do. Not a regression vs `ObservableObject` (everything re-rendered then too), but it forfeits a large piece of what both the migration and the early-out were bought for. Fix: compare-before-assign in `applyAccounts` (`if labelsByAccount != grouped { … }`); longer term, split `lastSyncAt` out of the `Account` rows views iterate.

## 6. nit (verified) — async snapshot + whole-row save widens clobber windows

`applyBlocklist` (`:952-991`) and `fireDueReminders` (`:3165-3188`) now read a snapshot on a pool reader, suspend, then whole-row-`save` from that snapshot; a user mutation landing in the gap (e.g., starring a thread whose reminder just fired) is silently overwritten. `reloadAccountsOffMain` can similarly re-apply a pre-rename account snapshot for up to one poll interval. All were atomic on the main actor pre-commit. Millisecond windows on edge-case rows — worth knowing, not worth blocking.

## 7. nit (verified) — first-second startup gaps

A manual "Sync All" (palette/menu) within the first moments can run `applyBlocklist` before `loadBlocked()` has populated `blockedEmails` (no-op pass, heals next tick); compose's `/` snippet picker and the Scheduled sidebar row can render empty for the first frames. The unread-baseline race, by contrast, is handled correctly — I checked all interleavings of `seedUnreadBaseline` (`:3117-3122`) vs an early sync's `notifyNewMail` (`:3124-3129`); the adopt-on-first-sight flag produces the right outcome in each.

## Clean areas (checked, no findings)

- **A. `@ObservationIgnored` audit:** all 31 ignored properties are `private`, and I traced every usage site of each — all sit in reload/sync/timer/termination logic, none is reachable from any view body directly or through a non-private method/computed property a body calls. The deliberate `labelsById`/`labelsByName` didSet-republish reasoning holds. `contentRevision(of:)` (reads non-ignored `contentRevisions`) is only called from `.task`/`.onChange`, keyed on observed `threadContentToken`. Every view reading `selectedThread` in its body observes `ListFocusState` (`LabelPicker.swift:20`, `CommandPalette.swift:9`, `ThreadListView.swift:35`, `ContentView.swift:30`; ThreadDetailView reads it only inside `.task`). LabelPicker observes `LabelPickerState` via `@ObservedObject`, covering the `labelPickerLabels` query dependency the store deliberately hides. No `@EnvironmentObject var store: MailStore` remains anywhere.
- **D. Early-out data flow (modulo finding 1):** verified in `SyncEngine.swift` that label-only history patches feed `patchedKeys → deriveThreads → touchedThreadIds` (`:334-356`, `:446-448`, `:595`); message deletions insert the thread key (`:315-325`) and `deriveThreads` unions keys even when derivation skips a now-empty thread, so a thread emptied by deletions still reports; `pruneLocalMail`/window changes/`rebuildThreads` set `contentFullyRebuilt` (`:746`); the starred backfill flows through `flushUpserts → deriveThreads`. `syncLabels` and the per-pass `Account` row update are covered by the unconditional `reloadAccountsOffMain`.
- **E. SQLite specifics:** pragmas correctly placed after `usePassphrase`; `cache_size = -KiB` form correct; `auto_vacuum = INCREMENTAL` **then** `VACUUM` is the required order and does convert an existing file; `writeWithoutTransaction` is mandatory for VACUUM; `incremental_vacuum` before `wal_checkpoint(TRUNCATE)` is the right order for a zero-length WAL; error paths degrade to logging with retry-next-launch. The quit-path `checkpoint()` serializes behind any in-flight write on the writer queue, so no deadlock — only the finding-2 lifetime issue.
- **F. Polling observers:** registration guarded against duplicates, tokens removed in `executeTermination`, blocks capture `self` weakly, re-arm only on actual cadence change, and the 60 s staleness floor on the activation catch-up prevents alt-tab sync storms.

---

## Triage notes (Claude, before dispatching fixes)

Two of the review's claims were narrowed after independent verification:

- **Finding 4 is real but narrower than described.** Debug and Release are *separate* `UserDefaults` domains (`dev.ronboger.MishMail.debug` vs `dev.ronboger.MishMail`) — confirmed empirically: after a `make demo` run the debug domain had `db.vacuumed.v24bodies = 1` while the release domain had no such key. So the 350 MB Release mailbox was never at risk of being skipped by a demo/UITest run. The genuine bug is *within* the Debug domain, where the real/demo/UITest databases share one marker. Fixed anyway, and with the stronger fix (derive the state from `PRAGMA auto_vacuum` instead of a side-channel marker), which removes the class.
- **Finding 6 applies only to `fireDueReminders`.** `applyBlocklist` does not whole-row-save a stale snapshot: it routes through `mutateThread` → `enqueueThreadPersistence`, the serial write tail with an optimistic projection, and carries its own `guard !isShuttingDown`. Only `fireDueReminders` saves a pre-`await` snapshot directly, so only it was changed (to a narrow two-column UPDATE).

All 7 findings were dispatched for implementation; see the follow-up commit(s) on this branch.
