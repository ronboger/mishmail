---
date: 2026-07-29 00:19
kind: fable-review
reviewer: Fable (jacq-claude, claude-fable-5)
target: branch fix/compose-narrow-clip vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260729T001659-11971
reviewed_commit: 0d8be41ed80d7a86626c25df59b2b45e4ba3cae7
invoked_from: /Users/ronboger/mishmail/.worktrees/compose-narrow-clip
git_branch: fix/compose-narrow-clip
focus: compose card left-clip under list on narrow windows when replying
---

# Fable Review: fix/compose-narrow-clip

Tests couldn't be executed (Bash approval denied in this read-only session), so this is a static review of `git diff main...HEAD` (commit 0d8be41).

## Findings

**No HIGH or MEDIUM issues.** The core fix is sound: `inlineMetrics` dropping the `max(minWidth, …)` floor (ComposePlacement.swift:135) removes the exact mechanism that pushed the card left under the list (over-wide child + `bottomTrailing` overlay + `clipShape`), and the measured-pane branch of `cardChrome` (ComposePlacement.swift:195–201) pins the card inside the pane with symmetric 12pt gutters. I verified the geometry: when the pane is flush with the host's trailing edge (the actual layout — detail column ends at the window edge), `leading + width + trailing == hostW` exactly, so the trailing-anchored overlay and the leading-inset model agree.

### LOW

1. **`minUsableCardWidth` is dead code** — ComposePlacement.swift:147 declares it, but it's only referenced in a doc comment (line 234). Nothing enforces or even consults it. Either use it (see #2) or delete it; as-is it implies a floor that doesn't exist.

2. **No demotion for pathologically narrow panes** — `resolvedPresentation` demotes inline→floating only on short pane *height* (ContentView.swift:104). With the minWidth floor removed, a pane narrower than ~300pt now yields an inline card of near-zero width (e.g. 100pt pane → 76pt card) instead of clipping. That's the intended trade-off per the plan, but a width-based demotion using `minUsableCardWidth` would be strictly better than an unusable sliver. Not a regression vs. main (main clipped instead), so LOW.

3. **Tests model leading-anchoring; the overlay is trailing-anchored** — e.g. `testInlineCardFitsHostWhenLeadingLarge` and `testSymmetricInlineSideInsets` compute `cardMinX = host.minX + chrome.leading` (ComposePlacementTests.swift:158, 199), but the real overlay is `.overlay(alignment: .bottomTrailing)` (ContentView.swift:264), where actual `cardMinX = host.maxX − trailingPad − width`. These coincide only because `leading + width + trailing == hostW` in the measured-pane branch. In the fallback branch (pane unmeasured, wide host) the sum is < hostW and the card actually renders further right than `chrome.leading` — harmless (still on-screen), but the tests would keep passing even if a future change broke the invariant that makes the two models agree. A test asserting `chrome.leading + chrome.width + chrome.trailingPadding == hostW` for the measured inline case would pin the actual contract.

4. **Split-branch gutter asymmetry** — ComposePlacement.swift:214–228: the clamp is `min(width, hostW − pad)` (one gutter) while the applied `EdgeInsets` have `leading: 0, trailing: splitPad` (ContentView.swift:527–529). On a very narrow host the split card can touch the left window edge with zero left gutter. Also the `320` floor doesn't match `minSplitComposeWidth (360) − 2·splitPadding = 336` — pre-existing magic number carried over, but now it lives next to named constants that disagree with it. Cosmetic.

5. **Fallback-leading on mid-width hosts gives a sliver, transiently** — with pane unmeasured and host ≈900pt in `.threePane`, leading = 800 → width clamps to 88pt (ComposePlacement.swift:186–192). Only lasts until `ReadingPaneFrameKey` fires (one frame), and it's the correct on-screen-over-clipping trade, so acceptable.

### Verified-correct spot checks

- `fallbackLeadingInset` 240+560 matches the actual `navigationSplitViewColumnWidth` ideals (ContentView.swift:415, 432). Test updated accordingly.
- Minimized path: `chromePresentation = .floating` (ContentView.swift:491) → leading 0, 300pt clamped to host, floating paddings — matches prior behavior on normal hosts, fixes overflow on tiny ones.
- Unmeasured first frame keeps the historical 620 (no zero-width flash) — covered by `testUnmeasuredHostKeepsPreferredFloatingWidth`.
- `if inline || chrome.leading > 0` at ContentView.swift:507 — the second disjunct is unreachable (leading > 0 only in the inline branch), redundant but harmless.
- `.frame(alignment: .topLeading)` addresses the mid-glyph center-clip; `max(0, …)` guards prevent negative-width crashes throughout.

## Open questions

1. Should a too-narrow pane demote inline→floating (like too-short does), rather than rendering a <280pt card? (Finding #2.)
2. Was `minUsableCardWidth` meant to be wired up somewhere, or is it intentionally documentation-only?

## Suggested fixes (not applied)

- Delete `minUsableCardWidth` or use it in a width-based demotion in `resolvedPresentation`/`demoteInlineComposeIfPaneTooShort`.
- Add a test: measured inline chrome satisfies `leading + width + trailingPadding == host.width` (locks the trailing-anchor equivalence).
- Split branch: clamp to `hostW − pad * 2` or add a leading pad for symmetry; replace `320` with `minSplitComposeWidth − splitPadding * 2`.

## Verdict

**SHIP** — the fix is correct for the reported bug, regressions in floating/split/minimized/first-frame paths are guarded, and new tests cover the key scenarios. The LOWs are polish, not blockers. (Caveat: `swift test` was not run in this session; run `swift test --filter ComposePlacementTests` before merging.)
