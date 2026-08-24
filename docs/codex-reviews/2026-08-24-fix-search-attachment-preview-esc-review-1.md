---
date: 2026-08-24 00:35
kind: fable-iterate review
review_model: claude-fable-5
review_effort: low
requested_model: claude-fable-5
resolved_model: claude-fable-5
model_substitution: none
job_id: review-20260824T003502-64987
branch: fix/search-attachment-preview-esc
base: main (008ad2e)
reviewed_commit: efee0c16ed4482043c7d1b8ba0bc44a42e645519
verdict: SHIP
started_at: 2026-08-24T07:35:02Z
finished_at: 2026-08-24T07:36:48Z
checks: make test → TEST SUCCEEDED, 1687 tests, 1 skipped, 0 failures
total_cost_usd: 1.45887
num_turns: 12
duration_ms: 102770
---

# Review pass 1 — search attachment chips + Esc Quick Look

## Prompt

```
Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: When searching an email with a PDF and an image (Surgical Plan Images from Evan Koenig), it sometimes showed double images and hid the PDF. Esc also closed the thread instead of the image preview after clicking an attachment. Reproduce and fix both if they are bugs.
```

## Verbatim review

Review is complete. The tests build and pass. Here is the report.

## Findings

**No blocking defects.** The diff fixes both reported bugs and the new tests pass (18 tests, 0 failures, incl. the 8 new ones).

**Bug 1 — duplicate image chips, hidden PDF.** Root cause is correct. Parsed `AttachmentRow`s have `id == nil` before insert. `Identifiable` then gives every chip the same identity, so ForEach draws one file many times. The fix is sound on both sides:
- `displayIdentity` (`Sources/MishMail/Store/Database.swift:203`) keys on the row id, with a part-level fallback for nil ids.
- All three attachment ForEach sites now use it (`ThreadDetailView.swift:1164,2047,2072`). No other attachment ForEach remains on the old key (I checked all sites).
- The recovery path (`MailStore.swift:6405-6423`) now returns the SQLite rows. This is safe: `upsertPending` (`SyncEngine.swift:806-809`) deletes all rows for the message and re-inserts the parsed set inside the same write. So the persisted fetch cannot pull stale or extra rows, and `order(id)` keeps parse order.

**Bug 2 — Esc closed the thread, not the preview.** The fix is correct. The local key monitor sees the main window as `event.window` even when the panel is on screen, so the old `event.window is QLPreviewPanel` guard failed. The new visibility check (`ContentView.swift:915-921`) plus `panel.makeKey()` (`QuickLookController.swift:20`) routes Esc to the panel. The chip click change to `quickLookAttachment` (`ThreadDetailView.swift:2077`) matches the requested behavior.

### Low severity
1. **All mailbox keys go dead while a preview is visible but not key** (`ContentView.swift:915`). If the user clicks back to the main window while the panel stays on screen, the monitor passes every key through: Esc closes neither the panel nor the thread, and j/k/archive shortcuts do not run. `panel.makeKey()` makes this rare on open. This is a small UX gap, not a regression on the reported bug.
2. **Intentional behavior change:** chip click now opens Quick Look, not the private-temp-file "Open." The tooltip and CHANGELOG document it. Confirm this is the wanted default; "Open with default app" is no longer one click away from the chip label.

## Open questions
- Should Esc close the reading pane when the panel lost key focus but is still visible (finding 1)? A follow-up could close the panel on Esc in that state.

## Suggested fixes (optional, not applied)
- In the monitor, when `previewPanelVisible` is true and the event is Esc on the main window, call `QLPreviewPanel.shared().close()` and swallow the event. This removes the dead-key state.

## Verdict
**SHIP.** Both fixes are correct, scoped, and tested. The two low-severity notes are follow-up material, not blockers.
