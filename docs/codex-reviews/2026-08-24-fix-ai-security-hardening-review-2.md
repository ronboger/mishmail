---
date: 2026-08-24
kind: fable-iterate review
target: branch fix/ai-security-hardening vs main
verdict: SHIP
review_model: claude-opus-5
review_effort: low
requested_model: opus
job_id: review-20260824T002442-62495
started_at: 2026-08-24T07:24:42Z
finished_at: 2026-08-24T07:26:59Z
reviewed_commit: 70d0eaaca09954f52ae4c17b01bb2444f22c52a0
pass: 2
---

# Review — AI security hardening (pass 2)

Prompt:

```
[jacq-claude] Mode: READ-ONLY. Do not modify project files. Analyze and report only.

You are a careful code reviewer. Focus on correctness, security, edge cases, and test gaps. Be specific (file:line).
Compare against git ref 'main' (diff / log as needed).
Focus: Pass 2. Review the complete diff against main after addressing pass 1 (NOT READY). Confirm: (1) forged </untrusted-mail> cannot close the wrapper, (2) unknown tools require confirm, (3) send fingerprint includes From/account and missing preview refuses send, (4) host consent fails closed, exact host match. Check regressions. Give findings by severity and finish with SHIP or NOT READY.

Deliver:
1. Findings ordered by severity with evidence
2. Open questions
3. Suggested fixes (do not apply unless write mode was requested)

Do not modify files unless explicitly told to write.
```

## Verbatim review

Permission deny rule "MultiEdit" matches no known tool — check for typos.
Reviewed the full diff, rebuilt, and ran the suite: `make test` → **1677 tests, 0 failures** (1 skipped).

## Pass-1 items: all four confirmed

| Claim | Evidence | Status |
|---|---|---|
| Forged `</untrusted-mail>` cannot close the wrapper | `AskMishContext.swift:70-76` regex `<(/?)untrusted-mail` → `[$1untrusted-mail]`, case-insensitive; applied in `contextMessage` (`:57`) and `wrapToolResult` (`:93`) | ✅ |
| Unknown tools require confirm | `AskMishTools.swift:66-68` `isWriteTool = !readToolNames.contains(name)`; allow-list at `:49-56` matches the MCP read catalog exactly | ✅ |
| Send fingerprint includes From/account; missing preview refuses send | `AskMishTools.sendFingerprint` = accountId+from+to+cc+bcc+subject+body (`:250-256`); `requestConfirmation` returns `.unavailable` when the preview is nil (`AskMishController.swift:432-437`); `askMishSendDraft` throws on nil **or** mismatched fingerprint (`MCPBridge.swift:638-647`) | ✅ |
| Host consent fails closed, exact host | `LLMProviderStore.hasHostConsent` (`:141-148`): unparseable host → `false`; preset → true; else exact lowercased match. `sendsMailOffDevice` returns `true` on unparseable URL (`LLMChat.swift:183-187`) | ✅ |

No regressions found. The `⌘L`/`GmailWebLinks` deletions in `git diff main` are **not** removals — the branch is 3 commits behind `main` (`8a3afe4`, `b02a073`, `4697749`). Rebase before merge.

## Findings by severity

**Medium — Ollama-kind providers bypass the host-consent gate.** `LLMClient.swift:161-168` applies `hasHostConsent` only in the `else` branch. A provider row with `kind == .ollama` goes to `Ollama.validateEndpoint`, which tests the **global** `Ollama.baseURL` for loopback, not the URL passed in — the doc comment at `Ollama.swift:202-205` states this limitation. So a second Ollama-kind row pointed at a remote HTTPS host sends mail there with no consent check when the built-in row is loopback. The `Hosted` badge does show, but the gate does not fire. Fix: move the `hasHostConsent` check above the `if config.kind == .ollama` split.

**Low — a future mutating tool is Return-confirmable.** `requiresExplicitClick` is a deny-list (`AskMishTools.swift:60-63`), so an unknown tool gets a card but ↩ still confirms it (`AskMishPanelView.swift:420`). The `isWriteTool` fix used the safer allow-list shape; this one did not. Fix: `requiresExplicitClick(name) = !readToolNames.contains(name) && name != <known-benign writes>`, or simply treat unknown names as click-required.

**Low — host consent ignores port and scheme.** `hostConsentKey` stores only the host, so consent for `https://h.example` also covers `https://h.example:8443`. Acceptable if intentional; worth a comment.

**Low — non-`get_thread` tool results are not truncated.** `wrapToolResult` (`AskMishContext.swift:81-88`) clips only `get_thread`. A wide `search_threads` result with long snippets is unbounded context. Cost, not security.

**Low — dead code.** `MailStore.askMishSendConfirmSummary` (`MCPBridge.swift:693`) now has no callers; only a doc comment references it.

**Test gaps.** No test asserts `isWriteTool("some_future_tool") == true` — that is the exact invariant the fix exists for. No test covers `askMishSendDraft` refusing a nil or drifted fingerprint; the fingerprint test only checks that the string changes.

## Open questions
1. Is a second Ollama-kind provider row reachable in the UI? That decides whether the Medium is live or theoretical.
2. Is `set_thread_summary` deliberately Return-confirmable, or is the click list meant to be "anything not read"?

## Verdict

**SHIP** — with the Ollama consent-branch fix. All four pass-1 gaps are closed, the build is green, and the remaining items are hardening, not correctness holes on the reviewed paths. Rebase onto `main` first.
