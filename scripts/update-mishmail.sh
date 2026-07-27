#!/bin/bash
# Install the latest MishMail release over an existing one, from the terminal.
#
#   scripts/update-mishmail.sh                    # update /Applications/MishMail.app
#   scripts/update-mishmail.sh ~/Apps/MishMail.app # or wherever it lives
#
# From 0.4.1 on the app updates itself (Settings → Updates → Install and
# Relaunch), so this exists for two cases:
#
#   1. Crossing *to* 0.4.1. Older builds tag every download as quarantined,
#      and Gatekeeper refuses to launch a quarantined build that isn't
#      notarized — which these, signed with a free Personal Team, never are.
#      Updating through the old in-app flow therefore ends at a Finder drag
#      and a trip through System Settings → "Open Anyway".
#   2. Recovery, if an in-place update ever fails and leaves you clicking
#      "Update" against something that won't install.
#
# The checks mirror the in-app updater: SHA-256 against the published
# SHA256SUMS, a full code-signature check, and Team ID continuity with the app
# being replaced — a stranger's Developer ID can't take over your install even
# if the GitHub account is compromised.

set -euo pipefail

REPO="ronboger/mishmail"
TARGET="${1:-/Applications/MishMail.app}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ -d "$TARGET" ] || die "no app at $TARGET (pass its path as the first argument)"

# Team ID of the install we're replacing. Empty means ad-hoc: those builds
# come from source, and `make install` is the way to update them.
team_of() {
  codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'
}
INSTALLED_TEAM="$(team_of "$TARGET")"
[ -n "$INSTALLED_TEAM" ] && [ "$INSTALLED_TEAM" != "not set" ] \
  || die "$TARGET is ad-hoc signed (built from source) — update it with 'make install'"

command -v curl >/dev/null || die "curl not found"

printf 'Looking up the latest release…\n'
API="https://api.github.com/repos/$REPO/releases/latest"
RELEASE_JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API")" \
  || die "couldn't reach the GitHub releases API"
# Ask python for the fields rather than grepping the JSON: asset names carry
# the version, so a regex over the whole payload picks up the wrong URLs.
# Assigned in its own step because a failure inside a here-string's command
# substitution wouldn't stop the script.
FIELDS="$(printf '%s' "$RELEASE_JSON" | python3 -c '
import json, sys
rel = json.load(sys.stdin)
assets = {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}
zip_url = next((u for n, u in assets.items() if n.endswith(".zip")), "")
sums = assets.get("SHA256SUMS", "")
if not zip_url or not sums:
    sys.exit("release is missing a .zip or SHA256SUMS asset")
print(rel["tag_name"], zip_url, sums)
')" || die "couldn'\''t read the latest release"
read -r TAG ZIP_URL SUMS_URL <<<"$FIELDS"

version_of() {
  plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist" 2>/dev/null
}
VERSION="${TAG#v}"
CURRENT="$(version_of "$TARGET" || echo '?')"
if [ "$VERSION" = "$CURRENT" ]; then
  printf 'Already on %s.\n' "$CURRENT"
  exit 0
fi
printf 'Updating MishMail %s → %s\n' "$CURRENT" "$VERSION"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

ZIP_NAME="$(basename "$ZIP_URL")"
curl -fsSL -o "$ZIP_NAME" "$ZIP_URL"
curl -fsSL -o SHA256SUMS "$SUMS_URL"

printf 'Verifying checksum…\n'
# --ignore-missing: SHA256SUMS may list assets we didn't download.
shasum -a 256 -c --ignore-missing SHA256SUMS >/dev/null \
  || die "SHA-256 did not match the published checksum"

ditto -x -k "$ZIP_NAME" extract
NEW_APP="$(find extract -maxdepth 2 -name '*.app' -print -quit)"
[ -n "$NEW_APP" ] || die "release archive contained no .app"

printf 'Verifying signature…\n'
codesign --verify --deep --strict "$NEW_APP" 2>/dev/null \
  || die "code signature on the downloaded app is invalid"

NEW_TEAM="$(team_of "$NEW_APP")"
[ "$NEW_TEAM" = "$INSTALLED_TEAM" ] \
  || die "Team ID mismatch (installed $INSTALLED_TEAM, download ${NEW_TEAM:-ad-hoc})"

NEW_VERSION="$(version_of "$NEW_APP")"
# The tag is attacker-controlled if the GitHub account is; the bundle version
# inside the signature is not. Without this, an old signed build could be
# republished under a higher tag to roll the install backwards.
[ "$NEW_VERSION" = "$VERSION" ] \
  || die "release $VERSION contains MishMail $NEW_VERSION"

# Belt-and-braces: curl doesn't quarantine what it downloads, so this is
# normally a no-op. If something did tag it, Gatekeeper reads the attribute on
# the bundle root, and the app is verified against the running install's own
# identity — a stronger claim than Gatekeeper can make about an un-notarized
# build. Leaving a tag on would only mean macOS refusing to launch what we
# just checked. (`xattr` here has no -r; the root is the part that counts.)
xattr -d com.apple.quarantine "$NEW_APP" 2>/dev/null || true

if pgrep -qx MishMail; then
  printf 'Quitting MishMail…\n'
  osascript -e 'quit app "MishMail"' 2>/dev/null || true
  for _ in $(seq 30); do pgrep -qx MishMail || break; sleep 0.2; done
  pgrep -qx MishMail && die "MishMail is still running — quit it and try again"
fi

printf 'Installing…\n'
BACKUP="$WORK/previous-MishMail.app"
mv "$TARGET" "$BACKUP"
if ! ditto "$NEW_APP" "$TARGET"; then
  mv "$BACKUP" "$TARGET"
  die "install failed; the previous version has been put back"
fi

printf 'Installed MishMail %s. Launching…\n' "$VERSION"
open "$TARGET"
