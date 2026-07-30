# MishMail Security Review — 2026-07-29

Second source-based pass (the first is [security-review.md](security-review.md),
2026-07-09, SEC-001–003 fixed same-day). Source review only: no dynamic fuzzing,
no binary entitlement inspection, no dependency CVE scan. All findings below
were fixed the same day and verified with the unit suite plus an app Debug
build; two external review loops (gpt-5.6-sol ×3 rounds, claude-opus-5 high
effort) each found real follow-ups — DMARC alignment, an async data-store
race, a payload-SELECT projection gap, a comment-stripped token match, and
the fail-closed-nil decision — all folded in before commit.

## Medium severity

### SEC-004 — CSP head injection could be misdirected into inert content

**Status: Fixed.** `HTMLBodyDocument` no longer injects into message markup at
all; the trusted head (CSP + MishMail CSS) is always a synthetic wrapper ahead
of the first untrusted byte (`trustedWrapper` is the only assembly path), and a
new adversarial test battery pins the invariant.

**Location:** `Sources/MishMail/Support/HTMLBodyDocument.swift` (pre-fix
`injectIntoHead` / `rangeOfOpeningTag`).

For complete HTML documents, the CSP `<meta>` was injected after the first
"real" `<head>` found by a hand-rolled scanner. The scanner skipped comments
and `script/style/title/textarea/xmp`, but not `<template>`, `<iframe>`
fallback content, `<noscript>` (parsed as markup because content JS is
disabled), `<plaintext>`, or SVG/MathML foreign-content breakout. A decoy
`<head>` inside any of those (e.g.
`<html><template><head>…</head></template><head>…`) attracted the injection
into content the parser treats as inert, so the message rendered with **no CSP
at all** while the app believed one applied.

Remaining layers (JS disabled, default-deny navigation, the HTTPS-image
content rule) kept the impact bounded, but under the default block-images
policy non-image HTTPS subresources (stylesheets, fonts, media) could load —
sender open-tracking and IP disclosure despite the user never opting in — and
`<base href>` phishing became possible.

**Fix:** wrapping instead of injecting is structurally immune — the parser
sees the synthetic head first, author `<html>`/`<head>` tokens in the body are
ignored, author `<style>` still applies document-wide, and a second
attacker-supplied CSP meta can only tighten the policy.

## Low severity

### SEC-005 — VIP remote-image auto-load trusted the unauthenticated From header

**Status: Fixed.** The parser now records Gmail's own
`Authentication-Results` verdict per message (migration v29,
`message.senderAuth`), and `.vip` auto-load requires an aligned `dmarc=pass`
from a boundary-checked method token with comments stripped — SPF/DKIM alone
are not sufficient (a spoofer passes both for their own domain), and a bare
substring match is attacker-influenceable (Google echoes the envelope sender
verbatim; `"dmarc=pass"@evil.example` must not qualify). The verdict reaches
the pane through every path — including the thread-detail cache's custom
payload SELECT, which previously projected it away.

**Fails closed on the existing corpus:** rows synced before v29 have no
verdict, and `nil` blocks auto-load too — an explicit per-message or
per-thread click always wins. Cost: one click per existing VIP message until
those threads re-sync.

Residual caveats, accepted: senders on domains without a DMARC record judge
as failures (one click); only the *first* `Authentication-Results` header is
consulted (Gmail prepends it at delivery, so forwarded copies can't pose as
it — but mail added via `users.messages.insert`/import can carry an
attacker-authored first header, so this is a guard, not a guarantee).

### SEC-006 — OAuth loopback could drop a fragmented legitimate redirect

**Status: Fixed.** The listener accumulates until the request line's CRLF
arrives (16 KB cap) instead of judging the first received fragment; a redirect
delivered in more than one segment is no longer mistaken for a probe.
Probe-tolerance and state validation are unchanged.

### SEC-007 — Recycled web views carried network state across messages

**Status: Fixed.** `clearForReuse` now wipes the view's ephemeral data store
(cookies/cache) along with the DOM, and pooling waits for the removal to
complete — a dequeued view never races the deletion, so one message's (or
one account's) remote-image state cannot accompany the next message's
loads. Pre-render steals hand out a fresh view and park the stolen one only
after its wipe lands. `hasForeignContent` is flagged *before* the async wipe
starts (a completion can otherwise re-park the view before the flag is set),
and a pool generation counter keeps `drain()` from being undone by pending
wipe completions. Parked pre-renders keep their store intentionally — same
message.

## Hardening / notes

- Attachment temp files are owner-only (0600) inside 0700 directories,
  asserted on the reuse path too (older builds left 0644/0755). The residual
  same-user swap race between validation and LaunchServices open is inherent
  to temp files; per-open quarantine re-tagging bounds it.
- `DemoSeed.isActive` documents the two deliberately different "demo" notions
  (persisted UI flag vs. the env-var fixture-key/account guards) so a future
  refactor doesn't guard on the wrong one.
- Keychain items stay `AfterFirstUnlockThisDeviceOnly` by design (background
  sync while the Mac is locked after first unlock). Accepted risk; revisited
  and kept.
- Ollama prompts interpolate raw mail bodies with untrusted-content markers;
  outputs are drafts/labels the user reviews. Inherent to local LLM features.

## Positive controls verified this pass

- SQL: every dynamic value bound; interpolated SQL is constant column
  names/placeholders; FTS5 via GRDB's quoting `FTS5Pattern`.
- MIME: CR/LF folded in all header values including attacker-controlled
  reply-threading headers; quoted parameters escaped.
- OAuth: PKCE S256, high-entropy state, RNG failure aborts, loopback-only
  one-shot listener, state-checked completion.
- Updates (in-place since 0.4.1): SHA-256, full nested signature check,
  Team-ID continuity, no ad-hoc downgrade, notarization for Developer ID,
  and a signed-bundle-version == tag pin that blocks rollback-by-republish.
  The relauncher's quarantine strip runs unsandboxed but only on the bundle
  the app itself installed; the plan file lives in the app container.
- Attachments: basename sanitization, risky-extension prompt, quarantine on
  every open, symlink/non-regular rejection, atomic writes, collision-free
  naming.
- Secrets/logging: tokens and DB key in device-only non-syncing Keychain;
  no tokens, subjects, or bodies in logs.
