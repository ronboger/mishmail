# Thread share: Markdown export, Obsidian, Notion — Design

Date: 2026-07-11  
Status: P0 implemented; P1–P3 proposed  
Author: Ron + Grok

## Motivation

People want to file an email thread into their notes system — same instinct as
Notion Mail’s “Add to Notion,” but MishMail is a third-party client. We need a
**destination model**, not a product deep link.

Ron’s own agent stack already has Notion/Gmail MCPs; those stay agent-side.
In-app share is for humans clicking a button.

## Goals

1. One canonical export format (Markdown) that every destination reuses.
2. Zero-config path that works offline and needs no credentials (P0).
3. Optional destinations (Obsidian folder, Notion API) that match MishMail’s
   local-first / user-owned-credentials ethos.
4. No MCP runtime inside the app.

## Non-goals

- Embedding an MCP client or spawning `npx` servers.
- Bidirectional sync (Notion page updates ↔ Gmail).
- Full HTML fidelity / tracking of open state in destinations.
- Shipping bundled Notion OAuth client secrets.

## Approaches considered

| Approach | Verdict |
|---|---|
| **A. MCP destinations** | Rejected for product UI — agent protocol, sandbox/distribution pain. Fine for Claude/Grok agents outside the app. |
| **B. Markdown core + pluggable destinations (chosen)** | Pure exporter; UI always offers Copy/Save; later destinations implement one protocol. |
| **C. System share sheet only** | Insufficient alone (no structured Markdown); can wrap P0 later. |
| **D. Notion-only deep integration** | Wrong for multi-tool users; Obsidian is filesystem-first. |

## Architecture

```
Thread + messages + attachment names
        │
        ▼
 ThreadExporter.markdown(...)     ← pure, unit-tested (Support/)
        │
        ▼
   destinations
   ├── Clipboard          (P0)
   ├── Save panel → .md   (P0)
   ├── Obsidian folder    (P1)
   ├── Notion API page    (P2)
   └── Shortcuts / Notes  (P3)
```

### Protocol (later destinations)

```swift
protocol ThreadDestination {
    var id: String { get }
    var title: String { get }
    func send(markdown: String, meta: ThreadExportMeta) async throws
}

struct ThreadExportMeta {
    var subject: String
    var threadId: String
    var accountId: String
    var messageCount: Int
    var suggestedFilename: String
}
```

P0 does not need the protocol yet — call sites use `ThreadExporter` directly.

## Phases

### P0 — Markdown Copy / Save (done)

- `Support/ThreadExporter.swift`: subject, per-message From/To/Cc/date, body
  (text preferred; HTML strip fallback with anchors → `[text](href)`),
  attachment filenames.
- `suggestedFilename` → `YYYY-MM-DD-slug.md`.
- Thread toolbar **⋯** menu: **Copy as Markdown**, **Save as Markdown…**.
- Save write failure: clipboard fallback **plus** `NSAlert` (never silent).
- Bodies hydrated before export (same pattern as Summarize).
- Tests: `ThreadExporterTests`.

### P1 — Obsidian (filesystem)

- Settings → Integrations (or Appearance): “Obsidian inbox folder”.
- Persist a **security-scoped bookmark** for the user-selected directory
  (App Sandbox). Resolve with `bookmarkDataIsStale`; re-save when stale;
  re-prompt the folder picker when resolution fails. Wrap access in
  `startAccessingSecurityScopedResource` / `stopAccessing…`.
- Destination writes `suggestedFilename` into that folder; optional
  frontmatter (`date`, `from`, `gmail_thread_id`).
- UI: ⋯ menu item **Send to Obsidian** when a folder is configured.
- No Obsidian plugin required — vault watch does the rest.

### P1.5 — Per-sender image allowlist (related; not share)

Remote image policy ships as Ask / VIP / Always. VIP reuses the importance
list, which is a weak proxy for “I trust this sender’s tracking pixels”
(newsletters/receipts are the opposite of VIP). Follow-up:

- Load images menu item: **Always from this sender**
- Separate allowlist (not VIP), checked in `RemoteImagePolicy.allows`
- Settings: view/edit the allowlist

Out of scope for share P1; noted so the policy design stays composable.

### P2 — Notion (REST)

- Settings: Integration token (Keychain) + parent page or database ID.
- Keychain: `kSecAttrAccessibleAfterFirstUnlock` + this-device-only (same
  class as other secrets).
- Create a page with Markdown body (Notion’s markdown/block conversion or
  simple paragraph blocks). Exported Markdown is **untrusted email content** —
  treat as text only; never interpolate into URL or API-path shaped strings.
- Privacy copy: “Thread content leaves this Mac.”
- Failures: clear toast / alert; never silent drop.
- Idempotency: always create a **new** page (no stored page-id map in P2).

### P3 — Polish

- Export **this message only** from the message card menu.
- Attachment files written beside the `.md` (Obsidian) or uploaded (Notion).
- “Run Shortcut…” / Apple Notes via `NSSharingService` or URL schemes.
- Optional keyboard shortcut for Copy as Markdown.
- Async body hydration for large threads (export currently matches Summarize’s
  main-thread hydrate — fine for P0, worth fixing when destinations make
  export more frequent).

## Export format (contract)

```markdown
# Subject

_N messages_

## Alice · Jul 11, 2026 at 10:42 AM

**From:** Alice <alice@x.com>
**To:** me@y.com

Body text…

**Attachments:**
- deck.pdf

---

## Bob · Jul 11, 2026 at 11:05 AM
…
```

Rules:

- Prefer `bodyText`; if empty, strip `bodyHTML` (scripts/styles dropped;
  block tags → newlines; `<a href>` → Markdown links).
- Do not re-fetch remote images for export.
- Attachment binaries out of scope until P3.

## UI placement

| Action | Where |
|---|---|
| Copy / Save Markdown | Thread ⋯ menu (P0) |
| Send to Obsidian / Notion | Same menu, only if configured (P1/P2) |
| Settings for destinations | New **Integrations** pane when P1 lands |
| Per-message export | Message card menu (P3) |

## Security

- Clipboard and local file write only for P0 (sandbox user-selected write).
- P1: security-scoped bookmarks with stale handling + start/stop access;
  revoke on folder clear.
- P2: token in Keychain (`AfterFirstUnlock`, this-device-only); HTTPS only;
  no logging of body content; untrusted-content hygiene when building blocks.
- Destinations never weaken HTML-mail CSP in the reading pane.

## Testing

- Pure exporter unit tests (P0) — hostless target.
- P1/P2: fake destination protocol tests; optional integration behind flags.
- UI paths untested (same as rest of ThreadDetailView).

## Open questions

1. Notion: parent **page** vs **database** first? (Database needs property map.)
2. Frontmatter dialect for Obsidian (YAML keys)?
3. Should Copy as Markdown get a KeyBindings entry or stay menu-only?
4. ~~When export fails mid-write, is clipboard fallback enough?~~ **Resolved:**
   clipboard fallback + `NSAlert` (P0).

## Implementation notes (P0 files)

- `Sources/MishMail/Support/ThreadExporter.swift`
- `Sources/MishMail/UI/ThreadDetailView.swift` (⋯ menu + pasteboard / save panel)
- `Tests/MishMailTests/ThreadExporterTests.swift`
- `project.yml` — exporter on MishMailTests sources list
