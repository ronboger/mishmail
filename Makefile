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
# Everything lands in ./build (git-ignored); nothing is scattered in DerivedData.

PROJECT = PerfectMail.xcodeproj
# Single source of truth for the version: MARKETING_VERSION in project.yml.
VERSION = $(shell awk '/MARKETING_VERSION:/ {print $$2}' project.yml)
DEBUG_APP = build/Build/Products/Debug/PerfectMail Debug.app
RELEASE_APP = build/Build/Products/Release/PerfectMail.app

.PHONY: test build run install gen hooks release

gen:
	xcodegen generate
	@mkdir -p build && touch build/.metadata_never_index  # keep build products out of Spotlight/launcher

test: gen
	xcodebuild test -project $(PROJECT) -scheme PerfectMailTests \
		-destination 'platform=macOS' -derivedDataPath build -quiet

# The throwaway test app (Debug identity, isolated data).
build: gen
	xcodebuild build -project $(PROJECT) -scheme PerfectMail -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath build -quiet

# Build the test app and launch it in place — the "let me look at my change" verb.
run: build
	open "$(DEBUG_APP)"

# Build Release and install it as your real /Applications app — the "ship it to
# my machine" verb. Replaces whatever PerfectMail.app is there.
install: gen
	xcodebuild build -project $(PROJECT) -scheme PerfectMail -configuration Release \
		-destination 'platform=macOS' -derivedDataPath build -quiet
	rm -rf /Applications/PerfectMail.app
	ditto "$(RELEASE_APP)" /Applications/PerfectMail.app
	@echo "Installed PerfectMail.app → /Applications (your daily driver)."

# Build Release, zip the app bundle, and publish it as a GitHub release
# tagged v<MARKETING_VERSION>. The app's Settings → Updates pane (and the
# sidebar "Update app" button) pick it up from the GitHub Releases API.
# Bump MARKETING_VERSION in project.yml first; requires the gh CLI.
release: test
	xcodebuild build -project $(PROJECT) -scheme PerfectMail -configuration Release \
		-destination 'platform=macOS' -derivedDataPath build -quiet
	cd build/Build/Products/Release && \
		ditto -c -k --keepParent PerfectMail.app PerfectMail-$(VERSION).zip
	gh release create v$(VERSION) \
		build/Build/Products/Release/PerfectMail-$(VERSION).zip \
		--title "PerfectMail $(VERSION)" --generate-notes
	@echo "Released v$(VERSION) — running apps will offer the update within a day."

# Install the pre-commit hook (run once per clone).
hooks:
	printf '#!/bin/sh\nexec make -C "$$(git rev-parse --show-toplevel)" test\n' > .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
	@echo "pre-commit hook installed (skip with git commit --no-verify)"
