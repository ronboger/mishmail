# Compose: draft status, inline reply, thread focus — Design

Date: 2026-07-14  
Status: implemented on `feat/compose-inline-draft-focus`

## Problem

Three related reading/compose friction points:

1. **Close is confusing** — the footer "Close" button saves a draft (it does
   not cancel), but the label reads as "discard and leave." Notion Mail
   instead surfaces a live **Draft saved** status in that chrome area.
2. **Floating compose occludes the thread** — Reply always opens the docked
   bottom-right card, which covers the reading pane you need to reference.
3. **No full-width thread mode** — Esc / ⌥⌘0 hide the pane, but there is no
   quick way to expand the conversation across the whole app chrome.

## Solution

### 1. Autosave + "Draft saved" status

- Debounced Gmail draft autosave (~1.5s after last edit) while compose is open.
- Footer replaces the text **Close** control with status:
  - empty / no content → nothing (or idle)
  - dirty → (brief) then **Saving…**
  - success → **Draft saved**
  - failure → short error (existing `lastError` path still works)
- Header **✕** remains the dismiss control; tooltip: "Save draft & close"
  when there is content. Esc still save-and-closes (expanded only).
- Autosave is **silent** (no bottom toast); explicit close may still be quiet
  if already saved. Demo mode shows status locally without API calls.
- `createDraft` returns the new draft/message ids so subsequent autosaves
  replace the live draft instead of stacking duplicates.
- **Live draft chain** — `replacingDraft` (updated on each successful save)
  is the single source of truth for Send (`PendingSend.replacingDraft`),
  Discard (trash), and the next autosave replace. Never use only the original
  `editDraft` after autosave has run.
- **Serialized persist** — one in-flight save at a time; further edits
  re-run after it completes (latest-wins). Send/Discard await idle first.
- **Dismiss** awaits a non-silent final save (errors via `lastError`) and
  syncs so the Drafts list matches Gmail. Demo never claims "Draft saved".
- **Undo-send baseline** — `request.restore` wins over `editDraft` when both
  are set (common after autosave-then-send); fingerprint stays dirty so Esc
  re-saves the full restore body, not just the last autosaved snapshot.
- **Finish re-entry guard** — `beginFinish()` sets `didFinish` before any
  await on Send / Schedule / Discard / Close so double-⌘↩ cannot queue two
  sends while persist is in flight.

### 2. Inline reply in the reading pane

- **Reply / Reply all / Continue draft** for the *currently open* thread open
  compose **inline** at the bottom of the reading pane (full pane width),
  not as the floating card. Placement uses PreferenceKey-measured frames
  (host + reading pane in global space) with a layout-mode fallback before
  first layout; the detail column reserves bottom safe area so the thread
  scroll doesn't hide under the card.
- **New message**, **Forward**, draft-only hop (no reading pane), and any
  compose whose thread ≠ selected thread stay **floating**.
- Inline chrome: no minimize strip; **Pop out** promotes to the floating card
  if the user wants the old layout.
- Hiding the reading pane or leaving the thread promotes inline → floating
  (work is not discarded).
- Keyboard `r` / `a` use the same placement rule when a thread is selected
  and the reading pane is visible.

### 3. Thread focus mode (⌘↩)

- When a conversation is selected and expanded compose is **not** claiming
  ⌘↩ for **Send**, **⌘↩** toggles **thread focus mode**:
  - sidebar + list hidden; reading pane fills the window.
- **Esc** exits focus mode first (before hide-pane / clear-selection ladder).
- Toolbar: optional affordance via existing reading-pane control is enough for
  v1; shortcut is the primary entry.
- Does not change single-key `j`/`k` thread navigation while focused (list is
  hidden but selection still moves; detail rebinds to the new selection).

## Non-goals

- Multi-compose windows / simultaneous drafts in two panes.
- Continuous local-only drafts without Gmail (except demo notice).
- Changing Send (⌘↩ while expanded compose is up still sends).
- Redesigning the floating card elevation / size for new mail.

## Files

- `Sources/MishMail/Support/ComposePlacement.swift` — pure placement + layout helpers
- `Sources/MishMail/Support/MailLayout.swift` — focus mode layout
- `Sources/MishMail/Gmail/GmailClient.swift` — createDraft returns ids
- `Sources/MishMail/App/MailStore.swift` — presentation, focus, silent save
- `Sources/MishMail/UI/ComposeView.swift` — autosave status, inline chrome
- `Sources/MishMail/UI/ContentView.swift` — overlay gating, focus layout, ⌘↩
- `Sources/MishMail/UI/ThreadDetailView.swift` — inline dock
- `Tests/MishMailTests/ComposePlacementTests.swift`, `MailLayoutTests.swift`
- `CHANGELOG.md`
