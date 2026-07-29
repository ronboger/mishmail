---
date: 2026-07-29 14:58
kind: review
target: branch fix/post-send-archive-speed vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260729T145836-78567
reviewed_commit: 4f2ee15e68bb09f52b9d666dd3e83914e2a95f74
invoked_from: /Users/ronboger/mishmail/.worktrees/post-send-archive-speed
git_branch: fix/post-send-archive-speed
git_head: 4f2ee15e68bb09f52b9d666dd3e83914e2a95f74
focus: post-Send e archive speed
---

# Prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: when i press e after sending a reply on a thread, it's really slow to actually archive. fix

# Verbatim review

id:	review-20260729T145836-78567
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/post-send-archive-speed
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260729T145836-78567/output.log
---
# Review: `fix/post-send-archive-speed` vs `main`

## Findings by severity

### MEDIUM — In-flight autosave can orphan a Gmail draft after Send
`ComposeView.swift:1894` — `cancelInFlightPersist()` cancels the persistTask wrapper, but a `performPersist` already past its `Task.isCancelled` check (createDraft on the wire via URLSession) completes anyway: it creates draft **Y** replacing **X**. Send's snapshot `replacingDraft: liveDraft` (`ComposeView.swift:1881`) = X, so `queueSend` deletes X (double-delete is harmless) but **Y is never deleted** → a user-visible duplicate draft in Gmail Drafts containing already-sent content. The comment at `ComposeView.swift:1915-1921` acknowledges this, but "until the next sync" understates it — sync only *reveals* the orphan; nothing cleans it up. This is the trade-off buying instant Send; it's documented but real.

### LOW — Blur side effect runs before all guards
`ContentView.swift:~967` — `event.window?.makeFirstResponder(nil)` fires for *every* key event while `composeFinishing` (including modifier chords), before the `mods.isEmpty`/palette guards. Window is brief and `beginFinish` closes palettes, so cosmetic only.

### LOW — Abort path leaves autosave cancelled
`send()` cancels autosave/persist *before* `buildPendingSend()` validates; on empty-To abort, unsaved content isn't re-persisted until the next keystroke re-arms autosave. Save-and-close persists explicitly, so worst case is a stale silent autosave.

## Correctness verified
- Double-send still prevented: `beginFinish()` claims synchronously before any work.
- `focusBody()` `!didFinish` guard (`ComposeView.swift:240-248`) fixes the delayed re-focus steal, and the abort path is unaffected — `abortFinish()` resets `didFinish = false` *before* calling `focusBody()`, so the re-focus still fires.
- Discard correctly still awaits persist idle (`discardAndClose`, `ComposeView.swift:495-505`) so it deletes the real server draft id.
- `textFocusBlocksMailboxKeys` only bypasses TextFocus when finishing; expanded typing still blocks j/k.

## Test coverage
`ComposeKeyOwnershipTests.swift` covers the new gate both ways plus the expanded-typing invariant. No test for send-doesn't-await-persist (async UI, hard to unit-test) — acceptable.

## Open questions
1. Is the orphaned-draft trade-off acceptable, or should `queueSend` do a post-send cleanup sweep (e.g. delete drafts on the sent thread)?

## Suggested fixes (not applied — read-only)
- For the MEDIUM: after a successful send, sweep Drafts for the sent thread's `threadId` and delete matches, or have `performPersist` check `didFinish` after createDraft returns and delete its own just-created draft.
- For the ContentView blur: move the `makeFirstResponder(nil)` after the `mods.isEmpty` check.

## Verdict: **SHIP**
The fix correctly makes post-Send `e` instant (both the persist wait and the focus-gate swallow are addressed), with the orphan-draft risk as a known, documented trade-off.
