---
date: 2026-08-24 16:40
kind: fable-iterate review
review_model: claude-fable-5
review_effort: low
requested_model: claude-fable-5
resolved_model: claude-fable-5
canonical_model: claude-fable-5
model_substitution: none
modelResolutionVerified: false (usage and resolvedModel are claude-fable-5)
job_id: review-20260824T163802-9370
branch: fix/model-picker-curation
base: main (11eb998)
reviewed_commit: 3ffb0d0
verdict: NOT READY
started_at: 2026-08-24T23:38:02Z
finished_at: 2026-08-24T23:40:02Z
checks: make test → TEST SUCCEEDED, 1708 tests, 5 skipped, 0 failures
total_cost_usd: 1.65504
num_turns: 11
duration_ms: 117175
---

# Review pass 1 — hide stale models in the picker

## Prompt

```
Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Hide irrelevant models in the Ask Mish picker. grok-4.2 is irrelevant and must not be the default. Hide old Google models the same way. Restore the missing Google Gemini logo in the picker.
```

## Verbatim review

`make test` passes: 1708 tests, 0 failures. The picker curation, the grok-4.6 default, and the Gemini mark all work as asked. One medium problem remains.

## Findings

**Medium — Settings task picker can show a model that is not the one in use.**
`TaskModelPicker.entries` now curates the list (`SettingsView.swift:2024`). A stored stale assignment, for example drafts → `grok-4.2`, is no longer an entry. `selected` then falls back to the first entry for that provider (`SettingsView.swift:2049`) and the picker shows `grok-4.6`. But `LLMTaskRunner.resolve` still returns the stored `assignment.model` (`LLMTaskRunner.swift:13-21`). So drafts, summaries, and triage keep the stale `grok-4.2` model while the UI shows a current one. Before this change, the stale model was in the list, so the display was at least honest. Note this hits the exact users the fix targets: users whose stored default is `grok-4.2`. Only Ask Mish gets a correction (`AskMishController.swift:111-116`), and that correction is in-memory only — the stored assignment stays stale.

**Low — `hiddenCount` is not exact.**
`total` is captured at `AskMishModelMenu.swift:39`, before the vendor fallback ids append at lines 41-46. When fallbacks add entries, `total - list.count` under-counts what curation hid, and `max(0, …)` can hide a negative. Cosmetic — it feeds only the "N more" label.

**Low — the dated-snapshot filter misses 8-digit dates.**
The regex `-\d{4}$` (`AskMishModelMenu.swift:112`) drops `gpt-4-0613` style ids but not `claude-…-20250219` style ids. The doc comment says dated snapshots stay out of browse; for Anthropic ids they do not. Grok's `-1212` ids are still caught by the `grok-2`/`grok-3` prefix rules, so no user-visible effect today.

**Low — broad substring drop-words.**
`isBrowseWorthy` drops any id that contains "image", "audio", "vision", or "voice" (`AskMishModelMenu.swift:105-110`). A future multimodal chat id such as `gpt-5-audio-chat` would vanish from browse. Search still reaches it, so this is acceptable.

Verified good: the `grok-4.2` versus `grok-4.20` carve-out is correct and tested; search bypasses curation (`AskMishModelMenu.swift:184`, test at `AskMishModelMenuTests.swift:157`); `brandAsset` now matches on host and OAuth vendor, and the `ProviderGemini.imageset` asset exists; pricing entries for the new ids are present and tested; the default-badge in the picker row uses `preferredDefault` while the context menu keeps the stored default, which is a sensible split.

## Open questions

1. Should stale task assignments migrate on load? A one-time rewrite in `LLMProviderStore.assignment(for:)` (or at load) would fix the Medium finding for all four tasks and make the Ask Mish fix persistent.
2. Is it intended that the Settings task picker also hides old models? A user can no longer assign `gemini-2.5-flash` to summaries from that picker at all — search exists only in the Ask Mish popover.

## Suggested fixes (not applied)

- For the Medium finding, pick one: (a) apply the `preferredDefault` rewrite inside `LLMProviderStore.assignment(for:)` and persist it, or (b) in `TaskModelPicker.entries`, pin the stored `assignment.model` into the list the way Ask Mish pins the active selection, so the display stays truthful.
- Snapshot `total` after the vendor fallback append, or compute `hiddenCount` from the pre-curation list minus the shown set.

## Verdict

**NOT READY** — one medium fix needed. The Settings picker can display a model different from the one a task actually runs, and the stale `grok-4.2` assignment persists for drafts, summaries, and triage. The rest of the change is solid and well tested.
