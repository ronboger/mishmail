---
date: 2026-07-31 15:34
kind: fable-review
target: exp/fable-handoff-ex02-treatment-fable-draft-card vs f0ef2e2
verdict: SHIP
reviewer: Fable (jacq-claude, model=claude-fable-5, effort=low)
job_id: review-20260731T153238-78920
reviewed_commit: a9a6a16ee654db84efa7263f273da8dc5c21b2db
total_cost_usd: 0.560967
agentModelUsage: {"claude-fable-5": {"inputTokens": 9589, "outputTokens": 6948, "cacheReadInputTokens": 301244, "cacheCreationInputTokens": 30192, "webSearchRequests": 0, "costUSD": 0.560967, "contextWindow": 200000, "maxOutputTokens": 32000}}
---

# Fable Review — Fable-direct draft-card experiment (ex02)

# Review: draft-card-while-composing (f0ef2e2..HEAD, Fable-direct arm)

## Findings by severity

**No high-severity issues.** The M1-class bug from the loop arm (stale composing-draft claim) is correctly avoided here — verified below.

### M1 (Medium) — Banner tap can reopen the draft compose is already editing (sibling-draft case)
`ThreadDetailView.swift:157-159`: the banner shows when a *sibling* draft is visible (`hasThreadDraft` correctly excludes the composing draft), but its action is `store.editDraft(inThread: thread)` → `newestDraft(inThread:)` (`MailStore.swift:5103-5106`), which is **not** filtered by `composingDraftIds`. If the thread has two live drafts and the one being composed is the newest, the banner appears (because of the sibling) but tapping it re-opens the composing draft — replacing the active compose with itself instead of continuing the sibling the banner advertised. Narrow edge case (two drafts in one thread), but the banner's own comment says "Continues the newest draft" while its visibility logic now means "a *visible* draft exists."
*Fix:* pick newest from `ComposingDraftVisibility.visibleLiveDrafts(...)` in the banner action, or have `editDraft(inThread:)` accept an exclusion set.

### L1 (Low) — Minimized compose keeps the card hidden
`composingDraftIds` (`MailStore.swift:1108-1117`) doesn't consider `composeMinimized`. With compose minimized, the thread shows neither the draft card nor the banner; the only trace of the draft is the minimized bar. Arguably fine (tapping a card would still spawn a duplicate-ish reopen), but "the editor *is* the draft" is weaker when the editor is collapsed. Deliberate-looking; flag only.

### L2 (Low) — Intermediate autosave-chain ids briefly unhidden
Hidden set = `editDraftId` + `restoreDraftId` + *latest* live id. If autosave re-creates the draft twice (d1→d2→d3) and a thread refresh lands while d2 still exists server-side (delete not yet propagated), d2's card could flash. Transient, self-healing on next refresh. Not worth complexity.

### L3 (Low) — Test gap: MailStore-level id-chain guards untested
`ComposingDraftVisibilityTests.swift` covers only the pure helper. The actual M1-prevention logic — `noteComposeLiveDraft` ignoring a stale `requestId` (`MailStore.swift:1123-1126`), `composingDraftIds` returning `[]` after `clearComposeRequest`, and the `requestId == req.id` match in the computed property — has no tests. That's exactly where the loop arm's known bug lived; a couple of MailStore tests (or extracting the guard into the pure enum) would lock it in.

## Correctness vs the checklist

1. **Double surface on Continue** ✅ — `editDraft.id` hidden immediately on open (`ThreadDetailView.swift:205`), before any autosave.
2. **Muted chrome** ✅ — sender line + preview `.secondary` (`ThreadDetailView.swift:1248,1276`); pill/rail untouched. Cosmetic-only.
3. **replacingDraft/autosave chain** ✅ — `ComposeView.swift:450` reports each `saved.id`; hidden set includes both opened and live ids (`testAutosaveDivergenceHidesBothIds`).
4. **Late autosave after replace/close** ✅ — `noteComposeLiveDraft` guards on `composeRequest?.id == requestId`; `clearComposeRequest` nils `composeLiveDraft` (`MailStore.swift:1172`). The one direct-nil site (demo teardown, `MailStore.swift:1554`) leaves a stale tuple, but it's inert: `composingDraftIds` requires a live request with matching UUID. No permanent-hide path found.
5. **Multi-compose overlap** ✅ — single `composeRequest` slot; each new `ComposeRequest` gets a fresh `let id = UUID()`, and presentation mutations (pop-out/split/promote) copy the struct so the id is preserved — the guard stays valid across placement changes.
6. **Undo-send suppression** ✅ — `suppressedDraftMessageIds`/`setPendingDraftSuppressed` untouched; on send, suppression takes over from the composing-hide (both target `liveDraft`, `ComposeView.swift:1900` / `MailStore.swift:4678`), so no reappear gap. Undo restore re-covers via `restoreDraftId` (`MailStore.swift:4692`).
7. **Tests** ✅/⚠️ — pure-helper coverage is good (divergence, restore, discarded-draft exclusion, banner-empty case); MailStore guard layer untested (L3). `project.yml` registers the new source file.

## Open questions
- Is hiding the card while compose is **minimized** intended (L1)?
- Should the banner ever appear while compose is open at all? Even continuing a sibling draft replaces the current compose — you may want `showDraftBanner` to also require `composeRequest == nil` for the bound thread.

## Suggested fixes (not applied — read-only)
1. **M1:** `editDraft(inThread:)` variant excluding `composingDraftIds`, used by the banner.
2. **L3:** Add 2–3 MailStore tests: stale-requestId autosave ignored; `composingDraftIds` empty after clear; live-id survives placement mutation.

## Verdict: **SHIP**
The core hide/unhide logic is correct, the stale-claim failure mode is structurally prevented (requestId keying + clear-on-close), and undo-send is untouched. M1 is a real but narrow sibling-draft edge worth a follow-up, not a blocker.
