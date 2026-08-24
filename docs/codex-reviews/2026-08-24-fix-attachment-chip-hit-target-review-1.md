---
date: 2026-08-24 16:44
kind: self-review (user asked not to use Fable/Claude)
review_model: grok-4.6
review_effort: low
requested_model: self
resolved_model: grok-4.6
model_substitution: none (Fable/Claude skipped by request)
job_id: none
branch: fix/attachment-chip-hit-target
base: main (11eb998)
reviewed_commit: 07c55d5
verdict: SHIP
started_at: 2026-08-24T23:44:00Z
finished_at: 2026-08-24T23:45:00Z
checks: xcodebuild test MishMailTests → TEST SUCCEEDED, 1708 tests, 1 skipped, 0 failures; app Debug BUILD SUCCEEDED
---

# Review pass 1 — attachment chip full hit target

## Prompt

```
Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: when i click on an attachment, i should be able to click the whole thing, not just text.
```

## Verbatim review

Review is complete. The tests build and pass. Here is the report.

## Findings

**No blocking defects.** The screenshot bug is that `.buttonStyle(.plain)` hit-tested the filename glyphs, and padding/background sat on an inert outer `HStack`. The new `MessageAttachmentChip` uses three sibling buttons with spacing 0. Preview padding lives inside the Quick Look button. Each label uses `.contentShape(Rectangle())`. Eye and Save stay distinct trailing actions. Context menu still offers Quick Look / Open / Save As. "Download all" also got a `contentShape` so its chrome hits.

The view uses `MessageAttachmentChipLayout` values (unlike some older layout helpers that only document the contract). `chipMinHeight` is a min, not `maxHeight: .infinity`, so a horizontal `ScrollView` cannot stretch the chip.

### Low severity
1. **Tests lock the helper, not SwiftUI hit-testing.** Hostless unit tests cannot click a view. This matches `ComposeFooterLayout`. The live chip reads `previewHitInsets()`, `saveHitInsets()`, `regionSpacing`, and `chipMinHeight`, so a revert of the padding-inside-button structure would still compile if someone copied the old HStack back. A UI test would close that gap; none exists for this chip and `make ui-test` is CI-only.
2. **No pointing-hand cursor.** Collapsed message cards push `NSCursor.pointingHand`. The chip does not. Not requested; the hit target is the bug.

## Open questions
- None for this task. Compose attachment chips are remove-only and were not in the screenshot.

## Verdict
**SHIP.** The hit target now covers the chip chrome. Eye and Save still work. Tests and the app build passed.
