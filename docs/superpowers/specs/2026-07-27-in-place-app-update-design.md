# In-place app update (Install and Relaunch)

**Date:** 2026-07-27
**Status:** Implemented — revised after review (see "Changes from review")

## Problem

"Update App" does not feel like updating an app. `UpdateChecker`
downloads the release zip into
`/var/folders/…/MishMailUpdate-<uuid>/`, verifies it, `ditto`-extracts
into a subfolder literally named `extract/`, tags the result with the
`com.apple.quarantine` xattr, and then calls
`activateFileViewerSelecting`. The user gets a Finder window onto a
scratch directory and has to drag the app into `/Applications`
themselves — and because of the quarantine tag, Gatekeeper then warns
about the un-notarized Personal Team build they just chose to install.

Three points of friction where a normal Mac app has none.

Two constraints shape the fix:

- **The app is sandboxed.** `MishMail.Distribution.entitlements` grants
  `files.user-selected.read-write` and nothing else file-related, so the
  app cannot write `/Applications` unaided.
- **Personal Team signing, no notarization** (see docs/RELEASING.md
  "Signing tiers"). Anything that re-triggers Gatekeeper is a visible
  regression, and no paid Developer ID is coming.

The download and verification code is good and stays. Only the "get it
into place" half is being replaced.

## Approaches considered

1. **In-place self-update via a one-time folder grant** *(chosen)* — after
   verification, an `NSOpenPanel` grants the app's own install directory,
   persisted as an app-scoped security bookmark. Atomic
   `replaceItemAt` swap, no quarantine tag, relaunch, quit. Stays
   sandboxed, needs no admin password, reuses every existing trust check,
   and costs one file picker on the first update only.
2. **Ship a DMG** with an `/Applications` symlink and open it. Cheapest
   change — a Makefile target plus `NSWorkspace.open` — and it replaces
   the temp `extract` folder with the familiar drag window. Rejected: it
   is still a manual drag every single release, so it fixes the ugliness
   without fixing the flow.
3. **Adopt Sparkle 2.** The industry answer: background download,
   Install-and-Relaunch, sandbox support via its installer XPC, EdDSA
   appcast signatures so no Developer ID is needed. Rejected for now — it
   adds a dependency, an appcast pipeline, mach-lookup entitlements, and
   it supersedes the bespoke checksum/Team-ID/notarization verification
   already written and tested here.
4. **Unsandbox the release build**, Sparkle-style, and write
   `/Applications` directly with zero prompts. Rejected: a real security
   regression for a mail client holding OAuth tokens.

## Design

### Components

`UpdateChecker` keeps its scope — *is there a newer version, and is this
download trustworthy*. A new `Support/UpdateInstaller.swift` owns
*getting it into place*:

- `installDirectory(for:) -> URL` — the running app's parent folder.
- `isTranslocated(_:) -> Bool` — whether the running app sits on a
  read-only App Translocation mount, where no in-place install is
  possible.
- `resolveGrant(installDirectory:defaults:) -> URL?` — resolve the
  persisted app-scoped bookmark; `nil` when absent, unresolvable, or
  pointing anywhere but the running app's folder. Unusable bookmarks are
  dropped so the next attempt re-prompts instead of failing forever.
- `requestGrant(installDirectory:defaults:) throws -> URL` —
  `NSOpenPanel`, directories only, opened *on* the install folder with
  nothing selected, so confirming without navigating grants exactly the
  folder needed. Prompt: "Grant Access". Persists the bookmark.
- `withAccess(to:_:)` — holds the security scope around a body.
- `swap(newApp:onto:) throws` — `clearQuarantine`, then
  `FileManager.replaceItemAt`.
- `relaunch(_:) async throws` — `NSWorkspace.openApplication` with
  `createsNewApplicationInstance`, then terminate.

`UpdateChecker.downloadAndVerifyApp` keeps every existing check, drops
the `markQuarantined` call, and gains version pinning (below).

### Install target and the grant

The target is the running app's own parent directory
(`Bundle.main.bundleURL.deletingLastPathComponent()`), not a hardcoded
`/Applications`. That resolves to `/Applications` for anyone who ran
`make install`, and stays correct if the app has been moved. The panel
opens there with the folder pre-selected.

The grant persists as an app-scoped security bookmark in `UserDefaults`
under `updates.installDirBookmark`, which requires
`com.apple.security.files.bookmarks.app-scope` in both
`MishMail.entitlements` and `MishMail.Distribution.entitlements`. If a
resolved bookmark does not match the running app's current parent
directory, the bookmark is discarded and the panel is shown again — this
is what handles the app being moved between updates.

### Trust: dropping the quarantine tag

The in-place install does **not** set `com.apple.quarantine`. By the time
`install` is called, `downloadAndVerifyApp` has confirmed the archive's
SHA-256 against the published `SHA256SUMS` (when present), full nested
code-signature validity (`kSecCSCheckNestedCode |
kSecCSCheckAllArchitectures`), and Team ID continuity with the running
app — plus notarization for Developer ID builds, and (after review) the
bundle's own version. That is stronger than what Gatekeeper checks on an
Apple Development build. Keeping the tag would not even be the
conservative option: on macOS 14+ Gatekeeper *refuses to launch* a
quarantined un-notarized build, so the tag would break the relaunch on
every single update. What is actually given up is XProtect's
first-launch malware scan and a user-override speed bump in a scenario
(stolen signing key *and* repo compromise) where the attacker already
owns the same Mac the key lives on. This is the same trade Sparkle
makes.

The Finder-reveal fallback **keeps** the tag. There the user
double-clicks a bundle out of a temp directory themselves, and the
trust chain is the OS's job again.

### Trust: version pinning

Signatures prove identity, not freshness. Every past release is public
and carries the same Team ID, so whoever controls the GitHub account —
with no signing key at all — could republish an old, vulnerable, validly
signed build under a higher tag and roll the app backwards past every
other check. `downloadAndVerifyApp` therefore requires the extracted
bundle's `CFBundleShortVersionString` to equal the release version it
was offered as; `make release` derives the tag from `MARKETING_VERSION`,
so the two always agree for real releases, and a mismatch falls back to
opening the release page.

### Install timing

One click: swap while the app is fully alive, then relaunch, then quit.
Deferring the swap to quit-time would mean doing filesystem work during
termination without a helper process — Sparkle uses a separate installer
XPC for exactly that reason — so it is not worth the fragility here.

Compose autosave is debounced and a compose window's pending save is
*not* flushed by app termination, so a restart can drop the last few
seconds of typing. Rather than build a compose-session registry for
this, the install asks first when a draft is open ("Install and Restart"
/ "Cancel"). With no draft open there is no prompt.

### Failure paths

Up to the swap, every failure degrades to the old behavior rather than a
dead end. After it, there is no going back — the new bundle is already
installed and the database is closed.

| Failure | Behavior |
| --- | --- |
| Running from an App Translocation mount | Finder reveal, quarantine tagged; no install directory exists to swap into |
| Panel cancelled / no grant | Finder reveal, quarantine tagged, as today |
| `swap` throws (disk full, permissions, TCC) | Verified copy stays in temp; status explains; Finder reveal offered |
| `relaunch` throws | The pool is closed and the timers are dead, so the process can no longer sync, save, or send. Alert ("MishMail X is installed… will now quit"), then terminate — a closed app on an installed update beats a zombie that looks alive |
| Download or verification fails | Unchanged: status explains, release page opens |

### UI

`UpdatesSettings` keeps its shape. The primary button, **Install and
Relaunch**, runs the whole sequence on one click, showing a spinner and
"Updating…" while the status line beneath tracks the phase
(Downloading… → Installing… → Restarting…). "View on GitHub" sits beside
it, and "Check for Updates" is disabled during an install. The footer
copy loses "drag into Applications to install" and describes the real
flow, including the one-time folder prompt. The sidebar affordance
becomes "Update to X and restart" — one click there installs, so the
label says so rather than hiding it in a tooltip.

## Testing

- The swap is exercised against a temp directory containing a stub
  `.app`: a successful replace, a failure leaving the original intact,
  and a tagged bundle arriving unquarantined (the property the relaunch
  depends on).
- Install-target resolution — bookmark directory matching the running
  app's parent, mismatch forcing a re-prompt, an unresolvable bookmark
  being dropped — is pure and unit-tested, as is translocation
  detection.
- `bundleVersion` is tested both ways: a real `CFBundleShortVersionString`
  and a bundle with no readable version, which must not pass as any
  version.
- Existing `UpdateCheckerTests` (version compare, checksum parsing,
  asset picking) are unaffected and must stay green.
- The grant and the relaunch need a real release to exercise: cut a
  throwaway v0.4.1 and update a 0.4.0 install before trusting it.

## Changes from review

An adversarial review of the first implementation produced four changes,
all folded in above: quitting rather than lingering when the relaunch
fails (the DB is already closed by then, so the old "stay open" plan
left a zombie); version pinning against tag-based rollback; an
open-draft confirmation before the restart; and an App Translocation
guard. Smaller: `check()` now refuses to run during an install, and the
sidebar label states that it restarts.

## Spikes — resolved by the first real update (0.4.1 → 0.4.2)

1. **Sandboxed self-relaunch — FAILED, then fixed.**
   `NSWorkspace.openApplication(createsNewApplicationInstance:)` returned
   "a miscellaneous error occurred" (LaunchServices `-10810`). Asking for
   a second instance of our own bundle from inside it doesn't work, and
   swapping first compounds it: the registration LaunchServices has
   cached points at the inode just deleted. Replaced in 0.4.3 with a
   detached `/bin/sh` that polls until this process exits, then `open`s
   the app by path — no instance conflict, and the bundle is re-read from
   disk. The failure path behaved exactly as designed: alert, then quit,
   rather than a zombie on a closed database.
2. **macOS App Management (TCC) — PASSED.** `replaceItemAt` from the
   sandbox container onto `/Applications` succeeded with no prompt on a
   free Personal Team certificate; the installed bundle really was 0.4.2
   afterwards. The same-Team-ID self-update exemption holds.
3. **`NSOpenPanel` empty selection — PASSED.** The panel returned
   `/Applications` with nothing selected, and the resulting app-scoped
   bookmark persisted (512 bytes under `updates.installDirBookmark`), so
   later updates skip the prompt.

A fourth problem surfaced at the same time, unrelated to the spikes:
`startPeriodicChecks` ran its launch check through the same daily gate as
the hourly tick, and that timestamp survives in preferences across an
update — so relaunching into a brand-new release showed nothing until
"Check for Updates" was pressed. 0.4.3 always checks at launch.

Still unverified after 0.4.3: whether the detached-shell relaunch works
from inside the sandbox. Spawning `/bin/sh` is permitted and the child
inherits the sandbox, where `open` is a LaunchServices client like
`NSWorkspace` — but the first update *from* a 0.4.3 install is the proof.
If the spawn itself fails it throws and the alert-and-quit path runs as
before; if the spawn succeeds but `open` doesn't, the update is installed
and the app simply has to be reopened.
