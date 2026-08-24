---
date: 2026-08-24 16:45
kind: fable-iterate review
review_model: claude-fable-5
review_effort: low
requested_model: claude-fable-5
resolved_model: claude-fable-5
canonical_model: claude-fable-5
model_substitution: none
modelResolutionVerified: false (usage and resolvedModel are claude-fable-5)
job_id: review-20260824T164214-12927
branch: fix/model-picker-curation
base: main (11eb998; origin/main has since moved to b112258)
reviewed_commit: e5db8e4
verdict: SHIP
started_at: 2026-08-24T23:42:15Z
finished_at: 2026-08-24T23:45:03Z
checks: make test → TEST SUCCEEDED, 1709 tests, 5 skipped, 0 failures
total_cost_usd: 2.022463
num_turns: 14
duration_ms: 165539
---

# Review pass 2 — hide stale models in the picker

## Prompt

```
Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Hide irrelevant models in the Ask Mish picker. grok-4.2 is irrelevant and must not be the default. Hide old Google models the same way. Restore the missing Google Gemini logo in the picker.

Pass 1 returned NOT READY: stale grok-4.2 assignments still ran drafts/summaries/triage while Settings showed Grok 4.6. That is now resolved in LLMProviderStore.assignment(for:), which migrates non-browse-worthy models to preferredDefault and persists. hiddenCount now counts stored ids not shown. Dated 8-digit snapshots are dropped. Re-check those fixes.
```

## Verbatim review

All 1709 tests pass. Review is complete. Here is the report.

## Pass-2 verification of the pass-1 fixes

All three fixes are real and tested:

- **Stale assignment migration**: `LLMProviderStore.assignment(for:)` (`Sources/MishMail/Support/LLMProviderStore.swift:162-179`) now runs `resolvedAssignment`, which replaces a non-browse-worthy model with `preferredDefault` and persists it. `testStaleAssignmentMigratesToPreferredDefault` stores grok-4.2, reads back grok-4.6, and reads a second time to prove persistence. Drafts, summaries, and triage all go through this path via `LLMTaskRunner.swift:13`.
- **hiddenCount**: now counts stored ids not shown (`AskMishModelMenu.swift`, `hiddenCount(stored:shown:)`). The oversized-list test asserts an exact count of 300.
- **Dated snapshots**: `-\d{8}$` drops 8-digit dates. `testGrok42IsNotThePreferredDefault` asserts `claude-sonnet-4-20250514` is not browse-worthy.
- **Gemini logo**: `brandAsset` now resolves through `subscriptionVendor` (host match on `generativelanguage.googleapis.com`), the `ProviderGemini.imageset` asset exists, and a test covers a provider labeled "Studio" with no "google" in the label.

## Findings

**1. Medium — an explicit "set default" of a hidden model reverts silently.**
Evidence: `AskMishPanelView.swift:202-208` (`setDefaultModel`) writes the chosen model as `defaultModel` and as the `.askMish` assignment. Search intentionally reaches hidden models (`AskMishModelMenu.swift` search doc: "search is how a hidden model is reached"). But the next `assignment(for: .askMish)` read migrates the choice back to the vendor fallback, and `preferredDefault` also ignores a non-browse-worthy `defaultModel`. So a user who searches for a hidden model and sets it as default gets grok-4.6 for every new chat anyway. The current chat keeps the selection, so the damage is limited. This matches the task for grok-4.2, but it applies to every hidden id with no way to opt out. A pin does not help: pins feed browse, not `preferredDefault`.

**2. Low — YYYY-MM-DD dated snapshots pass the filter.**
`isBrowseWorthy` drops `-\d{4}$` and `-\d{8}$`, but OpenAI-style ids such as `gpt-4o-2024-08-06` end in `-06` and pass. The task scoped Grok and Google, so this is a gap, not a regression.

**3. Note — the diff against main shows an unrelated revert; it is not real.**
`git diff main` removes the arrow-browse code (`ReadingPaneSpaceScroll`, `browseOpensDetail`, `ContentView` key handling). The branch forked from `11eb998`, before main got `b112258`. The branch commits do not touch those files (`git diff 11eb998..HEAD --stat` confirms). A merge keeps main's version. Rebase or merge normally; do not squash-apply this diff as a patch.

## Open questions

- Is the silent migration of a deliberately chosen hidden model (finding 1) acceptable? If yes, no change is needed.

## Suggested fixes (not applied)

- For finding 1: skip migration when the stored model is in `provider.pinnedModels`, or record a "user chose this" flag in `LLMTaskAssignment` and only migrate unflagged rows.
- For finding 2: also drop names that match `-\d{4}-\d{2}-\d{2}$`.

## Verdict

**SHIP.** The pass-1 blockers are fixed, tested, and persist correctly. `make test` passes: 1709 tests, 0 failures. Finding 1 is a design tension outside the requested task; findings 2 and 3 are minor.
