#!/usr/bin/env python3
"""Set each tracked file's mtime to the time of the last commit that touched it.

A fresh checkout stamps every file with "now", and xcodebuild treats a newer
mtime as a changed input, so a restored DerivedData cache would rebuild
everything. With commit times, only files that really changed since the cached
build look new. Needs full history (`fetch-depth: 0`).
"""
import os
import subprocess

log = subprocess.run(
    ["git", "log", "--format=%x00%ct", "--name-only", "--no-renames"],
    check=True, capture_output=True, text=True).stdout

remaining = set(subprocess.run(
    ["git", "ls-files"], check=True, capture_output=True, text=True
).stdout.splitlines())

stamp = 0
done = 0
for line in log.splitlines():
    if line.startswith("\x00"):
        stamp = int(line[1:])
    elif line in remaining:          # newest commit first: first hit wins
        remaining.discard(line)
        if os.path.isfile(line) and not os.path.islink(line):
            os.utime(line, (stamp, stamp))
            done += 1
    if not remaining:
        break
print(f"restored mtimes for {done} files")
