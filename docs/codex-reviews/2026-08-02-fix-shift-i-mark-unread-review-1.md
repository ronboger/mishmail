---
date: 2026-08-02 01:00
kind: review
target: branch fix/shift-i-mark-unread vs main
verdict: NOT READY
model: claude-opus-5
requested_model: opus
effort: low
job_id: review-20260802T005957-43087
reviewed_commit: 0d5f52364b521751d1509266ac4ebdc631eab6d7
invoked_from: /Users/ronboger/mishmail/.worktrees/shift-i-mark-unread
git_branch: fix/shift-i-mark-unread
focus: Shift+I marks unread when selection is already read; review correctness, regressions, tests
---

# Review prompt

Review the complete diff against the requested task. Task: if a thread is read, pressing Shift+I should mark it unread (Shift+I already marks unread→read; when fully read, flip to unread). Shift+U remains always mark-unread. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

# Verbatim review

id:	review-20260802T005957-43087
status:	completed
kind:	review
model:	claude-opus-5
cwd:	/Users/ronboger/mishmail/.worktrees/shift-i-mark-unread
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260802T005957-43087/output.log
---
## Review: Shift+I state-aware mark read/unread (`fix/shift-i-mark-unread` vs `main`)

### Findings by severity

**HIGH — Key auto-repeat turns Shift+I into a read/unread oscillator**
`Sources/MishMail/UI/ContentView.swift:1123-1130`. The chord branch returns before the `browseKeyIsRepeat = event.isARepeat` line and never inspects `event.isARepeat`. Previously this was harmless: repeated Shift+I was idempotent (`setRead(read: true)` over and over). Now each repeat re-reads `anyUnread` from the freshly mutated state, so a held Shift+I flips read → unread → read → unread at the OS repeat rate (~25–30 Hz after the initial delay).

Consequences, all real:
- A stream of `client.modifyThread` calls per keypress-hold (`MailStore.swift:4527-4530`) — Gmail API quota burn and racing add/remove `UNREAD` mutations whose final server state depends on completion order, not on the last keystroke.
- Visible unread-badge flicker; final state is effectively nondeterministic on a long hold.
- Same hazard on a large multi-select: N threads × M repeats.

Note ↑/↓ and the browse keys deliberately track `isARepeat` for coalescing; this chord has no such protection and now needs it because it became stateful.

*Suggested fix:* `if event.isARepeat { return nil }` inside the chord branch (drop repeats entirely — a mark-read chord has no meaningful hold semantics), or at minimum debounce Shift+I's state read.

**MEDIUM — `setReadSelected(read:)` is now dead code**
`Sources/MishMail/App/MailStore.swift:4533-4538`. Zero call sites remain (`ContentView.swift:1128` is the only caller of the chord path, and it uses `applyGmailMarkReadChord`). It survives as an untested, unreferenced public entry point that bypasses the new state-aware logic — a trap for the next caller who reaches for the obvious-sounding name.

*Suggested fix:* delete it, or mark it `private`/`@available(*, deprecated)`.

**MEDIUM — `markAsRead(key:shiftOnly:)` is now tested-only**
`GmailMarkReadKeys.swift:47-56`. It has no production callers; it's a shim over `chord`. `GmailMarkReadKeysTests.swift:5-33` asserts on it in every case, so roughly half the test additions exercise a function that ships only to satisfy those assertions. The `chord(...)` assertions added alongside already cover the same parsing. The doc comment ("Kept for simple chord tests") is honest about this but it's still production surface kept alive by tests.

*Suggested fix:* drop `markAsRead` and the assertions on it; the `chord` assertions are strictly stronger.

**LOW — No coverage for the target-selection and empty-guard logic**
The new decision logic splits across two places: the pure `desiredRead` (well covered) and `applyGmailMarkReadChord` / `gmailMarkReadTargets` (`MailStore.swift:4540-4558`, zero coverage). Untested behaviors that matter:
- checked-set precedence over `selectedThread`,
- `guard !targets.isEmpty` (new — the old code silently no-op'd; behaviorally equivalent, but now load-bearing since `anyUnread` over an empty set would be `false` and Shift+I would mean "mark unread" on nothing),
- mixed read/unread multi-select → all read.

This is consistent with the repo's pure-helper testing style (no test file instantiates `MailStore`), so it's a structural gap rather than an oversight. The logic could be lifted into `GmailMarkReadKeys` as a pure `func targets(checked:selected:)`-shaped helper if you want it covered.

**INFO — Shift+I on the open reading pane does not fight mark-read-on-open**
Checked because it's the obvious regression candidate: `ThreadDetailView.swift:453` uses `.task(id: thread.id)`, so the 1s-dwell auto-read task doesn't re-fire when `isUnread` changes. Marking the currently-open thread unread sticks. No bug. Same as existing Shift+U behavior.

**INFO — Shift+I now duplicates `toggleReadChecked`**
`MailStore.swift:4560-4568` is now functionally identical to `applyGmailMarkReadChord(.shiftI)` for the checked-set case. Not a defect, but the two will drift; `toggleReadChecked` could delegate.

### Open questions

1. Should a held Shift+I be dropped entirely, or coalesce to a single decision made on the first keydown? (Affects the HIGH fix shape.)
2. Gmail's actual Shift+I is idempotent — this intentionally diverges. Is the divergence documented anywhere a user would find it beyond the shortcuts sheet? (`ShortcutsHelpView.swift:20` and README are updated; good.)
3. On a mixed selection, is "first press → all read, second press → all unread" the intended feel, or should Shift+I stay idempotent whenever *any* target is unread and only flip on a fully-read set? Current code does the former.

### Verdict

**NOT READY** — the auto-repeat oscillation (HIGH) is a genuine regression introduced by making the chord stateful, and it produces racing remote mutations, not just cosmetic flicker. It's a one-line guard in `ContentView.swift:1123`. The dead `setReadSelected` and the tested-only `markAsRead` shim are worth cleaning in the same pass.

The core logic itself is correct and well-factored: `desiredRead` is a clean pure function with good direct coverage, `gmailMarkReadTargets` correctly preserves the checked-set-over-focus precedence, and the docs/CHANGELOG/help-sheet updates are complete and accurate.

*(Read-only mode: no files modified, no build or test run.)*
