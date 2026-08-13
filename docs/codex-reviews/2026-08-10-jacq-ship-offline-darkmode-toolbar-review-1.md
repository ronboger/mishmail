# Review: offline banner / dark-mode CTA / toolbar placement

- **Date:** 2026-08-10 00:10
- **Branch:** jacq/ship-20260809T234741-74530
- **Reviewed commit:** 55f2a84 (HEAD; base 9a8a31b main)
- **Implementer model:** grok-4.5
- **Grok jobs:** ship-20260809T234741-74530, rescue-20260809T235936-81596
- **Verdict:** SHIP

## Scope

Three user-reported bugs:
1. Frequent "offline" error banner.
2. Dark-mode colors wrong on designed HTML mail (TimeTap green CTA).
3. Detail-pane nav buttons (hide pane / prev / next) rendered top-left over the sidebar on macOS 26.

## Commits

| SHA | What | Author |
|-----|------|--------|
| 93b54fa | silence transient offline errors on background sync | grok |
| ded5a8c | keep authored colors on mid-tone CTA anchors in dark mode | grok |
| b312318 | detail nav buttons `.navigation` → `.principal` + `.toolbarRole(.editor)` | grok |
| 3a71821 | extract TransientNetworkError helper into test bundle (rescue) | grok |
| 55f2a84 | fix test anchor: search `.mm-fg-on-*:not(` past CSS comment mentions | Claude (supervisor) |

## Review notes

**Issue 1 (MailStore):** `syncAll(interactive:)` defaults to true; timer tick and
didBecomeActive catch-up pass false. Transient URLError codes (notConnected,
connectionLost, timedOut, cannotConnect/FindHost, dnsLookupFailed, dataNotAllowed;
walks NSUnderlyingErrorKey) are swallowed on non-interactive syncs. Sync-failure
banners are tagged with the account id and cleared on that account's next success;
the `lastError` setter resets the tag so send/draft errors are never auto-cleared.
Correct and minimal. Grok's first pass had a compile error (`URLError.Code(rawValue:)`
treated as failable) — fixed by supervisor; rescue moved helpers into
`Support/TransientNetworkError.swift` so the test bundle can compile them
(this repo's test target compiles sources directly, no app module).

**Issue 2 (HTMLBodyDarkMode):** new `mm-keep-authored` class stamped by the
contrast JS on anchors that own (or contain, within the anchor) an opaque
mid-tone fill (luminance 0.18–0.72). All forced link/fg color rules gained
`:not(...)` exclusions for that class, so authored white-on-green CTA text
survives. Specificity math checked: attribute rule and fg-class rules both gain
the same `:not(:is(a.cls, a.cls *))` term, so source-order still resolves the
Google-welcome case the existing tests guard. Thresholds mirrored Swift↔JS as
before. Grok broke one existing test by weakening its search anchor (matched a
CSS comment); supervisor fixed the anchor (`.mm-fg-on-*:not(`), second grok test
miss — noted per workflow.

**Issue 3 (ThreadDetailView):** placement `.navigation` → `.principal` with
`.toolbarRole(.editor)`; buttons/help/conditionals/`pmHideSharedBackground`
and macOS 26 spacers preserved. **Visually verified** in the Debug build
(demo inbox, reading-pane layout, 2000×1150): the »/^/v trio renders at the
leading edge of the detail column, no longer over the sidebar. Also checked
full-window thread style: trio sits center-left of the toolbar, usable.

## Tests

`make test`: **1358 tests, 0 failures (1 skipped)** after `make build`
(three Update* tests verify the built app and need a fresh build in the
worktree — they pass on main and after rebuilding; environmental, not a
regression). Grok could not run tests in its sandbox (SPM sandbox-exec
denied); all verification done by supervisor.

## Not verified

- Real-mail rendering of the TimeTap email (unit tests + logic review only;
  the demo inbox has no colored-CTA fixture).
- Offline behavior end-to-end (would need a real network drop).
