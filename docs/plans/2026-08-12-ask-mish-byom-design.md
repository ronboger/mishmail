# Ask Mish + Bring-Your-Own-Model — Design

Date: 2026-08-12
Status: Approved 2026-08-12 (with send, cost accounting, and follow-up
reminders added at review)
Scope: Phases 1–4. Memory and automations are out of scope (future specs).

## Background

Slashy (slashy.com) is an AI-native Gmail client. We evaluated its feature set.
MishMail already has AI drafts, summaries, triage, ⌘K, snippets, snooze,
scheduled send, and MCP inbox access. The gaps we adopt:

1. **Ask Mish** — an agent chat panel that can read and act on the inbox
   (Slashy calls this "Slashy Chat").
2. **Bring-your-own-model (BYOM)** — the user adds their own API keys and
   picks models per task, like the Aside browser. Slashy routes vendors
   server-side; we keep it local and user-controlled.
3. **Inline AI edits** in compose (rewrite, shorten, change tone).

We skip: open tracking (conflicts with the remote-image privacy stance), CRM
integrations, iMessage agent, team comments, availability links, and any
cloud backend. MishMail stays local-first.

## Decisions (approved 2026-08-12)

- Scope: Phases 1–3 now.
- Providers at launch: Anthropic, OpenAI-compatible, Ollama.
- Grok ships as an OpenAI-compatible preset (`https://api.x.ai/v1`).
- Auth modes: API key, or subscription OAuth sign-in like the Aside browser
  (Claude and ChatGPT accounts).
- Chat surface: right-hand panel in the main split view.
- Agent loop: native Swift, tools routed in-process to `MCPBridge`.
- Phase 1 landed: commits 93d162d..9bde382 (provider layer, OAuth, Settings).

## Phase 1 — LLM provider layer

### Goal

One protocol for all model calls. Three implementations. Keys in the Keychain.

### Components

**`Support/LLMChat.swift` (pure, unit-tested).** Provider-neutral types:

```swift
enum LLMRole { case system, user, assistant, tool }
struct LLMMessage { role, text, toolCalls: [LLMToolCall], toolResults: [LLMToolResult] }
struct LLMToolCall { id, name, argumentsJSON }
struct LLMToolResult { callID, contentJSON, isError }
struct LLMToolSpec { name, description, inputSchemaJSON }
enum LLMEvent { case token(String), toolCall(LLMToolCall), done(stopReason) }
struct LLMProviderConfig { kind, baseURL, modelID, keychainKey }
```

Also pure request/response codecs, one per wire format:
- `AnthropicWire` — Messages API (`/v1/messages`, `tool_use` blocks, SSE).
- `OpenAIWire` — Chat Completions (`/v1/chat/completions`, `tool_calls`, SSE).
- `OllamaWire` — reuse and extend the existing `Ollama.swift` chat path.

Codecs are pure functions `(messages, tools, model) -> URLRequest body` and
`(SSE line) -> LLMEvent?`. This keeps them testable without the network.

**`Support/LLMClient.swift` (app-side).** One `actor LLMClient` that takes an
`LLMProviderConfig`, builds requests with the codec, streams with
`URLSession.bytes`, and yields `AsyncThrowingStream<LLMEvent>`. It follows
`Ollama.generateStream`'s cancellation pattern (`onTermination` cancels the
task). Endpoint rule, same as Ollama today: loopback URLs are always allowed;
remote URLs require HTTPS.

**Auth modes.** Each provider row authenticates one of two ways:

- *API key* — the user pastes a key (default for OpenAI-compatible and
  Anthropic; the only mode for generic base URLs).
- *Subscription OAuth* — "Sign in with Claude" and "Sign in with ChatGPT",
  like the Aside browser. The flow is PKCE with a loopback redirect and
  reuses the patterns in `Auth/OAuth.swift` (state check, port handling,
  browser hand-off). New pure module `Support/LLMOAuth.swift` holds the
  per-vendor constants (authorize URL, token URL, client id, scopes) and
  the token refresh state machine; the app side reuses the existing
  loopback listener approach.
  - Claude sign-in yields tokens that call `api.anthropic.com` with an
    OAuth bearer header instead of `x-api-key`.
  - ChatGPT sign-in follows the Codex-CLI OAuth flow and its chat endpoint.
  - Tokens and refresh tokens live in the Keychain; refresh happens in
    `LLMClient` on 401, single-flight per provider.
  - Vendor OAuth details drift. The implementation plan must verify the
    current constants against Aside/Codex/Claude-Code behavior at build
    time, and the UI must degrade to API-key mode if sign-in breaks.

**Key storage.** One Keychain item per provider account:
`llm.key.<uuid>` via `Keychain.existingOrCreate` semantics (store on save,
`read()` on use, fail closed on `.unavailable`). All Keychain access sits
behind the same fixture-process guard OAuth uses, so demo and UI-test builds
never touch the real Keychain.

**Provider registry.** A small `LLMProviderStore` persisted as JSON in
UserDefaults (`llm.providers`): `[ {id, kind, label, baseURL, defaultModel} ]`.
Secrets never go in UserDefaults; only the Keychain key name is derivable
from `id`. Ollama remains a built-in row that needs no key.

### Settings UI

The existing `AISettings` pane gains a **Providers** section:
- List of configured providers with kind badge and model.
- Add sheet: kind picker (Anthropic / OpenAI-compatible / Ollama), label,
  base URL with presets (`api.anthropic.com`, `api.openai.com`,
  `openrouter.ai/api`, `api.x.ai` for Grok, local Ollama), auth mode
  (SecureField for a key, or a "Sign in with Claude / ChatGPT" button),
  model field with a "Fetch models" button (`/v1/models` or Ollama
  `/api/tags`).
- "Test" button does a 1-token round trip and reports pass/fail.
- Per-task default pickers (used by Phase 3): Drafts, Summaries, Triage,
  Ask Mish. Each picker lists `provider / model` pairs.

## Phase 2 — Ask Mish panel

### Surface

A toggleable right-hand panel hosted by `ContentView` next to the reading
pane, following the split-compose precedent (`ComposePlacement`, frame
preference keys). Pure width/visibility math goes in a new
`Support/AskMishLayout.swift` (added to the `MishMailTests` sources list).
Entry points: toolbar button, ⌘K command "Ask Mish", and a bindable shortcut
in `KeyBindings`.

### Conversation model

New GRDB records + migration (follow `ThreadSummaryRow`):
- `ChatConversation` — id, title, createdAt, updatedAt, providerID, modelID.
- `ChatMessage` — id, conversationID, role, text, toolCallsJSON,
  toolResultsJSON, createdAt.

The panel shows the current conversation, a history menu, and a per-
conversation model picker (Aside-style; defaults from Settings).

### Agent loop

`@MainActor` orchestration on a new `AskMishController` (observable). It is
owned by `MailStore`, so its in-flight task registers in the tracked-task
list and `executeTermination()` cancels and awaits it before the pool closes.

Loop per user turn:
1. Build the message array: system prompt + persisted history + context chips.
2. Call `LLMClient.stream`. Tokens append to the visible assistant bubble.
3. On `toolCall`: dispatch to the tool executor, append the result, and call
   the model again. Cap at 12 tool calls per turn; then the model must answer.
4. Persist the turn.

**Tool executor.** Reuse the MCP layer in-process: the tool list is the
existing `MCPTools.catalog` (schemas already written), and execution calls the
same `MCPToolProvider` methods `MCPBridge` implements. No HTTP, no token. The
provider codecs translate `MCPTools.catalog` JSON schemas into each wire's
tool format (pure, tested).

**Context chips.** "Current thread" chip is on by default when a thread is
selected: it injects the selected thread id and a compact rendering (subject,
participants, latest bodies with head+tail truncation, same policy as
`mcp-summarize.py`). The user can remove the chip.

**Safety.** Tools are split into read and write sets. Read tools
(`search_threads`, `get_thread`, `list_*`) run freely. Write tools
(`create_draft`, `trash_*`, labels, VIPs, summaries) render an inline
confirm card in the chat; the tool result returns only after the user
taps Allow. There is no "always allow" in v1.

**Sending.** Ask Mish gets a `send_draft` tool (Ask Mish–only executor; not
added to the external MCP catalog in v1). The model must create the draft
first, then request send. The confirm card shows To/Cc, subject, and the
full body, and requires an explicit Send tap. Sends go through the normal
`MailStore` send path, so the undo-send window still applies.

**Cost accounting.** `LLMEvent.done` carries usage (prompt tokens,
completion tokens) parsed from each wire format. `ChatMessage` persists
both counts. Cost is computed from a local, editable price table
(`Support/LLMPricing.swift`: per provider/model $ per Mtok in/out, with
shipped defaults and a Settings editor; prices drift, tokens are the
source of truth). The chat UI shows per-message cost on hover and a
running per-conversation total. Subscription-OAuth providers show token
counts only, with no dollar figure. Phase 3 call sites (drafts, summaries,
triage, chips) log usage to a small `llmUsage` table so Settings can show
a 30-day spend summary per task.

**System prompt.** Short, fixed, includes today's date, account emails, and
instructions to prefer search before answering inbox questions.

### Errors

Provider errors surface as an inline chat row with a retry button. Missing
key routes to Settings. Stream cancellation (user taps stop, or panel
closes) keeps the partial text and marks the turn interrupted.

## Phase 3 — retarget existing AI features

- `ComposeView.draftWithAI()`, `ThreadDetailView.summarizeThread()`, and
  `MailStore.classify…` call `LLMClient` with their per-task provider/model
  from Settings. Prompt builders move from `Ollama.swift` statics to
  `LLMChat` (pure).
- Default per-task selection stays on Ollama, so behavior is unchanged until
  the user picks a hosted model.
- **Inline AI edits:** compose selection gains Rewrite / Shorten / Change
  tone actions that stream a replacement for the selected text through the
  Drafts task model. Reuses `draftWithAI`'s streaming-into-editor plumbing.
- **Quick-reply chips:** the thread detail view offers up to three short
  reply suggestions for the latest inbound message (e.g. "Interested",
  "Need more details"). One model call per selected thread, on demand (a
  small "Suggest replies" affordance near the reply box — not automatic,
  to avoid background token spend). Tapping a chip opens compose with the
  suggestion expanded into a full draft in the user's voice, using the
  Drafts task model. Chip generation uses the Triage task model (cheap).
  Pure suggestion parsing/validation lives in `Support/` with tests.
- `Ollama.swift`'s public surface stays until all call sites move; then the
  prompt statics are deleted.

## Phase 4 — follow-up reminders

No LLM involved. Track sent threads that got no reply.

- New GRDB record `FollowUpReminder`: id, threadID, accountEmail,
  sentMessageID, dueAt, state (`pending`, `fired`, `dismissed`, `replied`).
- Creation: a "Remind me if no reply" control in compose and on sent
  threads, with a default interval in Settings (e.g. 3 days). Off by
  default; no auto-tracking in v1.
- Clearing: the sync engine marks a reminder `replied` when a newer inbound
  message arrives on the thread from someone other than the sender.
- Firing: the existing due-sweep pattern (`dueSweepTask`, like snooze)
  moves due reminders to `fired`, posts a notice, and badges a
  "Follow-ups" sidebar section listing fired and pending reminders.
- Pure due/clear logic in `Support/FollowUpPolicy.swift` with tests.

## Testing

- Codec round-trip tests per wire format (request body, SSE parse, tool
  translation) — pure, in `MishMailTests`.
- `LLMProviderStore` persistence and Keychain-name derivation tests.
- Agent-loop tests with a scripted fake provider: tool-call dispatch, cap
  enforcement, write-tool confirmation gating, cancellation.
- Layout math tests for the panel.
- Migration test additions for the chat, usage, and reminder tables.
- Usage parsing per wire format; pricing math; follow-up due/clear policy.
- Send-tool gating: no send without a confirmed draft and an explicit tap.
- Manual pass: each provider kind against a real endpoint; demo-mode build
  must run with zero Keychain prompts.

## Non-goals (v1)

- Memory system and automations (future specs).
- Attachment upload to models; image inputs.
- Auto-tracking every sent mail for follow-ups (opt-in per message in v1).
