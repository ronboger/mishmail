date: 2026-08-11 12:14
kind: review
target: fix/contact-name-prefer-from vs main
verdict: SHIP
model: claude-fable-5
effort: low
requested_model: claude-fable-5
resolved_model: claude-fable-5
job_id: review-20260811T121445-90792
reviewed_commit: dca0e73ece3e79044b4bb4d1b7b05cddf1b1b3b0
started_at: 2026-08-11T19:14:45Z
finished_at: 2026-08-11T19:16:14Z
invoked_from: /Users/ronboger/mishmail-wt-contact-name
git_branch: fix/contact-name-prefer-from

## Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Fix contact autocomplete showing typos like 'jJoshua Yang'. ContactMiner: prefer From over To/Cc, reject glued 1-2 char typo prefixes (fold-safe), longer name fallback. Pass 2 after addressing Unicode fold count + same-name From promotion test.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.
```

## Review (verbatim)

```
id:	review-20260811T121445-90792
status:	completed
kind:	review
model:	claude-fable-5
cwd:	/Users/ronboger/mishmail-wt-contact-name
exit:	0
log:	/Users/ronboger/.local/share/jacq-claude-data/jobs/review-20260811T121445-90792/output.log
---
Permission deny rule "MultiEdit" matches no known tool — check for typos.
## Review: `fix/contact-name-prefer-from` vs `main`

Ran `xcodebuild test -only-testing:MishMailTests/ContactMinerTests`: 21 tests, 0 failures.

The diff is confined to `ContactMiner.swift` and its tests. The only other `WeightMap` consumer is the in-memory `contactWeights` in `MailStore.swift:1930`, rebuilt from SQLite — the tuple shape change is not persisted anywhere, so no migration concern.

### Findings

**Low — sticky From-sourced typo.** `preferredName` (ContactMiner.swift:55) gives From-tier names absolute priority, so if a contact's *own* From header carries a glued typo (or a scraped/misconfigured client name), it can never be displaced by a correct To/Cc name — only by another From sighting. That's the documented design trade-off and the right default, but worth knowing: a single bad From beats any number of good To/Cc names.

**Low — `isLikelyTypoPrefix` with empty `shorter` returns true.** `isLikelyTypoPrefix(longer: "ab", shorter: "")` → true (`hasSuffix("")` is always true). Unreachable through `preferredName` because empty current/candidate are handled first, but the function is `static` and tested directly; a `!sFold.isEmpty` guard would harden it. No runtime impact today.

**Low — whitespace-only trim asymmetry.** `isLikelyTypoPrefix` trims and folds its inputs, but the same-name check in `preferredName` uses `caseInsensitiveCompare` on untrimmed strings. If `MessageParser.displayName` can ever return names differing only in surrounding whitespace, they'd be treated as different names and fall through to the length rule (harmless outcome — longer wins). Cosmetic.

**Info — Unicode fold handling is correct.** Counting `extra` and taking `dropLast(sFold.count)` both operate on the same folded strings, so the earlier desync (e.g. `İ` → two scalars) is fixed as claimed. `hasSuffix` uses canonical grapheme equivalence on those same strings, so the length arithmetic stays consistent.

**Info — test coverage is good.** Both merge orders (typo-then-From, From-then-typo), same-tier typo rejection in both orders, title prefix "Dr ", nickname non-suffix, same-name From promotion with case change, and direct unit tests of both helpers. One untested edge: two-word glued typo like `"j Joshua Yang"` (prefix contains a space, extra = 2) — correctly falls through to longer-wins, meaning the typo would win among To-only names. If that pattern shows up in real data it would need a separate rule, but it's outside the stated task.

### Open questions
- None blocking. If Vas-style typos ever appear *in From headers* (auto-BCC tools rewriting headers), the From-tier lock would preserve them; watch for that in the wild.

### Suggested fixes (optional, not applied)
- Add `guard !sFold.isEmpty else { return false }` in `isLikelyTypoPrefix`.

## SHIP
```
