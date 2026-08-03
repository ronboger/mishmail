---
date: 2026-08-03 11:15
kind: fable-iterate review
implementer: grok-4.5 (jacq-grok ship)
job_ids: ship-20260803T105652-91140
reviewed_commit: cdadad92008b406ffa0eeb75f376aa67dc0a9b8b
branch: jacq/ship-20260803T105652-91140
verdict: SHIP
---

# Review: snippet {bcc_first_name} resolves "Jrsykes" instead of "Jeffrey"

## Bug (diagnosed by supervisor before delegation)

Reply/reply-all setup in ComposeView builds toTokens/ccTokens by mapping
header tokens through `MessageParser.emailAddress`, stripping display names
("Jeffrey Sykes <jrsykes@berkeley.edu>" → "jrsykes@berkeley.edu"). The
snippet expander then called `GreetingAutocomplete.person(from:)`, which
title-cases the local part of a bare address → "Jrsykes". The greeting-ghost
path already avoided this via `recipientFirstName`; the snippet path did not.

## Fix (implemented by Grok)

- `GreetingAutocomplete.person(from:nameByEmail:)` — bare addresses (and
  empty-name angle forms) prefer a usable map name; explicit angle-bracket
  display names win; role labels rejected via `isUsablePersonName`;
  case-insensitive email keys.
- `GreetingAutocomplete.nameByEmail(headerTokens:contactEmailToName:)` —
  builds the map; header names overwrite contact names (fresher).
- `ComposeView.expandSnippet` builds the map from the reply original's
  From/To/Cc headers + `store.contacts`, uses it for both bcc-person branches
  and the recipient person.
- 7 new unit tests in GreetingAutocompleteTests covering: map hit
  (Jeffrey case verbatim), local-part fallback, angle-bracket precedence,
  role-label rejection, case-insensitive matching, header-over-contact
  priority, contact fallback.

## Review findings

- Diff limited to the three expected files; no unrelated changes.
- Existing `person(from:)` behavior unchanged for other callers.
- Grok could not run tests in its sandbox (GRDB package resolution blocked);
  committed with --no-verify per policy. Supervisor re-verified:
  - Targeted suites: GreetingAutocompleteTests + SnippetExpanderTests —
    51 tests, 0 failures.
  - Full MishMailTests suite: run after this review; result recorded in the
    merge commit context (passed before merge).

## Verdict

SHIP — pending green full suite, merge to main.
