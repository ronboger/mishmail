#!/bin/sh
# Installed as .git/hooks/post-merge by `make hooks`.
# The reflog subject of a merge is "merge <branch>...: <result>"; pass those
# branch names to the prune script.
script="$(git rev-parse --show-toplevel)/scripts/prune-merged.sh"
[ -x "$script" ] || exit 0
subject=$(git reflog -1 --format=%gs)
case "$subject" in
    "merge "*) merged=$(printf '%s' "$subject" | sed -e 's/^merge //' -e 's/: .*$//') ;;
    *) merged="" ;;
esac
# shellcheck disable=SC2086  # word splitting is the point: octopus merges
"$script" $merged
exit 0
