# Fable review — greeting: no fabricated name from bare email local-part

- **Date:** 2026-08-02
- **Grok job:** ship-20260802T014154-64257
- **Implementer model:** grok-4.5 (verified via `jacq-grok status --json`)
- **Branch:** jacq/ship-20260802T014154-64257
- **Reviewed commit:** f0101d9da2b1e925ce5603ab06c6dc5dd58f56b5
- **Verdict:** SHIP

## Problem

Composing to a bare address not in contacts (e.g. `tomconerly@gmail.com`, forward
draft) showed the ghost greeting "Hi Tomconerly," — a title-cased guess from the
email local-part. Prior fixes (f95f71f, b543c7a) only suppressed email-shaped
names and role mailboxes; `recipientFirstName`'s last fallback still used
`person(from:)`'s fabricated local-part guess.

## Change reviewed

- `GreetingAutocomplete.explicitDisplayName(from:)` added — returns a display
  name only for angle-bracket tokens (`"Alice <a@x.com>"`); bare addresses → nil.
- `recipientFirstName` now uses `explicitDisplayName` instead of
  `person(from:)`'s guess. Bare address + no contact + no header name → `""`
  → no ghost greeting.
- `person(from:)` unchanged — ComposeView call sites (lines ~1642, ~1940) use it
  only for the email component / non-greeting purposes; behavior preserved.
- Tests: new `testRecipientFirstNameIgnoresBareAddressLocalPart`
  (`tomconerly@gmail.com`, `john.doe@x.com` → ""); email-shaped contact
  fallbacks updated from "John" → ""; angle-bracket display names still work;
  `explicitDisplayName` covered directly.

## Review notes

- Diff is minimal (2 files, +48/−10), no unrequested changes.
- headerName / contactName preference order and role-mailbox suppression
  unchanged.
- Grok's sandbox blocked `make test` (GRDB package resolution); commit used
  `--no-verify`. Supervisor re-ran `make test` in the worktree outside the
  sandbox: **TEST SUCCEEDED** (full suite).

## Verdict

SHIP — merged to main.
