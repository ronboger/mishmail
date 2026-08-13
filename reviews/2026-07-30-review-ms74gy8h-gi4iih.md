# review: Review working tree diff

- Job: review-ms74gy8h-gi4iih
- Kind: review
- Workspace: /Users/ronboger/mishmail
- Started: 2026-07-30T06:18:08.101Z
- Completed: 2026-07-30T06:21:55.279Z
- Codex session: 019fb1ac-549b-7cf1-b998-493959e6e056

---

# Codex Review

Target: working tree diff

The WebKit completion-handler signature causes a compile failure. The asynchronous recycling change also allows memory-pressure drains to be undone by delayed callbacks.

Full review comments:

- [P1] Pass a zero-argument removal callback — /Users/ronboger/mishmail/Sources/MishMail/Support/WebViewPool.swift:252-254
  This does not compile against WebKit: `WKWebsiteDataStore.removeData` expects a `() -> Void` completion handler, but the closure declares one argument with `{ _ in ... }`. Use a zero-argument closure so the application can build.

- [P2] Prevent pending wipes from refilling a drained pool — /Users/ronboger/mishmail/Sources/MishMail/Support/WebViewPool.swift:181-185
  If memory pressure calls `drain()` while this asynchronous wipe is pending, its completion subsequently invokes `parkFreeIfRoom` and repopulates the pool because no drain generation is checked. This retains up to three heavyweight web views immediately after they were explicitly released; pending park callbacks should be invalidated when the pool is drained.
