date: 2026-08-11 12:11
kind: review
target: fix/contact-name-prefer-from vs main
verdict: SHIP
model: claude-fable-5
effort: low
requested_model: claude-fable-5
resolved_model: claude-fable-5
job_id: review-20260811T121143-88781
reviewed_commit: ab045a2370590d73d61ae0ee8e29dfbb28108bce
started_at: 2026-08-11T19:11:43Z
finished_at: 2026-08-11T19:13:40Z
invoked_from: /Users/ronboger/mishmail-wt-contact-name
git_branch: fix/contact-name-prefer-from

## Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Fix contact autocomplete showing typos like 'jJoshua Yang' instead of 'Joshua Yang'. Chose no-scope smarter ContactMiner merge: prefer From-header names over To/Cc, reject 1-2 char glued typo prefixes, then longer name. No Google Contacts API.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.
```

## Review (verbatim)

```
id:	review-20260811T121143-88781
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail-wt-contact-name
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260811T121143-88781/output.log
---
Permission deny rule "MultiEdit" matches no known tool — check for typos.
All 20 ContactMinerTests pass (`xcodebuild test -scheme MishMailTests -only-testing:…/ContactMinerTests`: Executed 20 tests, 0 failures). The diff is small (ab045a2, 2 files) and matches the stated task.

## Findings

**No high-severity issues.** The core logic is correct: From-tier beats To/Cc, glued-prefix rejection only applies within a tier, and the tie-break falls back to longer-name. I checked the only external consumer — `MailStore.swift:1930` `contactWeights` — and the tuple is in-memory only; on launch `contactWeights.isEmpty` forces a full rebuild (MailStore.swift:2013), so the added `nameFromSelf` field replays cleanly over existing data with no persisted-format migration needed.

**Low — Unicode count mismatch in `isLikelyTypoPrefix` (ContactMiner.swift:41-52).** `extra` is computed on the original strings but the suffix/prefix check runs on `lowercased()` copies, and lowercasing can change character count (e.g. `İ` → `i̇`, ligatures). A name like `"İİAlice"` vs `"Alice"` computes `extra = 2` from originals but drops a different-length prefix from the folded string. Worst case is a misclassification in one direction or the other for rare non-ASCII names — cosmetic, not a crash. Fix if you care: compute both counts from the folded strings.

**Low — sticky From lock-in.** Once `nameFromSelf` is true, no To/Cc name can ever replace it, even a much better one (From `"J"` beats To `"Joshua Yang"` forever — `"J"` passes `isUsableDisplayName` since single letters aren't junk-filtered, per the existing `"F <friend@x.com>"` test). This is the design you chose (self-identification wins) and full rebuilds re-derive it, so it self-corrects if the person ever sends with a fuller name. Noting it as accepted behavior, not a bug.

**Info — typo rule also applies within the From tier.** A sender whose own client emits `"jJoshua Yang"` in From is protected only if a clean From is also seen (same tier → prefix rejection handles it). Correct.

**Test coverage** is good: both orderings of typo-vs-From, To-only typo both orderings, title prefix (`"Dr "`), same-tier longer-name, and direct unit tests of both helpers. One untested path: the case-insensitive same-name branch (ContactMiner.swift:66-69 — To `"joshua yang"` then From `"Joshua Yang"` should keep From casing and set `fromSelf`). Logic reads correct; a one-case test would pin it.

## Open questions

- None blocking. The Unicode edge is the only thing I'd consider fixing, and only if non-ASCII display names matter to you.

## Suggested fixes (not applied — read-only)

- ContactMiner.swift:41-52: derive `extra` from `lFold.count - sFold.count` after folding, and guard `lFold.count > sFold.count`.
- Optional test: same-name-different-case merge promoting to From-sourced.

**SHIP** — correct, scoped, verified passing, no regressions found in the sole consumer.
```
