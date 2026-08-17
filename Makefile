# MishMail — build/test entrypoints.
#
# Two apps come out of this project, and they are deliberately kept separate:
#
#   TESTING → `make run`      builds Debug and launches it. Shows up as
#                             "MishMail Debug" (dev.ronboger.MishMail.debug)
#                             with its own isolated data — throwaway, can't touch
#                             the real app. This is what you build to eyeball a change.
#   REAL    → `make install`  builds Release and installs "MishMail" into
#                             /Applications. This is your daily driver.
#
#   make test      is the gate: run it before every commit (the pre-commit
#                  hook from `make hooks` does it).
#   make ui-test   is CI-only: XCUITest hijacks the desktop. CI is manual-dispatch
#                  now (gh workflow run CI --ref main) or release publish — run it
#                  after merging UI work. Locally it refuses unless UI_TEST_LOCAL=1.
#   make build     just compile the test (Debug) app; don't launch it.
#   make release   build Release, zip the app, publish a GitHub release
#                  (the in-app update checker looks at these releases).
#
# All build output lands in ./build/dd.noindex (git-ignored). The `.noindex`
# suffix is the one mechanism macOS reliably honors: Spotlight skips any path
# with a `.noindex` component (it's how Xcode hides its own Index.noindex), so
# throwaway Debug/Release builds never show up in the launcher or search. You
# launch the test app via `make run`; only the real /Applications app is indexed.
# `make clean` reclaims it all.

# xcodebuild folds the caller's PATH into its task signatures: a different
# PATH re-runs every Ld and CodeSign task, so builds from different shells
# (conda vs plain vs an agent) endlessly invalidate each other's incremental
# state. Pin PATH so every shell produces the same build graph.
export PATH := /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

PROJECT = MishMail.xcodeproj
# Single source of truth for the version: MARKETING_VERSION in project.yml.
# First match only — the app's. Without `exit`, a MARKETING_VERSION on any
# other target would silently make this "0.4.4 1.0" and take the whole release
# down at the ditto step.
VERSION = $(shell awk '/MARKETING_VERSION:/ {print $$2; exit}' project.yml)
# Derived data path — the .noindex suffix keeps every product out of Spotlight.
DD = build/dd.noindex
# Pin arch so xcodebuild doesn't warn about multiple matching destinations
# (arm64 + x86_64 "My Mac" on Apple Silicon).
DESTINATION = platform=macOS,arch=$(shell uname -m)
DEBUG_APP = $(DD)/Build/Products/Debug/MishMail Debug.app
RELEASE_APP = $(DD)/Build/Products/Release/MishMail.app
RELEASE_DIR = $(DD)/Build/Products/Release
# `make release` builds the same Release configuration as `make install`, but
# with different build settings (universal vs arm64-only, whole-module vs
# incremental, Distribution entitlements). xcodebuild folds settings into its
# task signatures, so sharing one derived-data path means every
# install→release→install alternation is a FULL rebuild of both. A separate
# path keeps `make install` at its ~5-12s incremental cost across releases.
SHIP_DD = build/ddship.noindex
SHIP_APP = $(SHIP_DD)/Build/Products/Release/MishMail.app
SHIP_DIR = $(SHIP_DD)/Build/Products/Release
ZIP_NAME = MishMail-$(VERSION).zip
# notarytool keychain profile used by `make release` (see release recipe).
NOTARY_PROFILE ?= MishMail-notary
# Real-account builds need a stable identity. Apple's free Personal Team is
# sufficient; the paid Developer Program is only needed for distribution.
# Ad-hoc builds are deliberately limited to compilation and the fictional demo:
# their designated requirement changes on every rebuild, which makes macOS ask
# for Keychain access again.
TEAM = $(strip $(shell awk -F' *= *' '/^DEVELOPMENT_TEAM/ {print $$2; exit}' Config/Local.xcconfig 2>/dev/null | tr -d '\r'))
VALID_SIGNING_IDENTITY = $(if $(strip $(TEAM)),$(shell python3 scripts/check_signing.py $(TEAM) any 2>/dev/null))
VALID_DEVELOPER_IDENTITY = $(if $(strip $(TEAM)),$(shell python3 scripts/check_signing.py $(TEAM) developer_id 2>/dev/null))
ifeq ($(VALID_SIGNING_IDENTITY),yes)
DEBUG_SIGN_FLAGS =
INSTALL_SIGN_FLAGS = MISHMAIL_APP_ENTITLEMENTS=Sources/MishMail/MishMail.Distribution.entitlements
else
DEBUG_SIGN_FLAGS = CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
INSTALL_SIGN_FLAGS = CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
	MISHMAIL_APP_ENTITLEMENTS=Sources/MishMail/MishMail.entitlements
endif

.PHONY: test ui-test build run demo install gen hooks release clean signing-doctor require-stable-signing require-run-signing require-pushed

# Refuse to ship an embedded relauncher that inherited the app's sandbox.
# Stripping com.apple.quarantine from the installed update is its entire job,
# the sandbox denies that silently (removexattr returns EPERM and nothing
# checks), and the result is an update that installs and then cannot be
# opened at all — which is exactly what 0.4.3 through 0.4.5 shipped. $(1) is
# the .app to check.
define check_relauncher
	@if codesign -d --entitlements - "$(1)/Contents/Library/MishMailRelauncher.app" 2>/dev/null \
		| grep -q "app-sandbox"; then \
		echo "Refusing: the embedded relauncher is sandboxed and cannot unquarantine"; \
		echo "the update it installs. Check MISHMAIL_APP_ENTITLEMENTS is used instead of"; \
		echo "a command-line CODE_SIGN_ENTITLEMENTS, which applies to every target."; \
		exit 1; \
	fi
	@echo "Relauncher is unsandboxed (can unquarantine the update)."
endef

gen:
	@# Worktrees lack the git-ignored Config/Local.xcconfig (personal signing
	@# identity), so their Debug builds fall back to ad-hoc signing — and every
	@# ad-hoc rebuild is a "new app" to the Keychain, which re-prompts for the
	@# stored OAuth tokens. Link the main checkout's copy in when one exists.
	@main_root=$$(dirname "$$(git rev-parse --path-format=absolute --git-common-dir)"); \
	if [ ! -e Config/Local.xcconfig ] && [ -f "$$main_root/Config/Local.xcconfig" ]; then \
		ln -s "$$main_root/Config/Local.xcconfig" Config/Local.xcconfig; \
		echo "Linked Config/Local.xcconfig from $$main_root (stable signing identity)"; \
	fi
	@# --use-cache: skip rewriting the .xcodeproj when project.yml is unchanged.
	@# An unconditional rewrite dirties the project file and forces xcodebuild
	@# into a full rebuild on every make invocation.
	xcodegen generate --use-cache

test: gen
	# No -quiet: show "Executed N tests" (silent pass looked like a no-op).
	xcodebuild test -project $(PROJECT) -scheme MishMailTests \
		-destination '$(DESTINATION)' -derivedDataPath $(DD)

# Small end-to-end pass over the fictional inbox. No Google account or network
# is involved; this catches launch, navigation, compose, and Settings regressions.
#
# CI-ONLY: XCUITest cannot run headless on macOS — it launches the app, takes
# focus, and injects keyboard/mouse events into the live desktop, so a local
# run hijacks the machine for its duration. CI (.github/workflows/ci.yml) is
# no longer push-triggered (Actions overuse): dispatch it manually after
# merging UI work with `gh workflow run CI --ref main`, or it runs on release
# publish. Locally the gate is `make test`. To run the UI suite here anyway
# (and surrender the desktop while it runs): UI_TEST_LOCAL=1 make ui-test
ui-test: gen
	@if [ "$$CI" != "true" ] && [ "$(UI_TEST_LOCAL)" != "1" ]; then \
		echo "ui-test is CI-only: XCUITest takes over the desktop while it runs."; \
		echo "CI runs it on every push/PR. To run locally anyway: UI_TEST_LOCAL=1 make ui-test"; \
		exit 1; \
	fi
	# XCUITest cannot attach deterministically when another Debug build with the
	# same bundle id is already open (for example from a different worktree).
	-pkill -f "MishMail Debug" 2>/dev/null || true
	# The throwaway Debug app persists window frames / prefs between runs;
	# the smoke test asserts default-launch geometry, so start clean.
	-defaults delete dev.ronboger.MishMail.debug 2>/dev/null || true
	xcodebuild test -project $(PROJECT) -scheme MishMailUITests \
		-destination '$(DESTINATION)' -derivedDataPath $(DD)

# The throwaway test app (Debug identity, isolated data).
build: gen
	xcodebuild build -project $(PROJECT) -scheme MishMail -configuration Debug \
		-destination '$(DESTINATION)' -derivedDataPath $(DD) -quiet $(DEBUG_SIGN_FLAGS)

# Build the test app and launch it in place — the "let me look at my change"
# verb. Launches with the fictional demo inbox by default (see DemoSeed.swift)
# so debugging never involves real mail; `make run DEMO=0` gets the empty
# real-account Debug app for testing sign-in/sync.
DEMO ?= 1
# Perf harness console logs: PERF=1 make run DEMO=0
# (signposts always emit; Console.app subsystem dev.ronboger.MishMail.perf)
PERF ?= 0
# Check signing before the build so a refusal doesn't cost a full compile.
require-run-signing:
	@if [ "$(DEMO)" != "1" ] && [ "$(VALID_SIGNING_IDENTITY)" != "yes" ]; then \
		echo "Refusing to launch a real inbox with an ad-hoc signature."; \
		echo "Ad-hoc rebuilds repeatedly ask for Keychain access."; \
		echo "Run 'make signing-doctor' for the free Personal Team setup."; \
		exit 1; \
	fi

run: require-run-signing build
	-pkill -f "MishMail Debug" 2>/dev/null || true
	open -n "$(DEBUG_APP)" --env MISHMAIL_DEMO=$(DEMO) --env MISHMAIL_PERF=$(PERF)

# Explicit alias for the screenshot/demo verb.
demo: build
	-pkill -f "MishMail Debug" 2>/dev/null || true
	open -n "$(DEBUG_APP)" --env MISHMAIL_DEMO=1

# Build Release and install it as your real /Applications app — the "ship it to
# my machine" verb. Replaces whatever MishMail.app is there. Never silently
# install ad-hoc: doing so changes MishMail's identity on the next rebuild and
# causes recurring Keychain prompts.
# Local-install speedups, deliberately NOT applied to `make release`:
# ONLY_ACTIVE_ARCH skips the x86_64 slice this Mac never runs, and
# incremental compilation recompiles only changed files (whole-module
# was one ~70s SwiftCompile after any edit). Optimization stays -O.
INSTALL_SPEED_FLAGS = ONLY_ACTIVE_ARCH=YES SWIFT_COMPILATION_MODE=incremental

install: gen require-stable-signing
	xcodebuild build -project $(PROJECT) -scheme MishMail -configuration Release \
		-destination '$(DESTINATION)' -derivedDataPath $(DD) -quiet \
		$(INSTALL_SPEED_FLAGS) $(INSTALL_SIGN_FLAGS)
	$(call check_relauncher,$(RELEASE_APP))
	rm -rf /Applications/MishMail.app
	ditto "$(RELEASE_APP)" /Applications/MishMail.app
	@echo "Installed MishMail.app → /Applications (your daily driver)."

signing-doctor:
	@if [ "$(VALID_SIGNING_IDENTITY)" = "yes" ]; then \
		echo "Ready: team $(TEAM) has a valid local code-signing identity."; \
	else \
		echo "MishMail needs stable signing before it can use a real inbox."; \
		echo ""; \
		echo "No paid Apple Developer membership is required:"; \
		echo "  1. Xcode → Settings → Apple Accounts → Add Apple Account"; \
		echo "  2. Select your free Personal Team → Manage Certificates"; \
		echo "  3. Click + → Apple Development"; \
		echo "  4. Put that Team ID in Config/Local.xcconfig (see README)"; \
		echo ""; \
		echo "The fictional demo remains available with: make run"; \
		exit 1; \
	fi

require-stable-signing:
	@if [ "$(VALID_SIGNING_IDENTITY)" != "yes" ]; then \
		echo "Refusing an ad-hoc MishMail install: it would repeatedly ask for Keychain access after rebuilds."; \
		echo "Run 'make signing-doctor' for the free Personal Team setup."; \
		exit 1; \
	fi

# `gh release create` tags whatever the REMOTE's main points at, not local
# HEAD. Cutting a release with the version bump still unpushed therefore
# publishes a correct zip under a tag whose source carries the *old* version,
# and anyone building from that tag gets the previous release (this happened
# on v0.4.1; see docs/RELEASING.md). Requiring HEAD to be exactly origin/main
# catches every shape of it at once — unpushed, behind, diverged, or released
# off a side branch — and the clean-tree check covers changes that would land
# in the zip but not the tag. Runs before `test` so it fails in a second
# rather than after the suite.
require-pushed:
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "Refusing release: the working tree isn't clean."; \
		echo "Uncommitted changes would ship inside the zip but not in the tagged source."; \
		git status --short; \
		exit 1; \
	fi
	@git fetch --quiet origin main || { \
		echo "Refusing release: couldn't fetch origin/main to check where the tag would land."; \
		exit 1; \
	}
	@head_sha=$$(git rev-parse HEAD); remote_sha=$$(git rev-parse FETCH_HEAD); \
	if [ "$$head_sha" != "$$remote_sha" ]; then \
		echo "Refusing release: HEAD is not what origin/main points at, so the tag"; \
		echo "would land on the wrong commit."; \
		echo "  HEAD         $$(git rev-parse --short HEAD)  $$(git log -1 --format=%s HEAD)"; \
		echo "  origin/main  $$(git rev-parse --short FETCH_HEAD)  $$(git log -1 --format=%s FETCH_HEAD)"; \
		echo ""; \
		echo "Push main (or check it out) and try again."; \
		exit 1; \
	fi

# Build Release, zip the app bundle, write SHA256SUMS, and publish a GitHub
# release tagged v<MARKETING_VERSION>. The in-app updater verifies the zip
# against SHA256SUMS, then the app's code signature / Team ID / notarization.
# Bump MARKETING_VERSION in project.yml first; requires the gh CLI.
# Two signing tiers (see docs/RELEASING.md "Signing tiers"):
#   - Developer ID identity present  -> Manual Developer ID signing + notarize.
#   - Otherwise, free Personal Team  -> Apple Development signing, no
#     notarization. Existing installs on the same Team ID update fine (this is
#     how every release to date has shipped); other people's Macs get
#     Gatekeeper warnings and should build from source.
# Both tiers use Distribution entitlements (full library validation).
release: require-pushed test
	@if [ -z "$(TEAM)" ] || [ "$(VALID_SIGNING_IDENTITY)" != "yes" ]; then \
		echo "Refusing release: no valid signing identity for DEVELOPMENT_TEAM in Config/Local.xcconfig."; \
		echo "Run 'make signing-doctor' for the free Personal Team setup."; \
		exit 1; \
	fi
	@if [ "$(VALID_DEVELOPER_IDENTITY)" = "yes" ]; then \
		echo "Release signing team $(TEAM) with Developer ID (will notarize)."; \
	else \
		echo "Release signing team $(TEAM) with Apple Development (free Personal Team, no notarization)."; \
		echo "Existing installs on team $(TEAM) update fine; strangers' Macs will see Gatekeeper warnings."; \
	fi
	@if [ "$(VALID_DEVELOPER_IDENTITY)" = "yes" ]; then \
		xcodebuild build -project $(PROJECT) -scheme MishMail -configuration Release \
			-destination '$(DESTINATION)' -derivedDataPath $(SHIP_DD) -quiet \
			CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=$(TEAM) \
			MISHMAIL_APP_ENTITLEMENTS=Sources/MishMail/MishMail.Distribution.entitlements; \
	else \
		xcodebuild build -project $(PROJECT) -scheme MishMail -configuration Release \
			-destination '$(DESTINATION)' -derivedDataPath $(SHIP_DD) -quiet \
			MISHMAIL_APP_ENTITLEMENTS=Sources/MishMail/MishMail.Distribution.entitlements; \
	fi
	# Notarize and staple (Developer ID builds only): the in-app updater and
	# Gatekeeper both reject un-notarized Developer ID builds. One-time setup:
	#   xcrun notarytool store-credentials $(NOTARY_PROFILE) \
	#     --apple-id <appleid> --team-id $(TEAM) --password <app-specific-pw>
	@if [ "$(VALID_DEVELOPER_IDENTITY)" = "yes" ]; then \
		cd $(SHIP_DIR) && \
		ditto -c -k --keepParent MishMail.app notarize-upload.zip && \
		xcrun notarytool submit notarize-upload.zip \
			--keychain-profile $(NOTARY_PROFILE) --wait && \
		rm notarize-upload.zip && \
		xcrun stapler staple MishMail.app; \
	fi
	$(call check_relauncher,$(SHIP_APP))
	cd $(SHIP_DIR) && \
		ditto -c -k --keepParent MishMail.app $(ZIP_NAME) && \
		shasum -a 256 $(ZIP_NAME) > SHA256SUMS && \
		echo "Checksum:" && cat SHA256SUMS
	gh release create v$(VERSION) \
		$(SHIP_DIR)/$(ZIP_NAME) \
		$(SHIP_DIR)/SHA256SUMS \
		--title "MishMail $(VERSION)" --generate-notes
	@echo "Released v$(VERSION) with SHA256SUMS — running apps will offer the update within a day."

# Reclaim all build output — the local ./build tree plus any stray per-project
# DerivedData caches Xcode may have left in ~/Library.
clean:
	rm -rf build
	rm -rf ~/Library/Developer/Xcode/DerivedData/MishMail-*
	@echo "Cleaned ./build and ~/Library DerivedData/MishMail-* caches."

# Install the pre-commit hook (run once per clone).
hooks:
	printf '#!/bin/sh\nexec make -C "$$(git rev-parse --show-toplevel)" test\n' > .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
	@echo "pre-commit hook installed (skip with git commit --no-verify)"
