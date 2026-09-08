---
date: 2026-09-07 22:09
kind: fable-iterate review
review_model: claude-fable-5-1
review_effort: low
requested_model: latest-fable
resolved_model: claude-fable-5-1
canonical_model: claude-fable-5-1
model_substitution: none
modelResolutionVerified: true
job_id: review-20260907T220700-64079
branch: feat/ask-mish-thinking-model-rank
base: main (69245a0)
reviewed_commit: ff89ae0
verdict: SHIP
started_at: 2026-09-08T05:07:00Z
finished_at: 2026-09-08T05:09:23Z
checks: make test → TEST SUCCEEDED, 1811 tests, 1 skipped, 0 failures
total_cost_usd: 2.84684475
num_turns: 12
duration_ms: 139684
---

# Review pass 3 — hosted thinking and ranked models

## Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Ask Mish thinking effort on hosted models, plus intelligence floor/groups in the picker. Hide Claude 3.5 Haiku from browse. Search still finds the full list.

Pass 2 returned NOT READY. Re-check:
HIGH: Fable ids no longer send thinking type disabled (acceptsDisabled is false; omit the field). Test covers claude-fable-5-1 with .off.
Also: Fable ranks as frontier. applyAuth uses the support-checked hosted thinking value. grok-3-mini medium maps to high. Routed ids still show as a subtitle next to thinking.

The pass-2 MEDIUM about Fable 5.1 signature binding vs compacted tool results is latent for existing orgs. Do not block SHIP on that unless it is a real request failure on this branch.

Do not count a fallback to a different model family as approval.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.

```

## Verbatim review

All 122 tests in the eight touched suites pass. Review complete.

## Pass 3 review: `feat/ask-mish-thinking-model-rank` vs `main`

**Verdict: SHIP.**

Reviewed commit ff89ae0. The worktree is clean. I ran the eight touched test classes.

| Scope | Result |
|---|---|
| Anthropic, OpenAI, Ollama wire, model rank, model menu, context, migration, provider store | 122 tests, 0 failures |

### Pass-2 items, verified

1. **HIGH fixed. Fable ids omit `thinking` on `.off`.** `acceptsDisabled` returns false for Fable at `Sources/MishMail/Support/LLMChat.swift:361`. The `.off` branch at `LLMWireAnthropic.swift:76` only sends `disabled` when that check passes. The test `testRequestBodyOmitsOffOnFable` asserts no `thinking` and no `output_config` key. This matches the API contract: Fable rejects `disabled` and `budget_tokens`, and omitting the parameter is the documented form.
2. **Fable ranks as Frontier.** `claudeRank` checks "fable" before the haiku, opus, and sonnet cases at `LLMModelRank.swift:42`. `isClaude3` does not match `claude-fable-5-1`. Test covers it.
3. **`applyAuth` uses the support-checked value.** `LLMClient.swift:182` passes `hosted`, not the raw stored value.
4. **grok-3-mini medium maps to high.** `openAIEffort` at `LLMChat.swift:411`. Test covers it.
5. **Routed-id subtitle is back.** `AskMishPanelView.swift:1082` shows the full id under the thinking line in both browse and search.

### Findings by severity

No HIGH or MEDIUM findings that fail a request on this branch.

**LOW. "Think: off" on Fable still thinks.** Fable runs adaptive thinking whenever the parameter is absent. The UI shows "Think: off" but the model reasons at default effort. This is the correct wire choice. A short note in the Think menu help, or a disabled "off" row for Fable ids, would remove the mismatch. Not a blocker.

**LOW. `gpt-5-chat-latest` gets `reasoning_effort`.** `supports` at `LLMChat.swift:346` returns true for every `gpt-5*` prefix. The chat-only variant does not accept the field. Exposure is small because the ChatGPT fallback list does not ship that id. Add `!name.contains("chat")` to the GPT-5 branch if a user reports it.

**LOW, latent, not blocking per instructions. Preserved thinking on Fable 5.1.** `prepareForModel` at `AskMishContext.swift:154` rewrites older tool results. The API reference confirms Fable 5.1 checks replayed thinking blocks against the prefix and returns 400 for orgs created on or after 2026-08-31. Ron's org predates that date. Replaying blocks on a different model is safe: the reference states other models drop them silently, so a mid-conversation model switch does not fail.

**INFO. Opus 5 with `disabled`.** The reference notes two failure modes when thinking is disabled on Opus 5: tool calls written as text and leaked thinking tags. The branch sends `disabled` for Opus 5 on the `.off` path, which is the default for drafts, summaries, and triage. That is a behavior risk, not a request failure. Low effort with thinking on is the documented alternative.

### Open questions

- Should the `.off` picker row hide or relabel for Fable ids, since the model cannot turn thinking off?
- Do you want drafts and triage on Opus 5 to send `disabled`, or to use `low` effort as the reference suggests?

### Suggested fixes (not applied)

1. In `applyThinking` for Anthropic, treat `.off` on Fable as `adaptive` plus `effort: low`. That honors user intent as closely as the API allows.
2. Exclude `chat` ids from the GPT-5 branch of `LLMHostedThinking.supports`.
3. Add a test for `openAIEffort("xhigh", model: "gemini-3.7-flash")` returning `high`. The mapping is correct today but untested.

