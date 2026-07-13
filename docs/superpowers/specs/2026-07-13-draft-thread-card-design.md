# Draft cards in the thread — Design

Date: 2026-07-13  
Status: implemented on `feat/draft-thread-card`

## Problem

After writing a reply draft and closing compose, the reading pane showed the
draft as a normal `MessageCard`:

1. **Huge empty gap** between authored text and the "…" quoted-trail pill —
   full HTML body (including collapsed `gmail_quote`) measured via
   `scrollHeight`, which often mirrored the WKWebView frame height rather than
   visible content.
2. **Edit only at the top** — "Edit Draft" / "Delete Draft" lived above the
   message list, not next to the draft at the bottom of the conversation.
3. **No draft cue** — the bottom card looked like a sent message (Reply /
   Forward, no "Draft" / "Not sent" chrome). Gmail and Notion Mail both mark
   unsent drafts distinctly.

## Solution

Treat DRAFT-labeled messages as first-class UI, not ordinary message cards.

### DraftMessageCard (bottom of thread)

- Orange **Draft** pill + **Not sent** label
- Left orange accent rail + warm stroke (Gmail-ish, not a full red banner)
- Compact **authored preview** only (`QuotedReply.authoredPreview`) — plain-text
  split first, HTML strip above `gmail_quote` as fallback
- No HTML webview, no "…" quote trail, no Reply/Forward
- **Continue** (primary) / **Discard** on the card; whole card clickable →
  `editDraft(inThread:)`

### Slim top banner

Shown only when `messages.count > 3` — short threads already show the draft
card in the first viewport, so a second orange affordance is noise. Long
threads open near the top; without a cue users might miss the draft.

### Supporting fixes

- Expand + scroll-anchor the newest **non-draft** message
  (`ForwardComposer.newestSentMessage`)
- **All** reply paths share that resolver: keyboard `r`/`a`/`f`, command
  palette, reading-pane toolbar
- `editDraft(_: Message)` / `deleteDraft(_: Message)` act on the card's
  message; `confirmingDraftDelete` holds a `Message?`
- Quote-only authored preview → empty (empty-draft UI), not the trail
- HTML body measure uses visible child bottoms (display:none quotes contribute 0)
- Hover cursor cleaned up on `onDisappear` (discard-under-cursor)
- Preview has no `.textSelection` (card is tap-to-edit)

## Non-goals

- Inline compose docked inside the reading pane (compose still docks bottom-right)
- Multi-draft simultaneous edit UX beyond "last draft wins" (existing store API)
- Changing draft-only-thread open behavior (still hops straight into compose)

## Files

- `Sources/MishMail/UI/ThreadDetailView.swift` — `DraftMessageCard`, wiring
- `Sources/MishMail/Gmail/MessageParsing.swift` — `QuotedReply.authoredPreview`
- `Tests/MishMailTests/QuotedReplyTests.swift` — preview unit tests
- `CHANGELOG.md`
