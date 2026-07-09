# PerfectMail — build/test entrypoints.
#
# Two apps come out of this project, and they are deliberately kept separate:
#
#   TESTING → `make run`      builds Debug and launches it. Shows up as
#                             "PerfectMail Debug" (dev.ronboger.PerfectMail.debug)
#                             with its own isolated data — throwaway, can't touch
#                             the real app. This is what you build to eyeball a change.
#   REAL    → `make install`  builds Release and installs "PerfectMail" into
#                             /Applications. This is your daily driver.
#
#   make test      is the gate: run it before every commit (the pre-commit
#                  hook from `make hooks` does it, and CI runs it on push/PR).
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

PROJECT = PerfectMail.xcodeproj
# Single source of truth for the version: MARKETING_VERSION in project.yml.
VERSION = $(shell awk '/MARKETING_VERSION:/ {print $$2}' project.yml)
# Derived data path — the .noindex suffix keeps every product out of Spotlight.
DD = build/dd.noindex
DEBUG_APP = $(DD)/Build/Products/Debug/PerfectMail Debug.app
RELEASE_APP = $(DD)/Build/Products/Release/PerfectMail.app
RELEASE_DIR = $(DD)/Build/Products/Release
ZIP_NAME = PerfectMail-$(VERSION).zip
# When Config/Local.xcconfig sets a DEVELOPMENT_TEAM, ship with Distribution
# entitlements (library validation ON). Ad-hoc default keeps the looser file.
TEAM = $(shell awk -F' *= *' '/^DEVELOPMENT_TEAM/ {print $$2; exit}' Config/Local.xcconfig 2>/dev/null)
ifneq ($(strip $(TEAM)),)
RELEASE_SIGN_FLAGS = CODE_SIGN_ENTITLEMENTS=Sources/PerfectMail/PerfectMail.Distribution.entitlements
else
RELEASE_SIGN_FLAGS =
endif

.PHONY: test build run demo install gen hooks release clean

gen:
	xcodegen generate

test: gen
	xcodebuild test -project $(PROJECT) -scheme PerfectMailTests \
		-destination 'platform=macOS' -derivedDataPath $(DD) -quiet

# The throwaway test app (Debug identity, isolated data).
build: gen
	xcodebuild build -project $(PROJECT) -scheme PerfectMail -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DD) -quiet

# Build the test app and launch it in place — the "let me look at my change"
# verb. Launches with the fictional demo inbox by default (see DemoSeed.swift)
# so debugging never involves real mail; `make run DEMO=0` gets the empty
# real-account Debug app for testing sign-in/sync.
DEMO ?= 1
run: build
	-pkill -f "PerfectMail Debug" 2>/dev/null || true
	open -n "$(DEBUG_APP)" --env PERFECTMAIL_DEMO=$(DEMO)

# Explicit alias for the screenshot/demo verb.
demo: build
	-pkill -f "PerfectMail Debug" 2>/dev/null || true
	open -n "$(DEBUG_APP)" --env PERFECTMAIL_DEMO=1

# Build Release and install it as your real /Applications app — the "ship it to
# my machine" verb. Replaces whatever PerfectMail.app is there.
install: gen
	xcodebuild build -project $(PROJECT) -scheme PerfectMail -configuration Release \
		-destination 'platform=macOS' -derivedDataPath $(DD) -quiet $(RELEASE_SIGN_FLAGS)
	rm -rf /Applications/PerfectMail.app
	ditto "$(RELEASE_APP)" /Applications/PerfectMail.app
	@echo "Installed PerfectMail.app → /Applications (your daily driver)."

# Build Release, zip the app bundle, write SHA256SUMS, and publish a GitHub
# release tagged v<MARKETING_VERSION>. The in-app updater verifies the zip
# against SHA256SUMS, then the app's code signature / Team ID / notarization.
# Bump MARKETING_VERSION in project.yml first; requires the gh CLI.
# When Config/Local.xcconfig has DEVELOPMENT_TEAM, builds with Distribution
# entitlements (full library validation).
release: test
	@if [ -n "$(TEAM)" ]; then \
		echo "Release signing team $(TEAM) — using PerfectMail.Distribution.entitlements"; \
	else \
		echo "No DEVELOPMENT_TEAM in Config/Local.xcconfig — ad-hoc Release (fine for self-update)"; \
	fi
	xcodebuild build -project $(PROJECT) -scheme PerfectMail -configuration Release \
		-destination 'platform=macOS' -derivedDataPath $(DD) -quiet $(RELEASE_SIGN_FLAGS)
	cd $(RELEASE_DIR) && \
		ditto -c -k --keepParent PerfectMail.app $(ZIP_NAME) && \
		shasum -a 256 $(ZIP_NAME) > SHA256SUMS && \
		echo "Checksum:" && cat SHA256SUMS
	gh release create v$(VERSION) \
		$(RELEASE_DIR)/$(ZIP_NAME) \
		$(RELEASE_DIR)/SHA256SUMS \
		--title "PerfectMail $(VERSION)" --generate-notes
	@echo "Released v$(VERSION) with SHA256SUMS — running apps will offer the update within a day."

# Reclaim all build output — the local ./build tree plus any stray per-project
# DerivedData caches Xcode may have left in ~/Library.
clean:
	rm -rf build
	rm -rf ~/Library/Developer/Xcode/DerivedData/PerfectMail-*
	@echo "Cleaned ./build and ~/Library DerivedData/PerfectMail-* caches."

# Install the pre-commit hook (run once per clone).
hooks:
	printf '#!/bin/sh\nexec make -C "$$(git rev-parse --show-toplevel)" test\n' > .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
	@echo "pre-commit hook installed (skip with git commit --no-verify)"
