#!/bin/sh
# Delete local branches whose work has landed, and remove their worktrees.
# Run by the post-merge hook (`make hooks`) and by `make prune`.
#
# Two sets of branches are candidates:
#   - every branch merged into main;
#   - the branches named as arguments, when they are merged into HEAD. The
#     post-merge hook passes the branches that `git merge` just merged.
#
# "Merged into the current branch" alone is NOT a candidate rule: a branch's
# own base (for example improve/pass under a topic branch) is always its
# ancestor, and must survive.
#
# A candidate is left alone when:
#   - it is main, master, or the current branch;
#   - it was never committed to (its reflog holds only the creation entry),
#     so a branch that was just created for new work is not treated as merged;
#   - its worktree has uncommitted changes.
set -eu

current=$(git symbolic-ref --quiet --short HEAD || true)
main_worktree=$(git worktree list --porcelain | sed -n '1s/^worktree //p')

candidates=$(
    if git show-ref --verify --quiet refs/heads/main; then
        git for-each-ref --format='%(refname:short)' --merged main refs/heads
    fi
    for branch in "$@"; do
        git show-ref --verify --quiet "refs/heads/$branch" &&
            git merge-base --is-ancestor "$branch" HEAD && echo "$branch"
    done
)

printf '%s\n' "$candidates" | sort -u | while read -r branch; do
    [ -n "$branch" ] || continue
    case "$branch" in main|master|"$current") continue ;; esac
    [ "$(git reflog show "$branch" 2>/dev/null | wc -l)" -gt 1 ] || continue

    worktree=$(git worktree list --porcelain | awk -v ref="refs/heads/$branch" '
        /^worktree / { path = substr($0, 10) }
        /^branch /   { if ($2 == ref) print path }')
    if [ -n "$worktree" ]; then
        [ "$worktree" = "$main_worktree" ] && continue
        if [ -n "$(git -C "$worktree" status --porcelain)" ]; then
            echo "prune-merged: kept $branch (uncommitted changes in $worktree)"
            continue
        fi
        git worktree remove "$worktree" || continue
    fi
    # -D: `git branch -d` refuses a branch merged into main but not into HEAD.
    git branch -q -D "$branch" && echo "prune-merged: removed $branch"
done
