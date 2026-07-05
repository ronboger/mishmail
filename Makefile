# PerfectMail — build/test entrypoints.
#   make test   is the gate: run it before every commit (the pre-commit hook
#   from `make hooks` does it for you, and CI runs it on every push/PR).

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
