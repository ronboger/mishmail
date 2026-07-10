# MishMail: Remaining Performance Work (post P0/P1)

## Context

MishMail is a native macOS Gmail client (SwiftUI, Gmail REST API, GRDB/SQLCipher). Hot paths: `MailStore.swift` (UI state + queries), `SyncEngine.swift` (sync), `Database.swift` (schema), `ThreadDetailView.swift` (reading pane).

### Already shipped or ready

| Tier | Status | What |
|------|--------|------|
| **P0** | On `main` (commit era ~`15e2682`) | Parallel incremental `getMessage` (concurrency 8); incremental contact mining + high-water mark; async `reloadThreads` + generation tokens; optimistic list updates for archive/trash |
| **P1** | On `main` (era ~`e78ac26` / version bump `c056c7c`) | Lazy message bodies on open/expand; label-only history without `format=full`; denorm thread flags (`inSent`/`inDrafts`/`inPromotions`/`inSocial`/`fromEmail`); aggregate badge SQL + VIP off list path; parallel multi-account `syncAll`; FTS v17 without `bodyText`; `HTMLWebViewPool`; P1 review fixes (any-message VIP/blocklist, batch label writes, WebView isolation) |
| **Phase 1 PR1–PR3** | Branch `perf/phase1-db-scale` (worktree `.worktrees/perf-phase1`) | v18 composite list indexes; chunked SyncEngine writes; backfill without full gmailId Set. PR4 (junction) **not** done — stop-and-measure first. |

**Prerequisite (done):** P1 landed on `main` (v16–v17). This plan's Phase 1 starts at **v18**.

Day-to-day inbox feel should already be good. Remaining work is **scale** (50k–100k messages), **backfill cost**, and **reading-pane / network edges**.

---

## Global Constraints

- Build/test: `make gen` (xcodegen), `make test` (hostless `MishMailTests`). Any new `Sources/` file used by unit tests **must** be listed under `MishMailTests` sources in `project.yml`, then `make gen`.
- Local-only thread columns (`snoozeUntil`, `reminderAt`, `reminderSetAt`, …) must survive `SyncEngine.deriveThread`. Extend `ThreadDerivationTests.testLocalStateSurvivesRederivation` when adding such columns. Denorm flags are **derived**, not local-only — set in `deriveThread` and keep coherent on local label mutations (`MailThread.syncFlagsFromLabelIds()`).
- New schema = **new migration only** (next is **v18** after P1). Never edit shipped migrations. Extend `DatabaseMigrationTests`.
- No hardcoding `DEVELOPMENT_TEAM`. Do not touch `Config/Signing.xcconfig` / `Config/Local.xcconfig`.
- Style: parameterized SQL, async/await, GRDB only (no new deps).
- Every task ends with `make test` green; commit after each PR/task with a descriptive message.
- Prefer worktree isolation (e.g. `.worktrees/perf-phaseN`) for multi-PR epics.
- Measure before claiming wins: large fixture (or long sync window) + optional `OSSignposter` on `fetchAll`, upsert writes, `reloadThreads` SQL, `messageHeaders` / body load.

### Out of scope (do not do in this plan)

- Replacing GRDB or rewriting the sync architecture
- Re-adding full body text to FTS (body search stays server-side via `searchAllGmail`)
- SwiftUI animation micro-tweaks
- Over-indexing every column “just in case”

---

## Phase 0 — Land P1 (gate)

**Do this first; block Phase 1 until done.**

1. In `.worktrees/perf-p1-six` (or checkout `perf/p1-six`): rebase/merge latest `main`.
2. `make test` && `make build`.
3. Manual smoke: long multi-message HTML thread (expand older msgs); archive `e` auto-advance; Sent/Drafts/Promotions views; multi-account Sync All; subject/from local search (body may need “Search all mail”).
4. Merge to `main`.
5. Optional: remove worktree `git worktree remove .worktrees/perf-p1-six`.

---

## Phase 1 — Scale the DB (highest ROI left)

**Goal:** Stay fast at ~50k–100k messages.  
**Branch suggestion:** `perf/phase1-db-scale`  
**Success metrics:** inbox list + badge SQL time; backfill peak memory; Labels view query time (if PR4 lands).

### PR1 — Composite / partial indexes (v18)

**Problem:** Hot queries filter denorm flags + `lastDate` / `inTrash` without covering indexes; badge aggregates still scan more pages than needed under SQLCipher.

**Requirement:**
- Migration **v18**: indexes matching real queries, e.g.:
  - `(inInbox, inTrash, lastDate DESC)` or equivalent GRDB/SQLite form
  - `(inDrafts, inTrash)`, `(inSent, inTrash)`, `(inPromotions, inTrash)`, `(inSocial, inTrash)`
  - `(isStarred, inTrash)`, `(accountId, lastDate DESC)` if not redundant with existing
  - Only add indexes justified by `baseQuery` / `fetchSidebarCounts` — document each in a comment
- No behavior change.

**Where:** `Database.swift`, `DatabaseMigrationTests`.

**Tests:** Migration applies on empty + pre-seeded DB; optional note in test that index exists (`sqlite_master`).

**Effort:** ~0.5–1 day. **Expected gain:** ~10–40% on inbox/drafts/sent list + counts at scale.

---

### PR2 — Chunked write transactions in SyncEngine

**Problem:** Concurrent `getMessage` is good, but each `upsert` often hits `db.write` separately → SQLCipher transaction overhead dominates backfill/catch-up.

**Requirement:**
- Buffer parsed messages (and attachment rows) and commit in chunks (e.g. **25–50** messages per write transaction) in `fetchAll` and incremental full-fetch path.
- Label-only local patches can stay one-tx-per-message or batch per history page — pick simplest correct approach.
- Progress callbacks still fire periodically.
- On failure mid-chunk: document behavior (whole chunk rolls back is fine).

**Where:** `SyncEngine.swift` (and tests under `MishMailTests` if you extract a batch helper).

**Tests:** In-memory DB: N upserts via batch helper → N rows, single derivation pass still works; partial failure doesn’t corrupt schema.

**Effort:** ~1–2 days. **Expected gain:** ~20–40% less write time on backfill/catch-up.

---

### PR3 — Backfill without loading all `gmailId`s into a Set

**Problem:** `fetchAll` does `SELECT gmailId FROM message WHERE accountId = ?` into a `Set` — memory and startup cost grow with mailbox size.

**Requirement:**
- Replace full-set load with one of:
  - Temp table of listed IDs + anti-join for missing, or
  - Per-page existence check, or
  - `INSERT OR IGNORE`-style flow that only downloads missing
- Must not re-download already-cached messages; must not skip truly missing ones.
- Memory for “existing ids” must not be O(all messages in account) for the common path.

**Where:** `SyncEngine.fetchAll`.

**Tests:** Seed account with known gmailIds; list mix of existing + new; only new downloaded (mock fetcher / inject existing filter if pure helper extracted).

**Effort:** ~1–2 days. **Expected gain:** large memory win at 50k–100k msgs; modest wall-time win on window changes.

---

### PR4 — User-label junction table (optional same epic)

**Problem:** User labels / Labels view / `label:` search still use `labelIds LIKE '%…%'` (system labels already denorm’d in P1).

**Requirement:**
- Migration **v19** (or next free after v18): `thread_label(threadId TEXT, labelId TEXT, PRIMARY KEY (threadId, labelId))` + index on `labelId`.
- `deriveThread` (or post-derive) rewrites junction rows from message label union (user labels: Gmail ids like `Label_*`; system labels can stay denorm-only).
- `toggleLabel` / local mutations update junction + `labelIds` string.
- `baseQuery` for `.labels`, `.label(account, id)`, and search `label:` use junction (or JOIN) instead of LIKE where possible.
- Keep `labelIds` string for display / debugging if useful.

**Where:** `Database.swift`, `SyncEngine.deriveThread` / `deriveThreads`, `MailStore` label mutations + `baseQuery` / search.

**Tests:** Migration; derive from multi-label messages; toggle add/remove; query returns correct threads; no false partial-token matches.

**Effort:** ~2–4 days. **Expected gain:** Labels view / label filters **3–10×** at 10k+ threads.

**Order within Phase 1:** PR1 → PR2 → PR3 → PR4 (PR4 can slip to a follow-up epic if time-boxed).

---

## Phase 2 — Reading pane 2.0

**Goal:** Open/navigate long HTML threads with near-zero hitch.  
**Depends on:** P1 lazy bodies + WebView pool landed.  
**Branch suggestion:** `perf/phase2-reading-pane`

### PR5 — Off-row message bodies

**Problem:** Bodies in the `message` row still inflate page size; even header projections can pay SQLCipher costs when co-located with large blobs.

**Requirement:**
- Migration: `message_body(messageId PK FK→message, bodyText, bodyHTML)` (or equivalent).
- Migrate existing body columns into the new table; leave `message.bodyText`/`bodyHTML` empty or drop columns in a careful multi-step migration (prefer: copy then null out, later migration drop if needed).
- `MessageParser` / upsert write body table; `messageHeaders` reads message only; `messageBody` / `messagesWithBodies` join or second query.
- Compose/reply/forward and AI summarize keep full bodies.
- FTS stays subject+from only (no body).

**Tests:** Migration preserves body content; header fetch has empty bodies; body fetch returns full text; delete message cascades body row.

**Effort:** ~2–3 days. **Expected gain:** another **1.5–3×** on open path for fat HTML caches.

---

### PR6 — Prefetch neighbor thread

**Requirement:** After opening thread T, background-load headers + last-message body for next/prev in `displayOrder` (cancel on selection change). Do not block UI; cap concurrency at 1.

**Where:** `MailStore` / `ThreadDetailView` / selection handlers.

**Tests:** Hard to unit-test; pure “neighbor ids” helper + manual smoke (j/k feels instant).

**Effort:** ~0.5–1 day.

---

### PR7 — P1 nits (if not already fixed on `perf/p1-six`)

Check before implementing — P1 review commit may already cover some:

- VIP / blocklist match **any** message From in thread (not only newest `fromEmail`) — may already be fixed.
- `needsBodyLoad` / hydrated flag so truly empty bodies don’t re-fetch forever.
- WebView pool isolation (no cross-message bleed) — may already be fixed.

**Effort:** small if still open.

---

## Phase 3 — Network edge

**Goal:** Catch-up when Gmail RTT dominates.  
**Branch suggestion:** `perf/phase3-network`

### PR8 — Gmail HTTP batch get (feature-flagged)

**Requirement:**
- Optional batching via `batch/gmail/v1` for multi-`getMessage` (and later modify if natural).
- Feature flag or UserDefaults kill-switch; fall back to concurrency-8 REST.
- Handle partial batch failures; respect size limits.

**Where:** `GmailClient.swift`, call sites in `SyncEngine`.

**Tests:** Parse batch response with mixed success/failure (fixture data); flag off = old path.

**Effort:** ~2–3 days. **Expected gain:** ~1.5–2× on multi-get when network-bound (quota still applies).

---

### PR9 — History `format=metadata` fallback

**Requirement:** When full body not needed but local message missing or labelIds missing from history, try `getMessage(format: metadata)` before `full` where sufficient for local row coherence; document when `full` is mandatory (`messagesAdded`, missing payload fields).

**Tests:** Pure decision helper: given history event + local existence → metadata vs full.

**Effort:** ~1–2 days. Correctness-sensitive.

---

## Phase 4 — Product scale (only if users hit the 300-thread cap)

### PR10 — Cursor pagination for thread list

**Requirement:**
- Replace or extend hard `limit(300)` with cursor by `lastDate` (+ id tie-break) and “Load more” or end-of-list fetch.
- Keyboard nav / `displayOrder` / selection advance remain correct across pages.
- Don’t load unbounded rows into `@Published threads` without a window strategy.

**Effort:** medium product + engineering. **Gain:** scales; not faster for top-of-inbox.

Defer until real users hit the cap.

---

## Explicitly deferred (Tier C / later)

| Item | Notes |
|------|--------|
| Cache `ThreadListView` grouping / recompute `displayOrder` only on input change | Small polish (~1–5ms) |
| Bounded concurrent AI classify | Only if auto-classify is a measured bottleneck |
| Parallel attachment download | Attach-heavy users only |
| Full offline body search | Conflicts with FTS trim strategy; use server search |

---

## Recommended default path

1. **Phase 0** — merge P1.  
2. **Phase 1 PR1–PR3** — indexes, chunked writes, no full gmailId set (high ROI, bounded risk).  
3. **Stop and measure** on a large real cache for a few days.  
4. Only if still needed: **PR4** (junction) and/or **Phase 2 PR5** (off-row bodies).  
5. **Phase 3** only if offline catch-up remains painful after P1 metadata history.  
6. **Phase 4** only if 300-thread cap is a real complaint.

### Rough effort (calendar)

| Slice | Effort |
|-------|--------|
| Phase 0 | 0.5 day |
| Phase 1 PR1–PR3 | 3–5 days |
| Phase 1 PR4 | +2–4 days |
| Phase 2 | 3–5 days |
| Phase 3 | 3–5 days |

---

## How to run this plan in a session

1. Create worktree from latest `main` (after Phase 0):  
   `git worktree add .worktrees/perf-phase1 -b perf/phase1-db-scale`
2. Implement **one PR at a time** (prefer sequential; parallelize only non-conflicting files).
3. After each PR: `make test`, commit, optional `make build`.
4. Prefer signposts + large fixture over micro-benchmarks in CI.
5. Do not start Phase 2 until Phase 1 PR1–PR3 are on `main` (or explicitly skipped with a written reason).

---

## File map (quick)

| Area | Primary files |
|------|----------------|
| Schema / migrations | `Sources/MishMail/Store/Database.swift`, `Tests/.../DatabaseMigrationTests.swift` |
| Sync / backfill | `Sources/MishMail/Gmail/SyncEngine.swift`, `GmailClient.swift` |
| List / badge / VIP | `Sources/MishMail/App/MailStore.swift` |
| Reading pane | `Sources/MishMail/UI/ThreadDetailView.swift`, `Support/WebViewPool.swift` |
| Derivation invariants | `Tests/.../ThreadDerivationTests.swift` |
| Test target list | `project.yml` → `MishMailTests.sources` |

---

## Implementation status (2026-07-09)

### Landed / ready to merge

| Item | Branch / note |
|------|----------------|
| Phase 0 | P1 on `main` (`80b0468` + `e78ac26`); rebased onto dark-mode/label-picker main before merge |
| Phase 1 PR1 | v18 composite indexes on `thread` for list paths (`flag, inTrash, lastDate`) + `accountId, lastDate` |
| Phase 1 PR2 | `writeChunkSize = 32`, `upsertPending` / `flushUpserts` on `fetchAll` + incremental full-fetch |
| Phase 1 PR3 | `filterMissingGmailIds` — per-page PK existence check; no O(mailbox) gmailId Set |
| Fable review fixes | Same branch: comments no longer claim badge use of indexes; secondary list indexes include `lastDate`; progress says “Fetched…” |

**Branch:** `perf/phase1-db-scale` (rebased onto `main` @ `c056c7c`). Skipped PR4 per plan stop-and-measure.

### Residual notes (from Fable review — do not lose)

Ship-with-nits; none of these block PR1–PR3 merge. Track for later:

1. **Badge / `fetchSidebarCounts` still full-table** — single `SUM(CASE…) FROM thread` cannot use list indexes. If counts hurt at 50k+: per-count `SELECT COUNT(*) WHERE …` or partial indexes involving `isUnread` (not in any index today).
2. **Optional: partial indexes** — e.g. `ON thread(lastDate) WHERE inSent=1 AND inTrash=0` may be smaller than 3-column composites; revisit only if measured.
3. **Chunked-path integration tests** — `ChunkedUpsertTests` exercises `upsertPending`, not real `fetchAll`/incremental with a mock `GmailClient`. Add if regressions appear (remainder flush was inspection-verified).
4. **Buffered × missing-check** — message still in write buffer can look “missing” on a later list page; re-download is idempotent. Note-only.
5. **P1 `applyBlocklist` cost** — any-message VIP/blocklist fix can scan inbox message Froms every sync when blocklist non-empty; unbounded `IN` ~32k. Follow-up: denorm any-From or bounded/joined form. `computeVIPThreadIds` is fine (capped by loaded 300).
6. **`make test -quiet`** — prints no “Executed N tests” summary; a silent pass can look like a no-op. Optional Makefile: drop `-quiet` or pipe for `Executed`.
7. **Measure before PR4 / Phase 2** — OSSignposter on `fetchAll`/flush + large real cache for a few days; only then junction table (PR4) or off-row bodies (PR5).
8. **Human smoke (P1 riskiest, unit tests miss)** — long multi-message HTML expand; WebView pool isolation; empty body no refetch loop; bulk mark-read history; Sent/Drafts after v18; interrupt mid-backfill and relaunch.
