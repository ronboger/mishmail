#!/bin/bash
# Claude Code PostToolUse hook: surface build warnings from make/xcodebuild
# runs so the agent fixes them instead of ignoring them.
# Reads the hook JSON on stdin; emits additionalContext JSON when warnings exist.
set -u

input=$(cat)

# Only act on build commands; the settings-level "if" filter is not honored
# by all Claude Code versions, so gate here too.
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
case "$cmd" in
  make\ *|make|xcodebuild\ *) ;;
  *) exit 0 ;;
esac

out=$(printf '%s' "$input" | jq -r '
  .tool_response
  | if type == "object" then ((.stdout // "") + "\n" + (.stderr // ""))
    else tostring end' 2>/dev/null)

warnings=$(printf '%s' "$out" \
  | grep -E 'warning: ' \
  | grep -vE 'directory not found for option|duplicate -rpath|ignoring duplicate libraries|will be run during every build|Metadata extraction skipped|search path .* not found' \
  | sort -u | head -40)

if [ -n "$warnings" ]; then
  jq -n --arg w "$warnings" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("The build completed but emitted compiler/build warnings. Treat these as work to do now: fix each warning in the source (do not suppress them) before considering the task done.\n\n" + $w)
    }
  }'
fi
exit 0
