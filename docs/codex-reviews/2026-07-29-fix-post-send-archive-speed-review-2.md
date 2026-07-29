---
date: 2026-07-29 15:01
kind: review
target: branch fix/post-send-archive-speed vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260729T150121-82271
reviewed_commit: 43e07c17f4688337b330de543d5cbe98b62c7b23
invoked_from: /Users/ronboger/mishmail/.worktrees/post-send-archive-speed
git_branch: fix/post-send-archive-speed
git_head: 43e07c17f4688337b330de543d5cbe98b62c7b23
focus: re-review after pass-1 findings
---

# Prompt

Re-review after addressing pass-1 findings. Check late-draft delete on didFinish, blur after mailbox-key guards, abort autosave re-arm. Confirm post-Send e archive is fixed. Finish with SHIP or NOT READY.

# Verbatim review

id:	review-20260729T150121-82271
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail/.worktrees/post-send-archive-speed
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260729T150121-82271/output.log
---
## Re-review: post-Send instant archive (main...HEAD, commits `4f2ee15`, `43e07c1`)

### Pass-1 findings — all verified addressed

1. **Late-draft delete on didFinish** ✅ — `ComposeView.swift:435` early-returns before `createDraft` when `didFinish` is set, and `ComposeView.swift:458-461` deletes a draft that was already on the wire (`store.deleteUnderlyingDraft(saved, silent: true)` — signature confirmed at `MailStore.swift:5055`, with a matching `!didFinish` guard on the chained tail-save at `ComposeView.swift:469`). The demo-mode branch is also behind the early return, so no false "saved" notice.
2. **Blur after mailbox-key guards** ✅ — `ContentView.swift:980-985`: `makeFirstResponder(nil)` now runs only after all guards pass (`finishingCompose && textEditing`), so a normal expanded-compose keystroke can no longer be blurred. Policy is extracted to `ComposeKeyOwnership.textFocusBlocksMailboxKeys` (`ComposeKeyOwnership.swift:36`) with tests covering both directions (`ComposeKeyOwnershipTests.swift:42-56`).
3. **Abort autosave re-arm** ✅ — `abortFinish` (`ComposeView.swift:149`) re-arms `scheduleAutosave()` when `hasContent`, since `send()` now cancels the autosave task before packaging. Order is correct: `didFinish = false` first, so the re-armed chain and the `focusBody()` guard (`ComposeView.swift:249`) both behave.
4. **Post-Send `e` archive** ✅ confirmed fixed by two independent mechanisms: `send()` (`ComposeView.swift:1902-1912`) is now fully synchronous on the main actor — `beginFinish` → `cancelInFlightPersist` → `queueSend` → `close()` in one turn, no `awaitPersistIdle` — and the `focusBody` re-steal guard (`ComposeView.swift:249`) plus the mid-finish text-focus bypass close the lagging-AppKit-focus window. Double-send protection is preserved (`beginFinish` claims before any work; sync path has no suspension points, so no interleaving with `performPersist` reads of `didFinish`).

### New findings

**LOW-1 — Cancelling an in-flight persist can orphan a sent-content draft server-side.**
`cancelInFlightPersist` (`ComposeView.swift:1934-1938`) cancels `persistTask`. The comment says "a createDraft already on the wire may still complete (URLSession)" — but `GmailClient.createDraft` (`GmailClient.swift:474`) goes through `request(...)`, and Swift's async `URLSession` APIs *are* cancellation-responsive: the local await throws `CancellationError` while the POST may still land at Gmail. In that case `saved == nil`, the `didFinish` delete path at `ComposeView.swift:458` never runs, and sent content stays in Gmail Drafts until the next sync notices. Narrow window, cosmetic outcome — but the safer design is to *not* cancel `persistTask` (send doesn't await it anyway; the `didFinish` guards already neutralize its side effects) and only cancel `autosaveTask`. The wrapper's `guard !Task.isCancelled` in `enqueuePersist` (`ComposeView.swift:359`) would then be the only thing you lose, which is fine.

**LOW-2 — Cancelled persist marks `draftStatus = .failed` after unmount.** `ComposeView.swift:473-475`: the `saved == nil` branch (including cancellation) writes `.failed` to unmounted `@State`. Harmless (silent path, view gone), noting for completeness.

**LOW-3 — Double-delete of the old draft when a persist completes mid-send.** If an in-flight `saveDraft` completes after `send()` built `PendingSend(replacingDraft: liveDraft)`, `MailStore.saveDraft` deletes that old draft (`MailStore.swift:4948`) and the send pipeline will later try to delete it again via `PendingSend.replacingDraft`. Presumably a tolerated 404 — worth a quick confirmation that the send pipeline's draft delete swallows not-found errors.

### Open questions
- LOW-3: does the send pipeline's `replacingDraft` cleanup tolerate an already-deleted draft id?
- Tests weren't run in this pass (logic-only tests added compile-trivially against a pure enum; full suite/build not exercised in read-only mode).

### Suggested fixes (not applied — read-only)
- LOW-1: in `cancelInFlightPersist`, drop `persistTask?.cancel()` / `persistTask = nil` and keep only the autosave cancellation; let the `didFinish` guards at `ComposeView.swift:435/458` handle the tail. Also update the comment either way — as written it overstates URLSession's behavior under cancellation.

## Verdict: **SHIP**

All pass-1 findings are correctly addressed, the instant-archive fix is structurally sound (synchronous send path + focus-bypass + no-refocus guard), and the remaining items are LOW-severity races with cosmetic worst cases.
