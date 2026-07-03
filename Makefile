# PerfectMail — local CI. No GitHub remote by design, so this is the gate:
#   make test   before every commit (pre-commit hook runs it for you).

PROJECT = PerfectMail.xcodeproj

.PHONY: test build gen hooks

gen:
	xcodegen generate

test: gen
	xcodebuild test -project $(PROJECT) -scheme PerfectMailTests \
		-destination 'platform=macOS' -quiet

build: gen
	xcodebuild build -project $(PROJECT) -scheme PerfectMail \
		-destination 'platform=macOS' -quiet

# Install the pre-commit hook (run once per clone).
hooks:
	printf '#!/bin/sh\nexec make -C "$$(git rev-parse --show-toplevel)" test\n' > .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
	@echo "pre-commit hook installed (skip with git commit --no-verify)"
