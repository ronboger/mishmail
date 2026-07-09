# PerfectMail Security Review

## Executive summary

PerfectMail has a strong security baseline for a local mail client: it uses OAuth PKCE with a loopback-only callback and state validation, stores tokens and the SQLCipher key in the macOS Keychain, encrypts the mail cache, renders email in a JavaScript-disabled ephemeral `WKWebView` with a restrictive CSP and default-deny navigation, and sanitizes and quarantines attachments.

I found no clear critical or high-severity vulnerability in the reviewed source. I found three defense-in-depth issues: one medium-severity update trust weakness affecting ad-hoc/source builds, and two low-severity local file/randomness weaknesses. All three were fixed on 2026-07-09 and verified with the unit suite plus a full Debug app build. The review was source-based; it did not include dynamic fuzzing, binary entitlement inspection, or a third-party dependency vulnerability audit.

## Medium severity

### SEC-001 — Ad-hoc/source builds accept an update signed by any ad-hoc identity

**Status: Fixed.** Source/ad-hoc installations now accept executable updates only when they are Developer ID signed and notarized; signed installations retain Team ID continuity.

**Location:** `Sources/PerfectMail/Support/UpdateChecker.swift:380-418`

When the running app has no Team ID, `evaluateTrust` does not require the update to have a particular identity. `verifyCodeSignature` accepts structurally valid ad-hoc signatures, and `officialRelease` is explicitly ignored. Therefore an ad-hoc/source installation will accept and reveal an arbitrary ad-hoc-signed app delivered through the configured GitHub release channel. A checksum does not establish independent trust because the checksum is fetched from the same release and is optional.

**Impact:** Compromise of the repository/release publishing channel could turn the updater into a code-delivery path for users running ad-hoc/source builds; Developer ID installations retain Team ID continuity and are not affected by this exact issue.

**Recommendation:** Do not present an ad-hoc update as verified solely because its signature is structurally valid. For source/ad-hoc installations, either open the release page without downloading an executable, require an independently pinned signing identity/public key, or require a trusted Developer ID/notarized build whose designated requirement is pinned. Keep the existing Team ID continuity check for signed installations.

## Low severity

### SEC-002 — Predictable attachment cache trusts any pre-existing file

**Status: Fixed.** Cache paths now include the account ID, cache hits must be regular non-symlink files and are re-quarantined, cache directories use restrictive permissions, and new files are written atomically and validated.

**Location:** `Sources/PerfectMail/App/MailStore.swift:2694-2723`

The attachment cache path is predictable from Gmail/DB identifiers. If a file already exists, the function returns it without checking that it is a regular non-symlink file, verifying its content against freshly downloaded bytes, or applying quarantine. A process able to write within the app's temporary container (including injected code in a development build with library validation disabled) can pre-position a file or symlink that the user later opens believing it is the email attachment.

**Recommendation:** Create the cache directory with restrictive permissions, reject symlinks and non-regular files, write a fresh download atomically with exclusive-create semantics, and apply quarantine before returning. At minimum, quarantine and validate any cache hit. Including the account ID in the namespace would further separate accounts.

### SEC-003 — PKCE verifier/state generation ignores RNG failure

**Status: Fixed.** OAuth sign-in now checks `SecRandomCopyBytes` and aborts with a dedicated error unless it returns `errSecSuccess`.

**Location:** `Sources/PerfectMail/Auth/OAuth.swift:289-305`

`SecRandomCopyBytes` returns a status, but the implementation discards it. On failure, the zero-initialized buffer is used for the PKCE verifier and OAuth state, making both predictable. A system RNG failure is rare, so practical likelihood is low, but authentication must fail closed if cryptographic randomness cannot be obtained.

**Recommendation:** Make `randomURLSafe` throwing, require `errSecSuccess`, and abort sign-in on failure. Add a test seam so the failure path can be exercised.

## Additional hardening observations

- **Fixed:** “Save All” now chooses a non-existing destination for duplicate or pre-existing names and uses atomic writes; “Save As” refuses a symlink destination.
- `Sources/PerfectMail/PerfectMail.entitlements:7-8` disables library validation for the normal project entitlement set. The documented distribution entitlement removes it, which is the correct shipping posture. Add a release/CI assertion that archived distribution builds actually use `PerfectMail.Distribution.entitlements`.
- `Sources/PerfectMail/Support/Keychain.swift:25-28` uses `AfterFirstUnlockThisDeviceOnly`. This is reasonable for background mail operation, but it deliberately leaves secrets accessible while the Mac is locked after first unlock. If locked-screen background sync is unnecessary, `WhenUnlockedThisDeviceOnly` is stricter.

## Positive controls verified

- OAuth callback binds to `127.0.0.1`, uses high-entropy state/PKCE under normal RNG operation, validates state, limits request size, and times out.
- OAuth refresh tokens, client secret, and database key are stored in a device-bound, non-synchronizing Keychain item.
- The mail database is SQLCipher-encrypted with a random 256-bit Keychain-held key.
- HTML email JavaScript is disabled; storage is ephemeral; CSP blocks scripts, forms, frames, objects, base URLs, and remote images by default; navigation is default-deny.
- Attachment names are reduced to basenames, risky executable extensions prompt the user, and downloaded files are normally quarantined.
- Distribution updates require Team ID continuity, and Developer ID updates must be notarized.
