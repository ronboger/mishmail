# Mark-read dwell — higher-level harness (deferred)

**Status:** not required for ship. Branch `feat/mark-read-dwell` landed with
pure-policy coverage; Fable re-review after the live-row fix was **ship**.

## What already covers the risk

- `MarkReadOnOpen.shouldMarkRead(selectedId:threadId:liveIsUnread:)` — `nil`
  live unread means abort (never fall back to a pre-open snapshot).
- `testMissingLiveRowDoesNotMarkRead` — selection still on the archived id +
  missing list row must not mark-read (the last-row archive race).
- `ThreadDetailView` dwell path requires a live `store.threads` row and passes
  that `liveThread` into `setRead` (avoids resurrecting `inInbox` / clobbering
  star/label/sync during the 1s window).

## Why not a full MailStore / UI harness now

- `MailStore` is AppKit-bound and is **not** in the hostless `MishMailTests`
  target (see `project.yml` + backlog constraints). A real sequence test needs
  either an extracted store surface or an app-host UI test.
- Residual risk is mostly “a future caller reintroduces a snapshot fallback
  *before* calling the helper” — code review on the open path, not missing
  policy coverage.
- Injected clock / fake store only pays off when this area keeps changing.

## When to add it later

Add a higher-level regression **if any** of:

1. You extract a testable open/mark-read coordinator (or store protocol) with
   an injectable clock / dwell.
2. More call sites share the same dwell (preview pane, configurable delay,
   trash/spam also force-read, etc.).
3. A real regression shows up in the archive-at-dwell-boundary race.

## Suggested harness shape (when ready)

Prefer pure/store-level over full UI:

| Case | Assert |
|------|--------|
| Final visible row archived during dwell | row stays out of inbox; no stale `setRead` |
| Selection leaves mid-dwell | no mark-read |
| Mixed bulk archive | all targets lose UNREAD; undo restores INBOX only, stay read |
| `is:unread` + archive + undo | stickiness / pin order still correct |

Do **not** block shipping mark-read dwell on building this harness first.

## Related

- Policy: `Sources/MishMail/Support/MarkReadOnOpen.swift`
- Dwell call site: `ThreadDetailView` `.task(id: thread.id)`
- Immediate path: `MailStore.archive` / `archiveChecked` (remove INBOX + UNREAD)
- Tests: `Tests/MishMailTests/MarkReadOnOpenTests.swift`
