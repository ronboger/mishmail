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

PROJECT = MishMail.xcodeproj
# Single source of truth for the version: MARKETING_VERSION in project.yml.
VERSION = $(shell awk '/MARKETING_VERSION:/ {print $$2}' project.yml)
# Derived data path — the .noindex suffix keeps every product out of Spotlight.
DD = build/dd.noindex
# Pin arch so xcodebuild doesn't warn about multiple matching destinations
# (arm64 + x86_64 "My Mac" on Apple Silicon).
DESTINATION = platform=macOS,arch=$(shell uname -m)
DEBUG_APP = $(DD)/Build/Products/Debug/MishMail Debug.app
RELEASE_APP = $(DD)/Build/Products/Release/MishMail.app
RELEASE_DIR = $(DD)/Build/Products/Release
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
INSTALL_SIGN_FLAGS = CODE_SIGN_ENTITLEMENTS=Sources/MishMail/MishMail.Distribution.entitlements
else
DEBUG_SIGN_FLAGS = CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
INSTALL_SIGN_FLAGS = CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
	CODE_SIGN_ENTITLEMENTS=Sources/MishMail/MishMail.entitlements
endif

.PHONY: test ui-test build run demo install gen hooks release clean signing-doctor require-stable-signing require-run-signing

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
	xcodegen generate

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
install: gen require-stable-signing
	xcodebuild build -project $(PROJECT) -scheme MishMail -configuration Release \
		-destination '$(DESTINATION)' -derivedDataPath $(DD) -quiet $(INSTALL_SIGN_FLAGS)
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

# Build Release, zip the app bundle, write SHA256SUMS, and publish a GitHub
# release tagged v<MARKETING_VERSION>. The in-app updater verifies the zip
# against SHA256SUMS, then the app's code signature / Team ID / notarization.
# Bump MARKETING_VERSION in project.yml first; requires the gh CLI.
# When Config/Local.xcconfig has DEVELOPMENT_TEAM, builds with Distribution
# entitlements (full library validation).
release: test
	@if [ -n "$(TEAM)" ] && [ "$(VALID_DEVELOPER_IDENTITY)" = "yes" ]; then \
		echo "Release signing team $(TEAM) — using MishMail.Distribution.entitlements"; \
	else \
		echo "Refusing public release: a paid-program Developer ID Application identity and notarization are required for distribution to other Macs."; \
		exit 1; \
	fi
	xcodebuild build -project $(PROJECT) -scheme MishMail -configuration Release \
		-destination '$(DESTINATION)' -derivedDataPath $(DD) -quiet \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=$(TEAM) \
		CODE_SIGN_ENTITLEMENTS=Sources/MishMail/MishMail.Distribution.entitlements
	# Notarize and staple: the in-app updater and Gatekeeper both reject
	# un-notarized Developer ID builds. One-time setup:
	#   xcrun notarytool store-credentials $(NOTARY_PROFILE) \
	#     --apple-id <appleid> --team-id $(TEAM) --password <app-specific-pw>
	cd $(RELEASE_DIR) && \
		ditto -c -k --keepParent MishMail.app notarize-upload.zip && \
		xcrun notarytool submit notarize-upload.zip \
			--keychain-profile $(NOTARY_PROFILE) --wait && \
		rm notarize-upload.zip && \
		xcrun stapler staple MishMail.app
	cd $(RELEASE_DIR) && \
		ditto -c -k --keepParent MishMail.app $(ZIP_NAME) && \
		shasum -a 256 $(ZIP_NAME) > SHA256SUMS && \
		echo "Checksum:" && cat SHA256SUMS
	gh release create v$(VERSION) \
		$(RELEASE_DIR)/$(ZIP_NAME) \
		$(RELEASE_DIR)/SHA256SUMS \
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
