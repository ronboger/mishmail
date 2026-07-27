# Releasing MishMail

MishMail ships as a signed `.app` published to **GitHub Releases**
(`ronboger/mishmail`). Running copies check that repo about once a day and
surface an **Update app** button (sidebar + Settings → Updates) when a newer
version exists. Cutting a release = building Release, zipping the app, and
creating a GitHub release tagged `v<version>`.

There are three "apps" the Makefile can produce — don't confuse them:

| Command | Config | What it is |
|---|---|---|
| `make run` | Debug | Throwaway **"MishMail Debug"** with isolated data. For eyeballing a change. Never shipped. |
| `make install` | Release | Installs the real **MishMail.app** into `/Applications` (your daily driver). Local only — does **not** publish. |
| `make release` | Release | Builds Release, zips it, and **publishes a GitHub release** everyone's updater sees. |

`make install` is "ship it to my machine." `make release` is "ship it to
everyone." This doc is about `make release`.

## Prerequisites (one-time)

- **`gh` CLI authenticated** with push access to `ronboger/mishmail`:
  ```sh
  gh auth status        # expect: Logged in to github.com as ronboger
  ```
- **`xcodegen`** installed (`brew install xcodegen`) — the Makefile regenerates
  the project from `project.yml` on every build.
- **Signing**: `Config/Local.xcconfig` (git-ignored) must define
  `DEVELOPMENT_TEAM` with a valid signing identity in the keychain. The
  standard setup here is the **free Personal Team** ("Apple Development"
  certificate, no paid program) — see [Signing tiers](#signing-tiers). Run
  `make signing-doctor` to check. Pure ad-hoc (no team at all) is refused:
  an ad-hoc signature provides no publisher identity for the updater.

## Release checklist

1. **Be on `main`, up to date, clean tree.**
   ```sh
   git checkout main && git pull
   git status            # expect: nothing to commit, working tree clean
   ```

2. **Bump the version.** `MARKETING_VERSION` in [`project.yml`](../project.yml)
   is the single source of truth (the Makefile reads it for the tag and zip
   name). Bump it following semver — e.g. `0.1.0` → `0.1.1` for fixes, `0.2.0`
   for features.
   ```sh
   # edit project.yml:  MARKETING_VERSION: 0.2.0
   ```
   Optionally bump `CURRENT_PROJECT_VERSION` (the build number) too if you want
   each build individually identifiable; it's not required for the updater,
   which compares `MARKETING_VERSION`.

3. **Commit the bump.**
   ```sh
   git add project.yml
   git commit -m "Release v0.2.0"
   git push
   ```

4. **Cut the release.** `make release` runs the full test suite first, then
   builds Release, zips the app, writes **SHA256SUMS**, and creates the GitHub
   release. It will refuse to proceed if tests fail.
   ```sh
   make release
   ```
   This runs, in order:
   - `make test` (gate — must pass)
   - `xcodebuild ... -configuration Release` (with Distribution entitlements
     when `Config/Local.xcconfig` defines `DEVELOPMENT_TEAM`)
   - `ditto -c -k --keepParent MishMail.app MishMail-<version>.zip`
   - `shasum -a 256 … > SHA256SUMS`
   - `gh release create v<version> MishMail-<version>.zip SHA256SUMS --generate-notes`

5. **Verify.**
   ```sh
   gh release view v0.2.0 --web     # zip + SHA256SUMS both attached
   cat build/dd.noindex/Build/Products/Release/SHA256SUMS
   ```
   Running apps pick it up within ~a day, or immediately via **Settings →
   Updates → Check for Updates**. The updater downloads the zip, checks
   SHA-256 against `SHA256SUMS`, then verifies code signature / Team ID /
   notarization before swapping the bundle over the running app and
   relaunching (`UpdateInstaller.swift`). Only a declined permission grant or a
   failed swap falls back to revealing the app in Finder.

## Tag & version rules

- **Tag format is `v<MARKETING_VERSION>`** (e.g. `v0.2.0`) — `make release`
  derives it automatically. Don't create the tag by hand.
- The updater compares `MARKETING_VERSION` strings, so **the version must
  strictly increase** or existing installs won't offer the update.
- **One release per version.** `gh release create` fails if `v<version>`
  already exists — if you need to redo a release, delete the old one first
  (`gh release delete v0.2.0 --cleanup-tag`) or bump to a new version (cleaner).

## Signing tiers

`make release` picks a tier automatically from what's in the keychain:

### Tier 1 — free Personal Team (the standard path here)

**This is how every MishMail release to date has shipped.** No paid Apple
Developer Program needed. `Config/Local.xcconfig`:

```
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = 47T79PSL25
CODE_SIGN_IDENTITY = Apple Development
```

The build is signed with the free "Apple Development" certificate (get one by
signing into Xcode → Settings → Accounts with any Apple ID; no membership
required). No notarization happens or is required. Trust model:

- **Your own installs update seamlessly** — the in-app updater accepts
  Apple Development-signed updates as long as the **Team ID matches** the
  running install ("Team ID continuity" in `UpdateChecker.swift`).
- **Other people's Macs** will get Gatekeeper warnings on the downloaded
  binary; building from source is the supported path for them (per README).

If `make release` says "Refusing release: no valid signing identity", the
usual causes are: the Apple Development cert expired (open Xcode →
Settings → Accounts → Manage Certificates and it auto-renews), or
`Config/Local.xcconfig` is missing on this machine (it's git-ignored —
recreate it with the block above).

### Tier 2 — Developer ID + notarization (optional, paid program)

If a "Developer ID Application" identity for the team exists in the keychain,
`make release` automatically switches to Manual Developer ID signing and
notarizes + staples before publishing (requires a stored
`MishMail-notary` keychain profile). This makes the binary Gatekeeper-clean
for strangers. Setup:

1. In `Config/Local.xcconfig`, use a Developer ID identity:
   ```
   CODE_SIGN_STYLE = Manual
   DEVELOPMENT_TEAM = XXXXXXXXXX
   CODE_SIGN_IDENTITY = Developer ID Application
   ```
   Keep `ENABLE_HARDENED_RUNTIME` on (it already is in `project.yml`).
   **`make release` / `make install` automatically pass
   `CODE_SIGN_ENTITLEMENTS=…/MishMail.Distribution.entitlements`** whenever
   `DEVELOPMENT_TEAM` is set, so library validation stays ON for shipping
   builds. (Ad-hoc CI/Debug still use the looser entitlements so the
   separately-signed GRDB framework can load.)
2. **Store notarization credentials** once so `make release` can notarize
   automatically:
   ```sh
   xcrun notarytool store-credentials MishMail-notary \
     --apple-id <you@example.com> --team-id XXXXXXXXXX --password <app-specific-pw>
   ```
   With the Developer ID identity and this profile in place, `make release`
   notarizes and staples the app before zipping — no manual steps.

Each user still needs their own Google OAuth client (see the README) — no
client secrets are ever committed. Building from source remains a first-class
path regardless of signing.

## Troubleshooting

- **`make release` stops at tests** — a test failed; the release is aborted
  before anything is published. Fix, commit, re-run.
- **"There is no XCFramework found at …" pointing at an old path** — the
  DerivedData cache went stale (e.g. the repo directory was moved/renamed).
  Fix: `rm -rf build/dd.noindex` and re-run; packages re-resolve on the next
  build.
- **"Refusing release: no valid signing identity"** — see
  [Signing tiers](#signing-tiers); usually a missing `Config/Local.xcconfig`
  or an expired Apple Development cert. A paid Developer ID is **not**
  required.
- **`gh release create` says the release exists** — you already released this
  version. Bump `MARKETING_VERSION` and try again, or delete the old release.
- **Updater doesn't offer the new version** — confirm the new
  `MARKETING_VERSION` is strictly greater than the installed one, the release
  isn't marked draft/prerelease, and the `.zip` asset is attached
  (`gh release view v<version>`).
- **"crash on launch — different Team IDs"** — hardened runtime + library
  validation rejecting the ad-hoc-signed GRDB framework. Already handled by
  `com.apple.security.cs.disable-library-validation` in `project.yml`; if you
  changed signing, make sure the app and its embedded frameworks share a team.
