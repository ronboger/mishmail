---
date: 2026-09-07 22:04
kind: fable-iterate review
review_model: claude-fable-5-1
review_effort: low
requested_model: latest-fable
resolved_model: claude-fable-5-1
canonical_model: claude-fable-5-1
model_substitution: none
modelResolutionVerified: true
job_id: review-20260907T220030-60390
branch: feat/ask-mish-thinking-model-rank
base: main (69245a0)
reviewed_commit: 5d42c28
verdict: NOT READY
started_at: 2026-09-08T05:00:30Z
finished_at: 2026-09-08T05:04:05Z
checks: make test → TEST SUCCEEDED, 1810 tests, 1 skipped, 0 failures
total_cost_usd: 3.6243890000000003
num_turns: 22
duration_ms: 211238
---

# Review pass 2 — hosted thinking and ranked models

## Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Ask Mish should let the user set thinking effort on hosted models (not only Ollama). The model picker should make it clear which models are worth using — hide older/weak ids such as Claude 3.5 Haiku from browse, and provide a filter/display by intelligence (frontier / strong / current / all). Search still finds the full list.

Pass 1 returned NOT READY. Re-check those fixes:
1. HIGH: .off no longer sends reasoning_effort none on GPT-5 / o-series (omit instead). Claude 4.6+ still sends thinking disabled.
2. HIGH: Anthropic thinking blocks (text + signature) are captured, stored on LLMMessage, persisted in chatMessage.thinkingBlocksJSON (v38), and replayed before tool_use on the next assistant turn.
3. MEDIUM: Ollama clamps xhigh to high. Grok 4 no longer claims reasoning_effort support. OpenAI xhigh maps to high except on GPT-5.1+.
4. LOW: interleaved-thinking beta only when a thinking level is set and tools are present. Subtitle says Ask Mish thinking. Floor no longer falls back to the full list.

Do not count a fallback to a different model family as approval.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.

```

## Verbatim review

The Write and ExitPlanMode tools are not available in this session, so I deliver the review as the final report. I made no changes to the repository.

## Pass 2 review: `feat/ask-mish-thinking-model-rank` vs `main`

**Test state.** The eight touched test classes pass.

| Suite scope | Result |
|---|---|
| Anthropic, OpenAI, Ollama wire, model rank, model menu, context, migration, provider store | 121 tests, 0 failures |

Worktree is clean after the run.

### Pass-1 fixes, verified

1. **OpenAI `.off` omitted.** `Sources/MishMail/Support/LLMWireOpenAI.swift:61` returns without a field. Claude 4.6+ still sends `thinking: disabled` at `LLMWireAnthropic.swift:76`. Tests cover both. Confirmed, with one gap below.
2. **Thinking blocks round-trip.** The stream state collects `thinking`, `signature_delta`, and `redacted_thinking` at `LLMWireAnthropic.swift:127-166`. The controller stores them on the message and in `thinkingBlocksJSON` (v38). The request builder replays them before `tool_use` at `LLMWireAnthropic.swift:19-27`. Interrupted and cancelled turns also persist them. Confirmed.
3. **Ollama clamps xhigh to high.** `LLMWireOllama.swift:52`. Grok 4 returns false from `supports`. OpenAI xhigh maps to high except GPT-5.1+. Confirmed with tests.
4. **Beta header, subtitle, floor.** Header only with a level and tools at `LLMClient.swift:222`. Subtitle reads "Ask Mish thinking". Floor returns an empty list rather than the full list, and a test covers it. Confirmed.

### Findings by severity

**HIGH. `.off` sends `thinking: disabled` to Claude Fable models, which return 400.**
`LLMHostedThinking.usesAdaptive` at `LLMChat.swift:369` returns true for any id that contains "fable". The `.off` branch at `LLMWireAnthropic.swift:75-77` then sends `{"type":"disabled"}`. Fable 5 and Fable 5.1 reject that config at any effort. Drafts, summaries, and triage default to `.off` in `Ollama.defaultThinking`, so a user who picks a Fable id for those tasks gets every request rejected. Ask Mish users who select "Think: off" hit the same error. No test covers a Fable id in the request body.

**MEDIUM. Thinking replay meets history edits on Fable 5.1.**
`AskMishContext.prepareForModel` at `AskMishContext.swift:154-166` rewrites older tool results in the middle of the transcript. The system prompt embeds the current date at `AskMishController.swift:553`. Fable 5.1 binds each thinking block signature to the prefix that produced it. Organizations created on or after 2026-08-31 get a 400 when a replayed block follows an edited prefix. Older organizations only record the mismatch today. This is not a regression for Ron's account, but it is a latent failure for any user on a new organization.

**LOW. Interleaved beta header uses the raw thinking value, not the support-checked one.**
`LLMClient.swift:182` passes `thinking`, while the body uses `hosted`. A non-thinking Claude id with a stored level and tools gets the beta header without a thinking body. The API ignores it, so no failure. Cosmetic.

**LOW. `reasoning_effort: medium` is not valid on grok-3-mini.**
xAI documents only `low` and `high` for that model. `openAIEffort` passes `medium` through. The model ranks as Older, so exposure is small.

**LOW. Fable ids rank as Strong, below Opus.**
`claudeRank` at `LLMModelRank.swift:40-46` has no Fable case, so `claude-fable-5-1` lands in Strong under Opus 5 in the browse list.

**LOW. Routed-id subtitle is lost for thinking models.**
`AskMishPanelView.swift:1067-1078` shows the thinking subtitle instead of the full routed id. An OpenRouter user no longer sees the vendor prefix for `anthropic/claude-sonnet-5`. Small display regression.

### Open questions

- Does the Claude subscription OAuth model list ever return a Fable id for this account? If yes, the HIGH finding hits Ron directly.
- Is the 8192 `max_tokens` cap in `LLMClient.swift:172` still right for adaptive `xhigh` and `max`? Thinking tokens count against it.

### Suggested fixes (not applied)

1. Add `LLMHostedThinking.acceptsDisabled(model)` that returns false for Fable ids. Use it in the `.off` branch and omit the field for Fable. Add a test with `claude-fable-5-1` and `.off` that asserts no `thinking` key.
2. For Fable ids, replay thinking blocks only on the final assistant turn, or freeze the date in the system prompt for the life of a conversation. Both keep the prefix intact.
3. Pass `hosted` instead of `thinking` to `applyAuth`.
4. Map `medium` to `high` for grok-3-mini in `openAIEffort`.
5. Add a Fable case to `claudeRank` that returns `.frontier`.

**Verdict: NOT READY.** The four pass-1 fixes hold. One new HIGH remains: the `.off` path sends a rejected config to Fable models on the default-off tasks.

