---
date: 2026-09-04
kind: fable-iterate review
target: branch fix/mailstore-ci-privacy-tests vs origin/main
verdict: SHIP
review_model: claude-fable-5
review_effort: low
requested_model: claude-fable-5
job_id: review-20260904T164257-80154
started_at: 2026-09-04T23:42:57Z
finished_at: 2026-09-04T23:44:46Z
reviewed_commit: 561a59f
pass: 2
duration_ms: 109000
total_cost_usd: 1.710749
---

# Review — MailStore split + Notion Mail migration (pass 2)

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
- Ship a Moving from Notion Mail page and import Notion Mail snippets (JSON/CSV, shortcut/content, variable mapping) as a migration guide before the 22 Sep 2026 shutdown.

Pass 1 (job review-20260904T163422-72773) returned SHIP on 722dfb0. Since then: Notion Mail page/importer (d5856d0) and the AITriage nil-config comment fix (561a59f). make test passed locally (1771 tests) after the project.yml directory include.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.
```

## Verbatim review

Review complete. Here is the report.

## Verdict: SHIP

Pass 1 covered 722dfb0. This pass covers d5856d0 (Notion Mail page and importer) and 561a59f (comment fix). I read the full new code, the store integration, the tests, the CI file, and the docs.

## Findings

**Medium — variable rewrite can corrupt snippet bodies with literal braces.**
`Sources/MishMail/Support/SnippetImport.swift:142-169`. The rewrite regex is `\{{1,2}\s*([^}]+?)\s*\}{1,2}`. It matches any brace group, not only variable tokens. Compare `SnippetExpander.swift:47-48`, which only treats `[A-Za-z0-9_]+` as a placeholder. Example: a snippet body with `struct X { let a = 1 }` becomes `struct X {let_a_=_1}` on import. The rewrite also lowercases and rewrites unknown tokens such as `{{Company Name}}` → `{company_name}`; the code comment says this is intended, but casing and punctuation are lost. The rewrite runs on every import path, so MishMail's own JSON re-imports also change. This is a regression: before this diff, import kept the body verbatim. The damage is silent, and a re-import cannot fix it because `plan()` skips existing names. Suggested fix: restrict the inner charset to `[A-Za-z0-9 _-]+`, or rewrite only tokens whose canonical form appears in `variableAliases` and leave all other brace groups untouched.

**Low — "skipped … existing" count includes dropped blanks.**
`MailStore.swift:4628` returns `items.count - planned.count` as `skipped`. `plan()` also drops items with an empty name or body. The UI then reports those blanks as "skipped existing" (`NotionMailSettings.swift:127`). Cosmetic. Suggested fix: return a separate blank count or word the message as "skipped".

**Low — cancel in the file importer now clears the last result.**
`SettingsView.swift` (Snippets pane): the old code kept `importResult` on `.failure`; `SnippetFileImport.apply` returns `nil`, so a cancel now erases the previous "Imported N" message. Trivial behavior change; probably fine.

**Nit — CHANGELOG says "Settings opens with a migration pane."** The pane sits first in the sidebar, but `@AppStorage("settingsPane")` still defaults to `.accounts` (`SettingsView.swift:47`). The wording overstates it slightly.

## What checks out

- The Cmd-K command writes `settingsPane` through `UserDefaults` and the `@AppStorage` enum reads it; the raw-value round trip works.
- `importSnippets` handles the security-scoped URL, dedupes case-insensitively, and counts unknown account ids as documented.
- The AITriage comment fix (561a59f) now matches the code: `nil` config returns `false`, so the classify pass still runs and fails locally. Hosted refusal for silent auto-sort is unchanged.
- CI runs unit tests plus build on `pull_request` and pushes to `main`; the UI suite is a separate job, so a UI hang cannot mask unit results.
- The test target now uses directory includes in `project.yml` with only app-only excludes, per the task.
- Tests cover the wrapped JSON, shortcut/content keys, CSV with quoted newlines, BOM-free garbage rejection, empty array, and alias mapping. Coverage is good.

## Open questions

1. Is the lowercase-and-underscore rewrite of unknown tokens (for example `{{Key Point 1}}` → `{key_point_1}`) the desired product behavior, or should unknown tokens keep their original text?
2. Should the Notion pane become the default selected pane on first open after this release, to match the CHANGELOG claim?

Read-only mode: I applied no fixes.
