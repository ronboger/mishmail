---
date: 2026-08-03 16:30
kind: fable-iterate review
implementer: grok-4.5 (jacq-grok ship)
job_ids: ship-20260803T162247-16980
reviewed_commit: bfd35ebf68d7258e555f08196ab7c832a6bde7ab
branch: jacq/ship-20260803T162247-16980
verdict: SHIP
---

# Review — schemeless email link recovery (pass 1)

## Bug
Clicking `cal.com/stevesimitzis` in Steve Simitzis's reply did nothing. The
sender's client emitted a schemeless `href="cal.com/stevesimitzis"`; MishMail
loads message HTML via `loadHTMLString(_, baseURL: nil)` (base `about:blank`),
so the click arrived with scheme `nil`/`about` and the allowlist in
`ThreadDetailView.decidePolicyFor` (`http`/`https`/`mailto` only) silently
cancelled it.

## Change reviewed
- New `Sources/MishMail/Support/ExternalLinkRecovery.swift`: pure helper.
  Pass-through for http/https/mailto; for nil/`about` schemes it peels
  `about:` / `blank` / leading slashes, percent-decodes, rejects reconstructed
  schemes (javascript:, file:, data:, custom), requires a dotted hostname of
  valid characters, and gates on `TextDirection.isLinkableHost` (multi-label
  host + allowlisted TLD) before returning `https://…`.
- `ThreadDetailView.swift` `.linkActivated` branch now opens the recovered URL
  via NSWorkspace; still always `.cancel`. Default-deny for non-link
  navigations untouched.
- 19 unit tests in `ExternalLinkRecoveryTests.swift` covering pass-through,
  all plausible about-resolved forms, and security rejections (javascript,
  file, data, about:blank alone, single labels, file-looking tokens, unknown
  TLDs, embedded scheme after about:, custom app scheme).
- `project.yml` registers the new source.

## Review notes
- Security invariant preserved: recovery path only fires for nil/`about`
  schemes; every other scheme stays inert. Reconstructed-scheme rejection
  closes the `about:javascript:alert(1)` hole and is tested.
- Reuses existing `TextDirection.isLinkableHost` prior art rather than a new
  loose regex — consistent with compose autolink behavior.
- Grok's sandbox blocked SPM resolution, so it committed with `--no-verify`
  and flagged VERIFICATION-BLOCKED. I re-ran `make test` in the worktree:
  **1282 tests, 0 failures**, `ExternalLinkRecoveryTests` suite present in the
  xcresult bundle. Build succeeded.
- No unrequested changes in the diff.

## Verdict
SHIP.
