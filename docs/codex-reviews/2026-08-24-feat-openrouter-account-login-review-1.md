---
date: 2026-08-24 12:32
kind: fable-iterate review
review_model: claude-fable-5
review_effort: low
requested_model: claude-fable-5
resolved_model: claude-fable-5
model_substitution: none
job_id: review-20260824T123114-97351
branch: feat/openrouter-account-login
base: main (e2984a1)
reviewed_commit: 1b88789
verdict: SHIP
started_at: 2026-08-24T19:31:14Z
finished_at: 2026-08-24T19:32:33Z
checks: make test → TEST SUCCEEDED, 1702 tests, 5 skipped, 0 failures
total_cost_usd: 1.569489
num_turns: 7
duration_ms: 75039
---

# Review pass 1 — OpenRouter account login

## Prompt

```
Review the complete diff against the requested task. Check correctness, regressions, and test coverage. Give findings by severity and finish with SHIP or NOT READY.

Task: Add OpenRouter account login to MishMail, matching the PKCE flow Pi uses. Users can sign in with an OpenRouter account (browser PKCE that mints a user-controlled API key) from Settings → AI → Subscriptions, without pasting a key. Pasting a key must still work. Tokens/keys stay in the Keychain.
```

## Verbatim review

I checked the full diff and the surrounding auth code. Here is the review.

## Findings

**Low — `localhost` redirect vs. IPv4-only listener.** `LLMOAuth.swift` sets `redirectHost: "localhost"` for OpenRouter. `OAuthService.startLoopbackListener` binds 127.0.0.1 only (`OAuth.swift:252` area). If the browser resolves `localhost` to `::1` first and does not fall back, the callback fails. Most browsers do fall back to IPv4. Other vendors already use the same pattern, so this is not a regression. Evidence: `Sources/MishMail/Support/LLMOAuth.swift:104`, `Sources/MishMail/Auth/OAuth.swift` bind comment.

**Low — API surface allows a weak call.** `startLoopbackListener(expectedState: "", expectedPath: nil)` would accept any state on the shared callback paths. No current caller does this: OpenRouter always pairs the empty state with a unique UUID path (`LLMClient.swift:375-384`). This is a latent misuse risk only. A precondition (`expectedState.isEmpty` requires `expectedPath != nil`) would close it.

**Info — no remote key revocation on sign-out.** The minted OpenRouter key is permanent. Disconnecting the provider deletes it from the Keychain but not from the OpenRouter account. The key stays live server-side. Pi has the same behavior, so this matches the task, but the user is not told.

**Info — model list freshness.** `defaultModel: "openai/gpt-4o"` and the fallback list are static and will age. The "Fetch models" path pulls the live list, so impact is small.

## What I verified as correct

- The CSRF design is sound: no `state`, but an unguessable `/callback/<uuid>` path plus PKCE S256, matching Pi. A hit on a wrong path does not finish the task, and `OAuthLoopbackTests.swift:145` proves it.
- The forged `error=access_denied` protection still holds for state-bearing vendors; the empty-state bypass applies only when the caller opts in.
- The exchange is correct: JSON POST to `/api/v1/auth/keys` with `{code, code_verifier, code_challenge_method}`; `parseTokens` accepts `{key: ...}`, prefers `access_token` when both exist, sets `distantFuture` expiry only for key-style responses, and rejects an empty body.
- Refresh: `performRefresh` is a no-op for OpenRouter, so a 401 retries once and then surfaces (`LLMClient.swift:242-245`); the expiry preflight never fires because of `distantFuture`.
- Existing vendors are untouched: Claude/ChatGPT/Gemini keep non-empty state and default paths; Grok still exits early into the device-code flow, so `usesOAuthState(.grok) == false` has no effect.
- Pasted keys still work: the segmented OAuth/API-key picker remains, and `applyAuth` handles both modes with Keychain-only storage.
- The Gemini-only fallback-model special case in `ProviderEditSheet` was generalized to all OAuth vendors; this is a small behavior improvement, not a regression.
- Test coverage is good: constants, authorize URL shape, exchange form, key parsing, loopback path matching, stateless loopback end-to-end, config round-trip, and store preset all have tests.

I did not run `swift test` because this session is read-only and a build writes to `.build`.

## Open questions

1. Should disconnect tell the user to revoke the minted key at openrouter.ai/keys?
2. Do you want a precondition that forbids empty `expectedState` without an `expectedPath`?

## Suggested fixes (not applied)

- Add a precondition or assert in `startLoopbackListener` for the empty-state case.
- Add one line to the disconnect UI or CHANGELOG about remote key revocation.

## Verdict

**SHIP.** The flow matches Pi, the CSRF stand-in is sound, keys stay in the Keychain, paste mode still works, and tests cover the new paths. The findings are low severity and optional hardening.
