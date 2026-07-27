# In-place app update (Install and Relaunch)

**Date:** 2026-07-27
**Status:** Designed

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

- `installDirectory() -> URL?` — resolve the persisted app-scoped
  bookmark, `nil` when absent or stale.
- `requestInstallDirectory() -> URL?` — `NSOpenPanel`, directories only,
  opened on the running app's parent folder, titled "Install MishMail".
  Persists the bookmark on success.
- `install(verifiedApp:over:) throws` — `FileManager.replaceItemAt`,
  wrapped in `startAccessingSecurityScopedResource` /
  `stopAccessingSecurityScopedResource`.
- `relaunch() throws` — `NSWorkspace.openApplication` with
  `createsNewApplicationInstance`, then terminate.

`UpdateChecker.downloadAndVerifyApp` is unchanged except that the
in-place path no longer calls `markQuarantined`.

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
app — plus notarization for Developer ID builds. That is strictly
stronger than what Gatekeeper checks on an Apple Development build,
where the quarantine tag buys nothing but a warning on every update.
This is the same trade Sparkle makes.

The Finder-reveal fallback **keeps** the tag. There the user
double-clicks a bundle out of a temp directory themselves, and the
trust chain is the OS's job again.

### Install timing

One click: swap while the app is fully alive, then relaunch, then quit.
Deferring the swap to quit-time would mean doing filesystem work during
termination without a helper process — Sparkle uses a separate installer
XPC for exactly that reason — so it is not worth the fragility here.

Compose autosave is debounced (`ComposeView.scheduleAutosave`) and
compose windows save their draft on close, so a normal `NSApp.terminate`
should flush rather than drop. Confirming that is a spike (below), not an
assumption.

### Failure paths

Every failure degrades to today's behavior rather than a dead end.

| Failure | Behavior |
| --- | --- |
| Panel cancelled / no grant | Finder reveal, quarantine tagged, as today |
| `install` throws (disk full, permissions) | Verified copy stays in temp; status explains; Finder reveal offered |
| `relaunch` throws | Swap already succeeded — do **not** terminate. Status: "Update installed — quit and reopen MishMail." |
| Download or verification fails | Unchanged: status explains, release page opens |

Termination happens only after `openApplication` returns successfully.

### UI

`UpdatesSettings` keeps its shape. The primary button runs the whole
sequence on one click, its label tracking the phase
(Update App → Downloading… → Verifying… → Installing…), with "View on
GitHub" beside it. The footer copy loses "drag into Applications to
install" and describes the real flow, including the one-time folder
prompt. The sidebar update affordance is unchanged.

## Testing

- The swap is exercised against a temp directory containing a stub
  `.app`: a successful replace, and a failure leaving the original intact.
- Install-target resolution — bookmark directory matching the running
  app's parent, mismatch forcing a re-prompt — is a pure function and is
  unit-tested.
- Existing `UpdateCheckerTests` (version compare, checksum parsing,
  asset picking) are unaffected and must stay green.
- The grant and the relaunch need a real release to exercise: cut a
  throwaway v0.4.1 and update a 0.4.0 install before trusting it.

## Spikes — assumptions to verify before shipping

1. **Sandboxed self-relaunch.** Whether
   `NSWorkspace.openApplication(createsNewApplicationInstance:)` is
   permitted for a sandboxed app launching itself. If it is blocked, the
   fallback is the "quit and reopen" message — degraded, not broken.
2. **macOS 14+ App Management (TCC).** Modifying another app's bundle
   normally prompts. Self-updates where the writing process and the
   target share a Team ID are exempt, and Team ID continuity is already
   enforced — but confirm on the actual OS.
3. **Terminate flushing a pending compose autosave.** ComposeView saves
   on close; whether `NSApp.terminate` reaches that path with a debounce
   still in flight needs checking.
