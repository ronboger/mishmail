---
date: 2026-07-30 16:38
kind: review
target: feat/compose-empty-pane-autoexpand vs main
verdict: SHIP (with M1 addressed in follow-up)
model: claude-fable-5
effort: low
job_id: review-20260730T163550-24490
reviewed_commit: 21d16ff284c32cbe9acaca569555fe750dc76ace
invoked_from: /Users/ronboger/mishmail-compose-pane-fill
git_branch: feat/compose-empty-pane-autoexpand
---

# Fable Review — empty-pane compose autoexpand (pass 1)

id:	review-20260730T163550-24490
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail-compose-pane-fill
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260730T163550-24490/output.log
---
## Review: Empty-pane compose autoexpand (`feat/compose-empty-pane-autoexpand` vs `main`)

### Findings (by severity)

**M1 — `readingPaneIsEmpty` can be true in `.list` layout mode, where no reading pane exists; safety depends on `ReadingPaneFrameKey` reliably resetting to `.zero`**

`ContentView.swift:507-509` computes empty as `!effectivePaneHidden && store.openedThreadId == nil`. In the reading-pane style with a **narrow window** (`width < 1080`) and no selection, `MailLayout.mode` returns `.list` (`MailLayout.swift:40-41`) — the detail column is not mounted at all, yet `effectivePaneHidden == false` (user hasn't hidden the pane), so `readingPaneIsEmpty == true`. The only thing preventing pane-fill from firing over the list is `readingPaneFrame` being `.zero`, which requires `onPreferenceChange(ReadingPaneFrameKey)` (`ContentView.swift:101-105`) to deliver the default value when `DetailPaneHost` unmounts. SwiftUI's preference-change-on-removal has historically been flaky, and the transition path (resize wide→narrow, or `compactDetail`→`list` after closing a thread) can leave a stale non-zero frame for at least a frame — producing a full-height compose card pinned to a phantom pane overlapping the list.

Suggested fix: gate on layout mode, which is already in scope in `composeChrome` — pane fill is only meaningful in `.threePane` (in `.compactDetail` the pane implies `openedThreadId != nil`, so it can never be empty):
```swift
private var readingPaneIsEmpty: Bool {
    layoutMode == .threePane && store.openedThreadId == nil
}
```
This also makes decision 6 (full-window never pane-fills) hold structurally rather than via `effectivePaneHidden` alone. Note: no test can cover this today because the emptiness predicate lives in ContentView — see T1.

**L1 — 12pt top gutter is implicit, not applied**

`effectivePaneCardHeight` subtracts `paneTopPadding` (`ComposePlacement.swift:99-102`) but the pane `EdgeInsets` has `top: 0` (`ContentView.swift:557-560`). The top gutter only materializes if `composeHostFrame.maxY == readingPaneFrame.maxY` (card is bottom-anchored). Inline makes the same assumption so this is consistent, but if the host ever grows a bottom inset the pane card's top gutter silently changes while bottom stays 12. A comment on `paneTopPadding` noting this coupling would help; not a blocker.

**L2 — `.pane` passthrough in `resolvedPresentation` legitimizes a state that "can never exist"**

`ComposePlacement.swift:68-69`: `case .split, .pane: return preferred`. By design the request never stores `.pane`, so this arm is unreachable — but if a future call site ever persists a resolved presentation back to the request (the codebase already has `demoteInlineComposeIfPaneTooShort` / `promoteInlineComposeIfNeeded` mutating stored presentation), a stored `.pane` would stick even after the pane fills with a conversation. Consider `assertionFailure` for `.pane` here, or at minimum extend the doc comment on the enum case ("must never be stored on a ComposeRequest").

**L3 — dead parameters in `reservesInlineComposeSpace`**

`ContentView.swift:588-593` now passes `readingPaneEmpty`/`paneWidth`, but that call only compares against `.inline`, and `.inline` preferred can never resolve to `.pane`. Harmless (arguably uniform), but it implies the flags matter there when they can't. Fine to keep; a one-line comment would prevent a future reader from "fixing" it.

**L4 — 320pt min width yields a 296pt card**

`minPaneFillWidth = 320` minus 2×12 gutters = 296pt of card — well below `preferredFloatingWidth` (620) and below `minSplitComposeWidth − gutters` (336), which the codebase treats as the floor for a usable From/To/Subject. In practice a threePane detail column has `min: 420` list + sidebar, so real pane widths will be larger — but if you want the constant to mean what its comment says ("keeps From/To/Subject usable"), 360 would match `minSplitComposeWidth` semantics. Judgment call.

### Test coverage

Good: the new tests cover promotion, occupied-pane, reply-safety (including the empty-flag-wrongly-set case — nice), split, thresholds (inclusive boundary), card height, chrome pinning, and preferred() stability. Gaps:

- **T1**: The M1 scenario is untestable because the emptiness predicate is view-layer logic. Moving it into `ComposePlacement` (e.g. `static func readingPaneEmpty(layoutMode:openedThreadId:paneHidden:) -> Bool`) would let you test the `.list`/`.threadFocus`/full-window cases the way everything else in this file is tested — and this repo's whole pattern is "placement rules pure and tested."
- **T2**: No test for `effectivePaneCardHeight(paneHeight: 0)` → 500 fallback (minor; that branch is unreachable when `.pane` was chosen, since `shouldPaneFill` requires ≥360).
- **T3**: No test that minimized pane-fill docks as floating (also view-layer; would fall out of T1-style extraction if `chromePresentation` logic ever moves down).

### On the design decisions

1. **Derive `.pane` at layout time, never store it** — sound, and the better choice. Storing `.pane` would need invalidation on thread-open, layout change, and window resize; deriving gets all three free and matches the existing `resolvedPresentation` demotion pattern. It also keeps minimize/pop-out working unchanged (decision 7 falls out for free). Keep it — but see L2 for hardening.
2. **Empty = pane visible ∧ no open thread, not draft-only** — correct. A draft-only special case would make new compose (⌘N) behave differently from reopened drafts for no user-visible reason; "the column is idle" is the right trigger. The one refinement needed is the layout-mode gate (M1) — `effectivePaneHidden` is not quite the same as "a detail column is mounted."
3. **Replies stay `.inline`** — correct, and the belt-and-suspenders test for the wrongly-set flag is exactly right.
4. **Card chrome, not full-bleed** — agree. Full-bleed would erase the visual distinction between "reading a message" and "composing," and would make the minimize affordance feel wrong. Reusing `inlineSidePadding` via `paneSidePadding` keeps one gutter constant.
5/6/7 — all fall out of the derived approach; no concerns beyond M1.

### Open questions

1. Have you manually verified the narrow-window (`< 1080pt`) resize path with a floating compose open — wide-empty (pane fill) → narrow (list mode)? That's the M1 exposure.
2. When pane fill is active and the user starts j/k browsing, `DetailOpenPolicy.opensImmediately` opens a thread → card shrinks to floating mid-browse. Intended per decision 5, but worth confirming the spring animation doesn't feel like the compose is "fleeing" during rapid keyboard nav.
3. Full-window style + floating compose on the list: confirmed never pane-fills via `effectivePaneHidden` — but that's the only guard; T1's extraction would pin it in a test.

### Verdict

**SHIP** — with M1 addressed (a one-line `layoutMode == .threePane` gate) or at minimum manually verified on the narrow-window resize path before merge. Everything else is polish. The core mechanism is clean, well-commented, and follows the codebase's pure-placement-rules pattern; test coverage of the pure layer is genuinely good.
