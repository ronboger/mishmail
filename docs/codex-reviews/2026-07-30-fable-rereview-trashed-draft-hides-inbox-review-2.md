---
date: 2026-07-30
kind: fable-rereview
target: fix/trashed-draft-hides-inbox vs main
model: claude-fable-5
effort: low
pass: 2
reviewed_commit: 5a11d228fb3fc6e2abdee4464c50d39aeb9d32d2
verdict: SHIP
note: jacq-claude failed (CLAUDE_CONFIG_DIR auth); review via direct claude CLI with same model/effort/flags
---

# Fable Re-review Pass 2 — trashed-draft hides inbox

This was a read-only review, not an implementation plan, so there's nothing to approve — the review stands as delivered above.

**Verdict: SHIP** — M1 addressed, all other findings verified resolved, only a self-healing cosmetic nit (union under-reporting TRASH after an explicit untrash until next sync) remains.
