# PerfectMail — build/test entrypoints.
#   make test      is the gate: run it before every commit (the pre-commit
#                  hook from `make hooks` does it, and CI runs it on push/PR).
#   make release   build Release, zip the app, publish a GitHub release
#                  (the in-app update checker looks at these releases).

PROJECT = PerfectMail.xcodeproj
# Single source of truth for the version: MARKETING_VERSION in project.yml.
VERSION = $(shell awk '/MARKETING_VERSION:/ {print $$2}' project.yml)

.PHONY: test build gen hooks release

gen:
	xcodegen generate

test: gen
	xcodebuild test -project $(PROJECT) -scheme PerfectMailTests \
		-destination 'platform=macOS' -quiet

build: gen
	xcodebuild build -project $(PROJECT) -scheme PerfectMail \
		-destination 'platform=macOS' -quiet

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
