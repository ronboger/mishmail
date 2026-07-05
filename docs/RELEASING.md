# Releasing PerfectMail

PerfectMail ships as a signed `.app` published to **GitHub Releases**
(`ronboger/perfectmail`). Running copies check that repo about once a day and
surface an **Update app** button (sidebar + Settings → Updates) when a newer
version exists. Cutting a release = building Release, zipping the app, and
creating a GitHub release tagged `v<version>`.

There are three "apps" the Makefile can produce — don't confuse them:

| Command | Config | What it is |
|---|---|---|
| `make run` | Debug | Throwaway **"PerfectMail Debug"** with isolated data. For eyeballing a change. Never shipped. |
| `make install` | Release | Installs the real **PerfectMail.app** into `/Applications` (your daily driver). Local only — does **not** publish. |
| `make release` | Release | Builds Release, zips it, and **publishes a GitHub release** everyone's updater sees. |

`make install` is "ship it to my machine." `make release` is "ship it to
everyone." This doc is about `make release`.

## Prerequisites (one-time)

- **`gh` CLI authenticated** with push access to `ronboger/perfectmail`:
  ```sh
  gh auth status        # expect: Logged in to github.com as ronboger
  ```
- **`xcodegen`** installed (`brew install xcodegen`) — the Makefile regenerates
  the project from `project.yml` on every build.
- **Signing**: the tracked default is ad-hoc + hardened runtime, which runs
  fine locally but is **not** distributable to other machines without warnings.
  For a real public release, sign with a Developer ID and notarize — see
  [Distributable signing](#distributable-signing-developer-id) below. For a
  personal / self-update release on your own machines, the ad-hoc default works.

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
   builds Release, zips the app, and creates the GitHub release. It will refuse
   to proceed if tests fail.
   ```sh
   make release
   ```
   This runs, in order:
   - `make test` (gate — must pass)
   - `xcodebuild ... -configuration Release` → `build/Build/Products/Release/PerfectMail.app`
   - `ditto -c -k --keepParent PerfectMail.app PerfectMail-<version>.zip`
   - `gh release create v<version> …PerfectMail-<version>.zip --generate-notes`

5. **Verify.**
   ```sh
   gh release view v0.2.0 --web     # opens the release; confirm the zip is attached
   ```
   Running apps pick it up within ~a day, or immediately via **Settings →
   Updates → Check for Updates**.

## Tag & version rules

- **Tag format is `v<MARKETING_VERSION>`** (e.g. `v0.2.0`) — `make release`
  derives it automatically. Don't create the tag by hand.
- The updater compares `MARKETING_VERSION` strings, so **the version must
  strictly increase** or existing installs won't offer the update.
- **One release per version.** `gh release create` fails if `v<version>`
  already exists — if you need to redo a release, delete the old one first
  (`gh release delete v0.2.0 --cleanup-tag`) or bump to a new version (cleaner).

## Distributable signing (Developer ID)

The ad-hoc default is fine for your own machines but Gatekeeper will warn other
users. To ship a binary anyone can open:

1. Create `Config/Local.xcconfig` (git-ignored) with a Developer ID identity:
   ```
   CODE_SIGN_STYLE = Manual
   DEVELOPMENT_TEAM = XXXXXXXXXX
   CODE_SIGN_IDENTITY = Developer ID Application
   ```
   Keep `ENABLE_HARDENED_RUNTIME` on (it already is in `project.yml`).
2. Build Release, then **notarize** the zip before (or instead of) attaching it:
   ```sh
   xcrun notarytool submit PerfectMail-<version>.zip \
     --apple-id <you@example.com> --team-id XXXXXXXXXX --wait
   xcrun stapler staple build/Build/Products/Release/PerfectMail.app
   ```
   Re-zip after stapling if you notarized the app rather than the zip.

Each user still needs their own Google OAuth client (see the README), so
building from source remains a first-class path regardless of signing.

## Troubleshooting

- **`make release` stops at tests** — a test failed; the release is aborted
  before anything is published. Fix, commit, re-run.
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
