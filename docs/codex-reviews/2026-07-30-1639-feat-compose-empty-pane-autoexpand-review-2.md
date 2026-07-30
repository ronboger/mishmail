---
date: 2026-07-30 16:41
kind: review
target: feat/compose-empty-pane-autoexpand vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260730T163954-27550
reviewed_commit: 9df620deb227aa6752a8b2897814f35dc6477254
invoked_from: /Users/ronboger/mishmail-compose-pane-fill
git_branch: feat/compose-empty-pane-autoexpand
---

# Fable Review — empty-pane compose autoexpand (pass 2)

id:	review-20260730T163954-27550
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail-compose-pane-fill
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260730T163954-27550/output.log
---
The M1 concern is resolved: the empty-state placeholder lives inside `DetailPaneHost` (ContentView.swift:691-695), which publishes `ReadingPaneFrameKey` from its own background (ContentView.swift:711-717) regardless of whether a thread is open — so pane width/height are live in the empty state, while the emptiness *predicate* no longer touches frames at all. Here's the review:

---

# Re-review: feat/compose-empty-pane-autoexpand (9df620d vs main)

## M1 verification — FIXED

`ComposePlacement.readingPaneIsEmpty` (ComposePlacement.swift:97-103) is now pure state: `layoutMode == .threePane && openedThreadId == nil`. I traced the supporting invariants:

- `MailLayout.mode` (MailLayout.swift:39-43) returns `.list` whenever `readingPaneHidden` — so `.threePane` cannot co-occur with a hidden pane; the predicate can't claim a nonexistent column.
- `.compactDetail` only arises with an open thread, `.list`/`.threadFocus` are excluded — matches the doc comment and `testReadingPaneIsEmptyOnlyInThreePaneWithoutOpenThread`.
- The `.threePane` branch (ContentView.swift:449-458) always mounts `detailPane`, and the frame preference is emitted even in the "Select a conversation" state, so `shouldPaneFill`'s width/height inputs are fresh — the stale-PreferenceKey failure mode from pass 1 is gone for the *predicate*, and the remaining frame use is only a size gate that fails safe (stale/zero frame → floating, never a wrongly-promoted pane).
- `.pane` is never stored: `ComposeRequest.presentation` writes are only `.floating`/`.split`/`preferred()` (MailStore.swift:1079-1220), `preferred()` can't return `.pane`, and the defensive `.pane → .floating` demotion is tested (`testStoredPaneDemotesWhenPaneNoLongerEmpty`).

## Findings

**L1 — Top gutter depends on host/pane bottom alignment (documented, not enforced).** `effectivePaneCardHeight` subtracts both paddings but only bottom padding is applied as an inset (ContentView.swift:560-563); the top gutter equals `paneTopPadding` only if the overlay host's bottom coincides with the reading pane's bottom (the comment at ComposePlacement.swift:112-117 admits this). Today they do align, but a future bottom bar/status strip in the host would silently shift the gutter. No test pins it. Cosmetic-only risk — the card can't overflow, just mis-gutter.

**L2 — Duplicate promotion logic in `.pane`/`.floating` cases.** The two `guard readingPaneEmpty, shouldPaneFill(...)` bodies in `resolvedPresentation` (ComposePlacement.swift:69-76, 82-87) are identical; a threshold change must be made twice. `case .pane, .floating:` would collapse them. Style only.

**L3 — One-frame lag on `layoutMode`.** `layoutMode` is `@State` synced via `onAppear`/`onChange` (ContentView.swift:91-92), so on a mode flip (e.g. window resize below 1080pt) the resolution can use the old mode for one frame. Worst case: pane fill renders one frame after the three-pane layout is gone, then demotes to floating with the spring animation. Transient and self-correcting; `reduceMotion` transaction gate (ContentView.swift:108) still applies. Pre-existing pattern for inline; not a regression.

**Info — pure-draft click promotes to pane fill.** Clicking a draft in three-pane skips the reading pane (`openedThreadId` stays nil) and opens floating compose → immediately promotes to pane fill. That reads as intended ("empty pane, compose is the primary surface") but it's a behavior change for draft-open specifically; worth a conscious sign-off.

## Test coverage

Good: promotion, occupation, inline/split immunity, size thresholds (inclusive boundary both axes), `minPaneFillWidth == minSplitComposeWidth`, stored-`.pane` demotion, layout-mode matrix, chrome pinning geometry, and `preferred()` non-involvement. Gaps are minor: no test for the minimized-in-empty-pane path (chromePresentation → `.floating`, height 40 — ContentView-level, hard to unit test) and nothing pinning L1's gutter assumption. I did not run the suite (read-only session — build artifacts); recommend `swift test` before merge.

## Open questions

1. Is pane-fill-on-draft-click (Info above) the intended UX?
2. Should `paneTopPadding` get a geometry assertion/test if a host bottom bar ever lands (L1)?

## Suggested fixes (not applied)

- L2: merge to `case .pane, .floating:` in `resolvedPresentation`.
- L1: add a comment-anchored test or compute the top inset explicitly instead of via height subtraction.

## Verdict

**SHIP** — M1 is fixed cleanly (pure predicate, fail-safe size gate, non-persisted `.pane` with tested defensive demotion). Remaining findings are low/cosmetic. Run `swift test` to confirm the 12 new assertions pass before merging.
