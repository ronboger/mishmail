---
date: 2026-09-04
kind: fable-iterate review
target: branch fix/mailstore-ci-privacy-tests vs origin/main
verdict: SHIP
review_model: claude-fable-5
review_effort: low
requested_model: claude-fable-5
job_id: review-20260904T163422-72773
started_at: 2026-09-04T23:34:22Z
finished_at: 2026-09-04T23:37:16Z
reviewed_commit: 722dfb00640f33a2386f3f7abba86fa78b0e70f4
pass: 1
duration_ms: 169220
total_cost_usd: 3.165918
num_turns: 24
---

# Review — MailStore split, CI, privacy, test sources (pass 1)

Prompt:

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'origin/main' (diff / log as needed).
Focus: Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task:
- Split MailStore command/service work (sync/mutations, compose/drafts, local reminders, AI, account lifecycle) away from observable UI state without dozens of MVVM objects.
- CI must run unit/build on pull_request + pushes to main; expensive UI suite separately.
- Fix README privacy claim: hosted LLM providers exist, Local vs Hosted, hosted drafting, host-consent, silent auto-sort refuses hosted.
- Stop enumerating production files in the test target; directory includes now, Swift packages longer term.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.
```

## Verbatim review

Review complete. I compared the branch against origin/main and verified the split, the CI change, the README change, and the test-target change.

## Verification method

The old `MailStore.swift` had 6,751 lines. The new main file plus six extensions total 6,748 lines. A sorted diff of all function and property signatures shows zero removed symbols. Every change is a visibility change (`private` → internal) that the cross-file extensions require. I compared the moved bodies for the four extracted policy areas (AI triage, accounts, reminders, compose reply-parent) line by line against origin/main. All are faithful moves with the policy decision routed through the new Support types.

## Findings

**Medium — the new test-target shape is unverified.** The branch is local only. No CI run exists for it (`gh run list` shows no run for this branch). Read-only mode blocks `make test` here because it regenerates `MishMail.xcodeproj`. The directory include adds four files that the old list did not compile: `LLMClient.swift`, `LLMTaskRunner.swift`, `Notifier.swift`, `MessageDateFormat.swift`. Their imports (AppKit, UserNotifications) do link in a macOS test bundle, and I found no code reference from an included file to an excluded one (`GmailFilterDisplay.swift:114` uses `@Environment(MailStore.self)` but it is on the exclude list). So this should compile, but nothing has proven it. Push the branch and let the new PR trigger run before merge.

**Low — comment contradicts code in `Sources/MishMail/Support/AITriage.swift:22`.** The doc comment on `shouldSkipSilentAutoSort` says "`nil` config means 'no provider resolved' — skip rather than guess," but the code returns `false` (do not skip) for nil. The code matches the old behavior at old `MailStore.swift:655` and the test asserts it. Fix the comment, not the code.

**Low — encapsulation loss is broad.** About 30 previously `private` stored properties (`syncTimer`, `pendingSend`, `suppressedDraftThreadIds`, `knownUnreadInboxIds`, …) and ~14 methods are now internal, so all UI code can mutate them. This is the known cost of same-module extensions and the task accepted it; the Swift-package step will force this decision again. `@ObservationIgnored` counts match exactly (39 before, 39 after), so no observation regression.

**Low — Actions cost returns.** The UI job was removed from push triggers earlier because of Actions overuse (old Makefile comment). It now runs a second macOS runner on every PR and every push to main. This is what the task asked for, but macOS minutes are 10x; a `paths-ignore` for docs-only changes would trim it.

**Info — checked and clean:**
- `AccountLifecycle.accountAfterSignIn` preserves `historyId`/`lastSyncAt` exactly as the old inline code did, and the update/insert split keys off `existing != nil` correctly.
- `LocalReminders.clearSQL` is byte-identical to the old compare-and-clear statement; arguments order matches.
- `LocalReminders.fireAt` changes a force-unwrap (`Calendar.date(...)!`) to an optional chain — safe, same value.
- `MailStore.replyParent` and the `autoClassifyKey`/`undoSendWindow` statics remain as forwarding shims, so `MCPBridge.swift:651`, `SettingsView.swift:1561`, and `AskMishPanelView.swift:611` still compile.
- CI job split is correct: `pull_request` + `push: main` + release + dispatch; the UI job is independent, so a UI hang cannot mask unit results. GitHub sets `CI=true`, which satisfies the Makefile gate.
- README/Security/CONTRIBUTING copy matches the actual policy (`LLMRemotePolicy.blocksSilentAutoSort`, LAN Ollama allowed, host consent for typed-in hosts) and the new tests pin the silent-auto-sort refusal for hosted providers.
- New tests are real behavior tests, not tautologies (except `testClearSQLMatchesCompareAndClearPredicate`, which only string-matches the SQL — weak but harmless).

## Open questions

1. Did `make test` pass locally before commit? The pre-commit hook implies yes, but the reshaped target is the one thing the hook run would have proven — confirm it ran after the `project.yml` change.
2. Is the doubled macOS runner spend per PR acceptable, given the earlier overuse rollback?

## Suggested fixes (not applied)

1. Correct the `nil`-config comment in `AITriage.swift:20-22` to say "nil means no provider resolved — the classify pass runs and fails locally, same as before."
2. Optionally add `paths-ignore: ['**.md']` to the CI triggers.

## Verdict

**SHIP** — after one green CI run on the pushed branch. The refactor is a faithful move with real new test coverage, the CI and docs changes match the task, and the only defect found is a comment. The single gate is that no build has yet compiled the new directory-based test target.
