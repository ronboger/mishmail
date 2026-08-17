# Ask Mish polish — design

Date: 2026-08-16. Approved by Ron in chat.

## Scope

1. **Fix toggle jank.** The Ask Mish toolbar button (⌥⌘M) animates the whole
   window `HStack`. The animated width change re-renders every `WKWebView` in
   the thread detail and can flip the layout mode. Fix: scope the animation to
   the panel only, keep the detail width stable during the slide, drop the
   mid-animation `@State` write, and do not let the panel width flip
   `MailLayout.mode` mid-toggle.

2. **Multi-thread attach.** Add a "+" next to the current-thread chip in the
   Ask Mish composer. It opens a popover with a search field backed by
   FTS5 (`ThreadTypeahead`). Selecting a thread attaches it: the controller
   keeps a set of injected thread IDs and emits one context message per
   thread via `ThreadExporter.markdown` + `AskMishContext.contextMessage`.
   Also add a model-side `attach_thread` tool so the model can pin a thread
   it found with `search_threads`. No embeddings/RAG — FTS5 is enough now.

3. **Provider → model submenu.** Replace the flat model menu in
   `AskMishPanelView` with a two-level menu like Aside: provider row → submenu
   of that provider's models. Curate lists: use the provider's stored/known
   models; cap very long lists (OpenRouter) to a curated subset so selection
   stays legible.

4. **Gemini free tier.** Working-tree changes already add the `.gemini`
   vendor, presets, pricing, and Settings wiring. Verify with tests, commit,
   and ensure Gemini models appear in the new picker. Leave OAuth subscription
   sign-in out of the UI (the OpenAI-compat endpoint rejects Google OAuth
   tokens).

## Non-goals

- Embedding store / semantic search.
- Gemini-native wire codec or Cloud Code Assist OAuth endpoints.

## Testing

- Unit tests for: attach-set context assembly (AskMishContext/Controller),
  picker entry grouping/curation, Gemini endpoint path + preset tests
  (already in working tree).
- Manual: toggle Ask Mish with a heavy thread open; attach two threads and
  ask a cross-thread question; select a Gemini model and chat.
