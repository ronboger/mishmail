#!/bin/bash
# Dump the reading-pane perf timeline from the running/just-quit Debug app.
#
#   1) PERF=1 make run DEMO=1
#   2) open a conversation, then delete 4-5 in a row (d), pausing ~1s between
#   3) scripts/perf-capture.sh
#
# Reads the unified log, so it works after the app has quit.
MINUTES="${1:-10}"

log show --last "${MINUTES}m" --info \
  --predicate 'subsystem == "dev.ronboger.MishMail.perf"' \
  --style compact 2>/dev/null \
  | sed 's/.*\[dev\.ronboger\.MishMail\.perf:timing\] //' \
  | grep -E '^(open\.|nav\.|action\.|selection\.|reload\.total|list\.group)' \
  || echo "no perf events found — was the app launched with PERF=1 ?"
