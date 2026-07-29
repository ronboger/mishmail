---
date: 2026-07-29 14:52
kind: fable-review
target: feat/greeting-name-and-warmness vs main
verdict: SHIP
model: claude-fable-5
effort: low
job_id: review-20260729T145200-70016
reviewed_commit: f95f71f5fd31604e1d390cce564a1536d12d573e
invoked_from: /Users/ronboger/mishmail/.worktrees/greeting-name-and-warmness
git_branch: feat/greeting-name-and-warmness
---

# Review prompt

Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Fix greeting Tab autocomplete treating full email as person name (Hi John@ormoni.bio,) when contacts lack a real first name — root cause in contact mining storing bare From addresses as display names (case mismatch meant name==email never cleared). Also guess warmness of the previous email so empty-body default prefers Hey when casual vs Hi/Hello. User wants the contacts issue fixable.

# Review: greeting email-as-name fix + tone-aware openers (`main...f95f71f`)

Note: I could not run the test suite (Bash approval for `swift test` was denied), so this is a static review.

## Findings

### Medium

**M1 — `greetingTone` strips the original message's HTML on every render/keystroke.**
`ComposeView.swift:1540-1545` is a computed property calling `MessageParser.replyQuotableText` → `stripHTML` (`MessageParsing.swift:232-238`) on `original.bodyHTML`. `greetingSuggestion` (`ComposeView.swift:1550-1563`) is itself computed and evaluated from `greetingGhostText` (per body render) and again in `acceptGreetingSuggestion`. For a long HTML reply target this re-strips the full HTML on every keystroke while the ghost machinery is active. `original` is fixed for the compose session — the tone should be computed once (e.g. `lazy`/`@State` set in `onAppear`, or memoized on `original.id`). Functionally correct, but an avoidable per-keystroke cost in the hot typing path.

### Low

**L1 — `"ty!"` casual marker matches substrings.** `GreetingAutocomplete.swift` tone body markers use `sample.contains("ty!")`, which fires on "party!", "warranty!", "plenty!", "safety!" etc. Same class of issue for `"lol"` (matches "lollipop") — but `ty!` is the most likely real-world false positive. Consider word-boundary checks or dropping `ty!`.

**L2 — First-line formal detection misses bare `"Hello"` / `"Hello!"`.** The `hi` branch handles `open == "hi"` and `"hi!"`, but the formal branch only checks `"hello "` and `"hello,"` — a prior mail opening with just `Hello` or `Hello!` falls through to body signals. Similarly `"dear "` requires the trailing space, so `"Dear,"`/`"Dear:"` misses (rare). Inconsistent with the `hi` handling; likely unintentional.

**L3 — `"On "` first-line skip discards legitimate openers.** The first-line finder skips any line starting with `"On "` (intended for `On Mon, X wrote:`), so a body opening "On Monday we shipped..." has its first line ignored for tone. Harmless (falls back to body signals) but worth a `wrote:` suffix check if refining.

**L4 — `recipientFirstName` local-part guess can still produce odd names, by design.** `person(from:)` title-cases `noreply@x.com` → "Noreply", `info@x.com` → "Info". Pre-existing behavior, not a regression — flagging only because the task was "contacts issue fixable"; if the contact store still holds junk, the ghost now shows a guessed local-part name rather than nothing. Acceptable tradeoff, and `@host` / empty-local cases are correctly handled (`GreetingAutocomplete.swift` `person(from:)` with `omittingEmptySubsequences: false` — nice catch, and tested).

**L5 — Emoji casual detection covers only U+1F300–U+1FAFF.** Misses `❤️` (U+2764), `✨` (U+2728), `☺`. Fine as a heuristic; noting for completeness.

### Correctness spot-checks that pass

- Root cause correctly fixed: `isUsableDisplayName` uses `caseInsensitiveCompare` and an `@`-shape check (`ContactMiner.swift`), covering the original `John@ormoni.bio` vs lowercased-key mismatch. Tested at `ContactMinerTests.swift:158` and the legacy-map scrub in `ranked` means no weight-map rebuild is needed — matches the "fixable without rebuild" requirement.
- Merge name-preference change preserves old tie behavior (prev wins on equal length) and adds "empty never wins" — verified against the old expression; `testEmailShapedNameNeverWinsOverRealName` covers the regression risk.
- `ComposeView.person(from:)` now delegates to `GreetingAutocomplete.person(from:)`; behavior is identical except the `omittingEmptySubsequences` fix, which only improves the `@host` edge. Other call sites of `person(from:)` (chips) get the same safe behavior.
- Defense in depth in `suggestion`/`templates` (`isUsablePersonName` guard) means even stale callers can't produce an email-shaped ghost — tested.
- Tone plumbing default `.neutral` keeps all pre-existing call sites/tests behavior-compatible.

## Open questions

1. Is per-keystroke tone recomputation (M1) acceptable for typical reply sizes in this app, or should it be memoized? (If `stripHTML` is cheap regex on small bodies it may be fine — I'd still memoize.)
2. Intentional that a prior mail opening with bare `"Hello"` (L2) is treated as neutral?

## Suggested fixes (not applied — read-only)

1. **M1**: Cache tone once per compose: `@State private var greetingTone: Tone = .neutral` set in `.onAppear`/`task` from `original`, or a `lazy` computed via a memo keyed on `original?.id`.
2. **L1**: Replace `"ty!"` with word-boundary matching (e.g. check `" ty!"`/line-start) or drop it.
3. **L2**: Add `open == "hello" || open.hasPrefix("hello!")` to the formal branch for parity with the `hi` branch.

## Test coverage

Good: root cause (cased bare address), legacy-map scrub, merge preference, tone classification (casual/formal/neutral), empty-body tone defaults, ambiguous-prefix tone ordering, defense-in-depth nil ghost, `@host` edge. Gaps: no test for `Hello`-alone tone (L2), no `ty!` false-positive test (L1), and `ComposeView.greetingTone` integration is untested (view-level, harder — acceptable).

## Verdict

**SHIP** — the core bug fix is correct, well-guarded at multiple layers, and well-tested; remaining findings are a perf nicety and heuristic polish, none blocking. (Caveat: tests were reviewed statically, not executed.)
