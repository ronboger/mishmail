---
date: 2026-07-30
kind: fable-review
target: fix/trashed-draft-hides-inbox vs main
model: claude-fable-5
effort: low
pass: 1
reviewed_commit: 2860a911f908823932691b6a617e43305736607f
verdict: SHIP
note: jacq-claude failed (CLAUDE_CONFIG_DIR auth); review via direct claude CLI with same model/effort/flags
---

# Fable Review Pass 1 — trashed-draft hides inbox

## Code Review — discarded drafts pinning `inTrash`

I traced the diff against callers of `syncFlagsFromLabelIds`, `applyLabelMutation`, the prune paths, and the migration history. Findings by severity:

### Medium

**M1. Migration v30 clears `inTrash` on threads with zero cached messages.** `trashDraftFlags(labelIdStrings: [])` returns `(false, false)` (guard at `SyncEngine.swift:849`), and v30 unconditionally writes those values for *every* thread row (`Database.swift:1297-1306`). If a thread row exists without cached messages, a genuinely trashed thread would get `inTrash=0` — and if it still has `inInbox=1`, it resurfaces in Inbox. Mitigation: `pruneLocalMail` rebuilds threads "from what remains," so orphan thread rows should normally be deleted — but v30 offers no defense if any exist (crash-between-prune-and-rebuild, older bugs). A cheap fix: skip the `UPDATE` when `labelStrings.isEmpty`. Low likelihood, so Medium not High.

### Low

**L1. New inbound reply to a user-trashed thread stays hidden.** If the user trashed the thread (non-draft messages carry TRASH) and Anna replies later, `anyNonDraftTrash` pins `inTrash=true` while `inInbox` goes true — thread stays out of Inbox until old messages lose TRASH server-side. Gmail resurfaces the conversation. This is **not a regression** (the old union had the same behavior), just a known limitation worth a comment/test.

**L2. `applyLabelMutation(remove: ["TRASH"])` also strips TRASH from the `labelIds` union** (`Database.swift:106`), losing the discarded-drafts' TRASH from search/chips until the next sync re-derives the union. Pre-existing pattern (same as INBOX/STARRED), self-healing, cosmetic.

**L3. v30 is O(threads) queries** — one `SELECT` + `UPDATE` per thread. `message.threadId` is indexed (`Database.swift:779`) and v29 uses the same pattern, so acceptable; a single `GROUP BY threadId` pass would be faster on large caches but isn't required.

### Correctness — checks that passed

- **Helper logic** (`trashDraftFlags`): live-draft / discarded-draft / all-trashed / mixed cases all derive correctly; `anyNonDraftTrash || (anyTrash && allTrashed)` handles the discarded-compose-only thread (goes to Trash, not Drafts) and the whole-thread-trashed case (drafts become DRAFT+TRASH but non-draft TRASH messages keep `inTrash=true`).
- **`syncFlagsFromLabelIds` callers**: only `applyLabelMutation` calls it in Sources; explicit TRASH/DRAFT flag sets happen *after* the call, so ordering is correct. Trash/untrash/spam flows in `MailStore.swift:4448-4459` go through `applyLabelMutation(add:/remove: ["TRASH"])`, so optimistic mutations still work.
- **Sync path**: `deriveThread` now uses per-message labels; the union still feeds `labelIds` for search/chips, matching the doc comments and the `SearchQuery.includesLocation` contract at `MailStore.swift:4207`.
- **Migration hygiene**: raw SQL only, no live-record decoding (consistent with the stated frozen-schema rule and with v29's pattern).

### Test coverage

Good: derivation tests (mixed thread, discarded-only, live draft), pure-helper table test, `syncFlags`/`applyLabelMutation` tests including the star-mutation-doesn't-re-pin case, and an end-to-end v29→v30 migration test with a realistic 4-message Fund Expense fixture. Missing (minor): a v30 case for a genuinely-trashed thread staying `inTrash=1`, and the empty-messages thread case from M1.

## Verdict

**SHIP** — the fix is correct for the reported bug, mutation and sync paths stay coherent, and coverage is solid. M1 is worth a one-line guard (`if labelStrings.isEmpty { continue }` — or explicitly decide orphan threads should be flag-cleared) either in this PR or a fast follow.
