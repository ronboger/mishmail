---
date: 2026-09-07 21:52
kind: fable-iterate review
review_model: claude-fable-5-1
review_effort: low
requested_model: latest-fable
resolved_model: claude-fable-5-1
canonical_model: claude-fable-5-1
model_substitution: none
modelResolutionVerified: true
job_id: review-20260907T215046-55439
branch: feat/ask-mish-thinking-model-rank
base: main (69245a0)
reviewed_commit: edc74d6
verdict: NOT READY
started_at: 2026-09-08T04:50:46Z
finished_at: 2026-09-08T04:52:56Z
checks: make test → TEST SUCCEEDED, 1804 tests, 5 skipped, 0 failures
total_cost_usd: 1.9595304999999998
num_turns: 9
duration_ms: 127689
---

# Review pass 1 — hosted thinking and ranked models

## Prompt

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Ask Mish should let the user set thinking effort on hosted models (not only Ollama). The model picker should make it clear which models are worth using — hide older/weak ids such as Claude 3.5 Haiku from browse, and provide a filter/display by intelligence (frontier / strong / current / all). Search still finds the full list.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.

```

## Verbatim review

Review of `edc74d6` against `main`. Verdict: **NOT READY**. Two defects break real requests. One is a regression for users who never touch the new controls.

## Findings

**1. HIGH. Summaries, drafts, and auto-sort on GPT-5 and o-series now send an invalid reasoning value.**
Evidence: `Sources/MishMail/Support/Ollama.swift:57` returns `.off` for every task except Ask Mish. `Sources/MishMail/Support/LLMClient.swift:246` now forwards that value to hosted providers. `Sources/MishMail/Support/LLMWireOpenAI.swift:522` encodes `.off` as `reasoning_effort: "none"`. Per OpenAI docs, `none` is only accepted from GPT-5.1 onward. GPT-5, o3, o4-mini, and o1 reject it with a 400. Gemini Pro and Gemini 3 models also cannot turn thinking off. Before this branch no field was sent, so these tasks worked. The regression fires with default settings. Tests cover `gpt-5` with `.off` and assert the bad value, so the test locks in the bug (`Tests/MishMailTests/LLMWireOpenAITests.swift:113`).

**2. HIGH. Claude thinking levels break the Ask Mish tool loop on the second request.**
Evidence: `Sources/MishMail/Support/LLMWireAnthropic.swift:19` rebuilds assistant turns from text plus tool calls only. `LLMMessage` (`LLMChat.swift:186`) has no field for thinking blocks or signatures, and `StreamState` at `LLMWireAnthropic.swift:127` drops the signature. The Anthropic API requires the thinking block to be sent back on the assistant turn that holds `tool_use` when thinking is enabled. The follow-up request after a tool call returns a 400. This applies to both adaptive and budget modes. The interleaved-thinking beta header at `LLMClient.swift:302` does not remove that rule. No test covers a multi-turn body with thinking on.

**3. MEDIUM. "Extra high" is sent to Ollama as `think: "xhigh"`.**
Evidence: `LLMChat.swift:118` now accepts `xhigh`; `LLMWireOllama.swift:51` writes the raw value. The settings picker at `SettingsView.swift:1908` and the Ask Mish menu at `AskMishPanelView.swift:525` offer it for local models too. Ollama accepts only `low`, `medium`, `high`, or a boolean. The capability gate at `LLMClient.swift:264` does not help, because the model does support thinking. The stored value is shared across providers, so a user who sets extra high on Claude and later switches to a local model gets failed requests.

**4. MEDIUM. `reasoning_effort` on xAI Grok 4 and `xhigh` on older OpenAI models are likely rejected.**
Evidence: `LLMHostedThinking.supports` (`LLMChat.swift:175`) returns true for every `grok-` id except Grok 2. xAI documents that Grok 4 models do not accept `reasoning_effort`. OpenAI accepts `xhigh` only on newer models; `gpt-5` and o-series reject it. I could not check the live APIs, so treat this as plausible.

**5. LOW. Beta header is now sent on every Anthropic request.**
`LLMClient.swift:302` adds `interleaved-thinking-2025-05-14` even when thinking is off or the model is Claude 3.x. It is likely ignored, but it is a behavior change for OAuth sessions. Verify that the claude.ai OAuth gateway accepts a combined beta header.

**6. LOW. The right-click "Think:" menu writes a global setting but looks per-model.**
`AskMishPanelView.swift:719` sets the Ask Mish task value. Each thinking model row shows the same `thinking: high` subtitle, which reads as per-model state. The changelog says "set its effort", which overstates it.

**7. LOW. Floor filter silently falls back to the full list.**
`AskMishModelMenu.swift:58` keeps all models when no model meets the floor. The Show menu still reads "Frontier", so the label and the list disagree.

## Task coverage

- Hosted thinking effort: implemented, but see findings 1 to 4.
- Hide Claude 3.5 Haiku from browse: done, tested (`AskMishModelMenuTests.swift:181`).
- Intelligence filter and grouped display: done, persisted, tested.
- Search still finds the full list: done, tested (`AskMishModelMenuTests.swift:242`).

## Open questions

- Does the Claude subscription OAuth endpoint accept `thinking` and `output_config` in the body?
- Should the `.off` default for summaries and triage apply to hosted models at all? The old behavior was "send nothing".

## Suggested fixes

1. Map `.off` to "omit the field" for OpenAI-compatible hosts, or only emit `none` for ids known to accept it. Keep `.off` as `disabled` for Claude 4.6+ only.
2. Add a thinking block carrier to `LLMMessage`. Capture `signature_delta` in the Anthropic stream state. Replay thinking blocks first in assistant turns. Add a two-turn test with tool use.
3. Clamp `xhigh` to `high` in the Ollama codec, or hide "Extra high" when the current model is local.
4. Narrow `supports` for Grok and map `xhigh` to `high` for models that lack it.
5. Send the interleaved beta only when a thinking level is set and tools are present.
6. Change the subtitle and changelog wording to "Ask Mish thinking: high", or make the setting per-model.
7. When the floor empties a list, show an empty state with a hint instead of the full list.

Verdict: **NOT READY**.

