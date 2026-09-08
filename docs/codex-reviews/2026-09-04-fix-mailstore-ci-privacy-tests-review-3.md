---
date: 2026-09-04
kind: fable-iterate review
target: branch fix/mailstore-ci-privacy-tests vs origin/main
verdict: SHIP
review_model: claude-fable-5
review_effort: low
requested_model: claude-fable-5
job_id: review-20260904T164646-82403
started_at: 2026-09-04T23:46:47Z
finished_at: 2026-09-04T23:48:11Z
reviewed_commit: 204a1fef18687cc991fd36dbdc2f633cb401670a
pass: 3
duration_ms: 81545
total_cost_usd: 1.339087
num_turns: 10
---

# Review — MailStore split + Notion Mail migration (pass 3)

Prompt:

```
Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Pass 2 (review-20260904T164257-80154) returned SHIP with a valid Medium: snippet variable rewrite could corrupt bodies with literal braces. That is fixed on 204a1fe: rewrite only known aliases, restrict the inner charset, leave code braces and unknown tokens verbatim, and cover it with tests. Also wording: skipped (not skipped existing), CHANGELOG no longer claims Settings opens on the pane, cancel keeps the last import result.

Confirm the rewrite fix and that nothing else regressed.
```

## Verbatim review

## Review result: SHIP

I reviewed the full diff against origin/main. I confirm the rewrite fix on 204a1fe. The full unit suite passes: 1772 tests, 0 failures, 1 skipped.

### Confirmation of the pass-2 fix

- `Sources/MishMail/Support/SnippetImport.swift:51-63` — the rewrite now maps only known aliases through `canonicalVariable`. Unknown tokens `continue` and stay verbatim.
- The regex at `SnippetImport.swift:141-142` restricts the inner charset to `[A-Za-z][A-Za-z0-9 _-]*`. Code such as `{ let a = 1 }` cannot match because `=` breaks the pattern.
- Tests cover both cases: `SnippetImportTests.swift:113-125` checks alias mapping, unknown tokens (`{{key_point_1}}`, `{{Company Name}}`), and code braces.
- The status message now says "skipped N", not "skipped N existing" (`NotionMailSettings.swift:129`). This is accurate: the skipped count also includes blank rows and in-file duplicates.
- Cancel keeps the last import result: `SnippetFileImport.apply` returns `nil` on `.failure`, and both call sites (`NotionMailSettings.swift:72-74`, `SettingsView.swift:583-585`) only assign on a non-nil message.
- The CHANGELOG now says "Settings lists a migration pane first," which matches the actual behavior.

### Findings

**Low — brace loss on unbalanced known tokens.** `SnippetImport.swift:142`: the pattern `\{{1,2}…\}{1,2}` accepts unbalanced braces. A body with `{name}}` becomes `{name}` and loses one `}`. Same for `{{name}` → `{name}`. This needs a known alias adjacent to unbalanced braces, so it is a rare input. Suggested fix, if you care: match `\{\{…\}\}` and `\{…\}` as two alternatives and require balance.

**Low — rewrite also applies to MishMail-format imports.** `SnippetImport.swift:99` and `:133` rewrite every import path. A MishMail re-import with `{today}` or `{first}` becomes `{date}` / `{first_name}`. The result still expands correctly, so this is normalization, not corruption. No change needed.

**Observation.** `{ name }` inside code text rewrites to `{name}` because "name" is a known alias. Only whitespace changes, and the token is a valid placeholder either way. No change needed.

### Open questions

None. The `unknownAccountIds` count and the `plan` skip logic behave as documented.

### Verification

`make test` in the worktree: **TEST SUCCEEDED**, 1772 tests, 0 failures.
