# MishMail interaction, auth, draft, and memory polish plan

Date: 2026-07-16

Status: implemented on `codex/mishmail-interaction-polish`. This pass ships
the low-risk viewport animation fix and measured-height fallback; Fable should
specifically assess whether the larger scroll-position restore model described
in PR 3 is still necessary after hands-on testing.

## Outcome

Make MishMail feel as immediate as Finder for keyboard browsing, eliminate the
reply-composer jump and the draft ghost during Undo Send, explain and reduce
reauthorization prompts, reduce WebKit process/memory cost, and make participant
headers consistent at narrow widths.

## What the inspection found

| Symptom | Likely cause | Direction |
| --- | --- | --- |
| Inline reply jumps upward | The composer is mounted in a global overlay while the reading pane independently adds a bottom safe-area reserve. A top-anchored `scrollPosition`, late WebView height updates, and repeated re-pins can all write the scroll position during the same transition. | Give the reading pane sole ownership of the composer and scroll state; perform one non-animated pin after layout and stop immediately on user scroll. |
| Every account asks to reauthorize | The README says to leave the Google OAuth app in Testing and incorrectly says Gmail refresh tokens do not expire there. Google says External + Testing refresh tokens expire after seven days when non-basic scopes are requested; MishMail requests Gmail scopes. Accounts authorized together expire together. | Correct setup/docs and explain the reason in-app. Separately distinguish a genuinely missing/revoked token from a temporarily inaccessible Keychain item. |
| Holding Down feels slow | Every selection change publishes through the whole app, starts/cancels neighbor database prefetch, and can rebuild/hydrate the visible reading pane. The visual list highlight and the expensive open-thread state are the same ID. | Split immediate list focus from the opened detail selection; debounce/coalesce detail work and prefetch until navigation settles. |
| Draft remains in the thread during Undo Send | Undo Send intentionally delays the Gmail send for ten seconds. The underlying Gmail draft is not deleted until the delayed send commits, so the local draft card remains visible. | Optimistically suppress the draft from MishMail views during the pending window without deleting it from Gmail; restore it on Undo or failure. |
| Many MishMail Web Content / Graphics / Helper processes | Every expanded HTML card can own a `WKWebView`, and the recycle pool retains up to three more. WebKit also uses separate content, GPU, and networking processes by design. | Allow one live HTML renderer per reading pane, retain at most one warm renderer, drain it under memory pressure, and reduce duplicate HTML document construction. Some WebKit helpers will remain while HTML mail is supported. |
| Bare-email contact header looks misaligned | The compact header uses a different layout from the expanded `Grid`; the long recipient wraps while the disclosure glyph is centered against the multi-line block. | Reuse a fixed-column participant row in both states, keep a bare address on one line with middle truncation, and put the glyph in its own optically aligned fixed frame and 40×40 hit target. |

Google references:

- [OAuth refresh-token expiration](https://developers.google.com/identity/protocols/oauth2#expiration)
- [Testing audience behavior](https://support.google.com/cloud/answer/15549945)

## Important branch note

`fix/inline-reply-scroll` already contains four rounds of scroll work
(`278391a` through `4cb19b4`), but it is not on `main`. It is 670 changed lines
and predates current `main` changes such as the eager message stack, HTML
rendering hardening, and delayed mark-read behavior. Do not merge it wholesale.
Port its tested placement math, restore-point model, and user-scroll disarm
behavior onto current `main`, then delete the superseded overlay logic.

## PR 1 — Fix OAuth guidance and error classification

### Product behavior

1. Correct README and onboarding:
   - Remove the claim that Testing-mode Gmail refresh tokens do not expire.
   - Explain that Testing mode normally means reauthorization after seven
     days for MishMail's Gmail scopes.
   - Recommend moving a personal OAuth consent screen to In production when
     Google/account policy permits; otherwise make the seven-day tradeoff
     explicit.
2. Add an account-level reason under the Reauthorize button:
   - `Expired or revoked by Google`
   - `No token found in this MishMail build`
   - `OAuth client changed`
   - `Keychain temporarily unavailable — unlock Mac and retry`
3. If several accounts fail with `invalid_grant` in one sync pass, show one
   consolidated explanation instead of repeating a generic error.

### Engineering

1. Change `Keychain.get` from `String?` to a typed result that preserves
   `OSStatus`. Only `errSecItemNotFound` means the token is absent. Do not
   convert `errSecInteractionNotAllowed`, access-control failures, or a locked
   Keychain into a reauthorization request.
2. Save non-secret token metadata: issuing OAuth client-ID fingerprint,
   authorization date, and granted account. This makes a client change
   diagnosable without logging any token.
3. Keep `invalid_grant` as a per-account terminal refresh error, but never
   include Google's raw response body or credentials in logs.
4. Explain Debug versus Release isolation: they intentionally use different
   bundle IDs, databases, and Keychain services.

### Tests and acceptance

- Unit-test `errSecItemNotFound` versus transient/locked/access-control statuses.
- Unit-test multi-account failure consolidation and client-ID mismatch.
- A temporary Keychain access failure offers Retry, not Reauthorize.
- A Testing-mode expiration explains the seven-day rule and identifies only
  the affected accounts.

Primary files: `Support/Keychain.swift`, `Auth/OAuth.swift`,
`App/MailStore.swift`, `UI/SettingsView.swift`, `UI/OnboardingView.swift`,
`README.md`.

## PR 2 — Make pending-send draft visibility a state machine

### Product behavior

The moment Send is pressed:

1. Close the composer.
2. Hide its draft card/banner and remove its Drafts-list representation.
3. Keep the existing `Sending… Undo` affordance.
4. Do not delete the Gmail draft during the Undo window.

On Undo or send failure:

1. Remove suppression before reopening compose.
2. Restore the exact recipients, body, attachments, From identity, and live
   autosaved draft.
3. Never show both a draft card and an open composer for the same draft.

On successful send:

1. Delete/replace the Gmail draft through the existing send path.
2. Clear suppression after local sync has reconciled the sent message.

### Engineering

- Add a small pure `PendingDraftVisibility` policy keyed by stable local
  message ID.
- `queueSend` suppresses `PendingSend.replacingDraft`.
- Thread-header fetches, draft banners, Drafts lists, and draft-only routing
  all consult the same suppression source.
- `cancelPendingSend`, `performSend` failure, a second queued send, and app
  termination explicitly transition the state; avoid view-local ad hoc flags.
- Bump `threadContentVersion` so an already-open thread removes the card
  immediately.

### Tests and acceptance

- Existing draft → Send → card disappears in the same run-loop turn.
- Fresh reply that autosaved → Send behaves the same way.
- Undo restores one composer and no duplicate card.
- Network failure restores the draft.
- A second send flushes the first without leaking suppression.
- Relaunch/sync cannot permanently hide a real remote draft.

Primary files: `App/MailStore.swift`, `UI/ThreadDetailView.swift`,
`Support/ThreadRefresh.swift`, plus a pure helper and hostless tests.

## PR 3 — Replace competing inline-compose layout ownership

### Recommended structure

Mount the inline `ComposeView` inside `ThreadDetailView`'s reading-pane layout,
not in `ContentView`'s global overlay. The reading pane should own:

- the thread viewport;
- the fixed composer height;
- the single restore point;
- the one programmatic scroll to reveal the reply target;
- the user-scroll disarm state.

This removes cross-tree frame preferences and prevents the overlay and
`safeAreaInset` from racing each other.

### Scroll rules

1. Capture the current top message/content position before changing layout.
2. Apply the composer height with animations disabled for layout properties.
3. Scroll once, after layout, only when the reply target would otherwise be
   covered.
4. A late HTML height change may perform at most one small corrective pin while
   still armed.
5. Any wheel/trackpad gesture immediately and permanently disarms auto-pin for
   that compose session.
6. Dismiss restores the captured reading position without animation.
7. If a truly zero-motion result is more important than a fixed dock, fallback
   to rendering the reply composer as the final item in the thread's scroll
   content; adding content below the viewport cannot push existing content up.

### Reuse from `fix/inline-reply-scroll`

- `InlineScrollRestore`
- offset-based user-scroll disarm, with the macOS 14 wheel fallback
- monotonic measured composer/reserve height tests
- single-message top restore
- zero-height pane fallback to floating compose

Preserve from current `main`:

- eager stack behavior used to avoid WebView geometry churn;
- delayed/cancellable mark-read;
- current HTML rendering and remote-image hardening.

### Tests and acceptance

Build a deterministic UI harness covering:

- single plain-text message;
- multi-message thread;
- tall HTML that reports height late;
- open, type, resize window, dismiss;
- user scroll during the settle window;
- compact, three-pane, and focus layouts;
- macOS 14 fallback and macOS 15+ offset observation.

Budgets:

- no second visible correction larger than 4 px after the first 150 ms;
- no programmatic movement after a user scroll;
- dismiss restores within 2 px when the underlying content did not change;
- no spring animation on scroll or composer-height changes.

Primary files: `UI/ThreadDetailView.swift`, `UI/ContentView.swift`,
`Support/ComposePlacement.swift`, `Tests/.../ComposePlacementTests.swift`,
UI tests.

## PR 4 — Finder-speed keyboard browsing

### State model

Split the current selection into:

- `focusedThreadId`: the list highlight; updated synchronously for every arrow
  or `j`/`k` repeat;
- `openedThreadId`: the reading pane's expensive content selection.

Behavior:

1. Arrow/key repeat changes only `focusedThreadId`, with no animation or I/O.
2. Enter opens immediately.
3. If live preview while the pane is visible is desired, update
   `openedThreadId` after a short quiet period (roughly 60–90 ms), coalescing
   repeats to the latest row.
4. Schedule neighbor body prefetch only after `openedThreadId` settles, not in
   every `selectedThreadId.didSet`.
5. Maintain an ID→index map when `displayOrder` changes so movement does not
   scan the array on every repeat.
6. The native list should scroll the focused row into view without animating
   intermediate repeat events.

### Measurement and acceptance

Add signposts from key-down to focus publication and from settled selection to
detail-ready:

- key-down → row highlight p95 under one 60 Hz frame (16.7 ms);
- holding Down for 30 rows does not drop or reorder events;
- no body hydration, WebView navigation, or database prefetch per intermediate
  repeat;
- arrow keys and rebound `j`/`k` share exactly the same path;
- VoiceOver selection announcements remain correct.

Primary files: `App/MailStore.swift`, `UI/ContentView.swift`,
`UI/ThreadListView.swift`, `Support/NeighborPrefetch.swift`, performance and
selection tests.

## PR 5 — Bound WebKit processes and memory

### Set expectations

WebKit deliberately runs HTML content, GPU work, and networking in helper
processes. MishMail cannot promise a single Activity Monitor row while it uses
`WKWebView`. It can promise a bounded number of live renderers and no unbounded
memory growth.

### Measure first

Record MishMail plus helper private memory and live `WKWebView` count for:

- cold idle;
- inbox with no reading pane;
- one plain-text thread;
- one HTML thread;
- 50 thread changes;
- repeatedly expanding/collapsing older HTML messages.

Use Instruments Allocations/VM Tracker and add counters for active, pooled,
created, and recycled WebViews plus HTML byte size.

### Changes

1. Lift expanded-message ownership to `ThreadDetailView` so only one HTML
   `MessageCard` can be expanded/mounted at a time.
2. Keep at most one warm `WKWebView` (`HTMLWebViewPool.capacity = 1`), and add
   an explicit drain on:
   - reading-pane close/thread change after a short idle period;
   - app memory-pressure notification;
   - app termination.
3. Precompile/cache the static remote-image rule list. Construct the large
   trusted-fallback HTML document only if rule compilation actually fails;
   today both full document strings are built for every load.
4. Prototype shared WebKit process reuse only behind a flag and retain
   per-message storage/privacy tests. Do not trade cookie/cache isolation for a
   cosmetic Activity Monitor win.
5. Add a Memory Saver setting only if the above is insufficient:
   - prefer plain-text alternatives when available;
   - load HTML on demand.

### Acceptance

- exactly one live HTML renderer in a reading pane and at most one parked;
- after a 50-thread stress run and a settle/drain period, total private memory
  is within 15% of the one-thread baseline;
- helper count does not grow with each opened message;
- no remote-image cookie/cache leakage between messages;
- plain-text-only use mounts no WebView.

Primary files: `UI/ThreadDetailView.swift`, `Support/WebViewPool.swift`,
`Support/HTMLRemoteImageBlocker.swift`, `Support/PerfMetrics.swift`,
`UI/SettingsView.swift`, rendering/privacy tests.

## PR 6 — Unify participant header layout

### Before / after

| Before | After |
| --- | --- |
| Compact state is an unconstrained `VStack`/`HStack`; a long bare address wraps to line two. | Compact and expanded states reuse the same fixed role/value grid. |
| The disclosure glyph is centered against a multi-line recipient block. | Glyph lives in a fixed visual frame, baseline/optically aligned to the one-line recipient value. |
| Bare address can dominate the row and push controls. | Bare address appears once, gets lower layout priority, and truncates in the middle. |
| Small visible glyph has an incidental hit area. | Invisible button frame provides a non-overlapping 40×40 hit target. |
| Expansion changes to a noticeably different alignment system. | FROM/TO columns stay stationary; expansion only reveals additional rows and Show less. |

Implementation:

- Extract `ParticipantIdentityView` and `ParticipantRow`.
- Use explicit layout priorities for name, email, date, and trailing actions.
- Keep sender name primary; treat an unknown/bare email as the primary value,
  not as a missing name.
- Use a custom disclosure button instead of relying on a system `Menu`
  indicator.
- Animate only opacity/disclosure state for about 120 ms; avoid animating the
  whole card's geometry.

Test saved name, bare address, email-as-name, multiple To/Cc, very long domains,
320/480/900 pt widths, 80–200% text size, light/dark mode, and VoiceOver.

Primary file: `UI/ThreadDetailView.swift`, plus screenshot/UI tests.

## Additional interface improvements

| Before | After |
| --- | --- |
| Selection can feel visually disconnected from fast keyboard movement. | Use one crisp, non-animated focused-row treatment and keep the reading preview visually secondary until navigation settles. |
| Sync, auth, and generic errors compete in banners. | Add a small account activity center with per-account states: Syncing, Offline, Reauthorize, Last synced, Retry. |
| Draft saved, Sending, Undo, and Sent are separate pieces of UI state. | Present them as one compose-delivery state progression so there is never both a draft cue and a sending cue. |
| Dense message-header controls remain visible even when unused. | Keep sender/date hierarchy stable and reveal secondary message actions on hover/focus, while preserving keyboard access. |
| One density is expected to fit every workflow. | Add Compact / Comfortable list density; default to the current spacing and make Compact closer to Finder. |
| Motion is inconsistent across navigation and disclosure. | Centralize durations; no animation for keyboard navigation or scroll correction, short interruptible transitions for hover/disclosure, and honor Reduce Motion. |

## Recommended order and effort

| Order | Slice | Why first | Rough effort |
| --- | --- | --- | --- |
| 1 | OAuth docs + classification | Explains the alarming all-account prompt and corrects unsafe guidance. | 1–2 days |
| 2 | Pending-send draft suppression | Small state-machine fix with high visible payoff. | 1–2 days |
| 3 | Inline reply scroll ownership | Highest interaction risk; reconcile the existing branch before more `ThreadDetailView` edits. | 3–5 days |
| 4 | Keyboard focus/open split | Makes the daily triage loop feel native. | 2–3 days |
| 5 | WebKit/memory bound | Measure, then make renderer count structurally bounded. | 3–5 days |
| 6 | Participant header + adjacent polish | Low risk after the larger reading-pane refactor settles. | 1–2 days |

Every PR should run `make test` and `make build`. PRs 3, 4, 5, and 6 also need
manual/UI verification because hostless unit tests cannot validate scroll
position, key-repeat responsiveness, process count, or optical alignment.
