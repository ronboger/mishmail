---
date: 2026-07-30
kind: fable-review
target: fix/mailstore-return-and-install vs main
model: claude-fable-5
effort: low
pass: 1
reviewed_commit: 28f8765048a869bbac9717762fa6747c11f9b27d
verdict: SHIP
note: jacq-claude CLAUDE_CONFIG_DIR auth issue; review via direct claude CLI with same model/effort/flags
---

# Fable Review Pass 1 — mailstore return / install

The diff is a single-line fix (plus comment). Verified in context:

**Findings**

- **None (blocking).** The closure `pool.read { db -> [String] in ... }` became multi-statement when `let now = Date()` was added (commit 2c94300's snooze filter), which silenced Swift's implicit return and made the closure fail to compile (`missing return in closure expected to return '[String]'`). The explicit `return try` restores the declared `[String]` result. Query semantics are unchanged — same filters, same projection.
- **Low / informational:** the `try? ... ?? []` wrapper means a query error still silently yields an empty set — pre-existing behavior, not touched by this diff.
- **Test coverage:** no new test, but this was a compile error, not a logic bug — the compiler itself is the regression guard. The snooze-filter logic it unblocks was covered by the prior commit's tests per the task description.

The comment explaining *why* the explicit return exists is a nice touch against future "cleanup" regressions.

**SHIP**
