---
date: 2026-08-02
kind: fable-iterate review
branch: jacq/ship-20260802T020134-76019
implementer_model: grok-4.5 (verified via jacq-grok status --json)
grok_jobs:
  - ship-20260802T020134-76019 (initial implementation)
  - rescue-20260802T020620-78727 (project.yml test-target fix)
reviewed_commit: 6a5f2a9 (fix: add FuzzySearch.swift to MishMailTests target sources)
base_commit: ad32c37 (main)
verdict: SHIP
---

# Review: fuzzy typo-tolerant fallback for local search

## Scope

User report: searching "levi" surfaces Levi's promos, but "levis" returns
nothing. Root cause: local search is strict FTS5 prefix matching over
subject/fromHeader; the unicode61 tokenizer splits "Levi's" into `levi` + `s`,
so the token `levis` exists nowhere and there was no fallback.

## Changes reviewed (5 files, +422)

- **Database.swift** — migration `v31` creates `message_fts_vocab`
  (`fts5vocab('message_fts', 'row')`) with a warning comment that future FTS
  rebuilds must drop/recreate the vocab table first. Correct placement after
  v30; vocab tables are views over the live index, so no backfill needed.
- **FuzzySearch.swift** (new) — pure bounded Damerau–Levenshtein candidate
  ranking (distance 1 for len 3–5, 2 for len ≥ 6; rank by distance → shared
  prefix → length → lexicographic) plus `expandedPattern(db:text:)` that pulls
  a length-banded, doc-frequency-capped (5000) slice of the vocab per token
  and builds an AND-of-OR-groups raw FTS5 pattern, `*`-suffixed on the last
  token group only. Pattern validated via `db.makeFTS5Pattern(rawPattern:
  forTable:)` under `try?` so malformed patterns can never throw out of the
  search path. Returns nil when no token gained an alternative.
- **MailStore.swift** (committed search, ~L2108) — fuzzy re-query only when
  the strict FTS id fetch is empty; all other filters/ordering untouched.
- **ThreadTypeahead.swift** — same fallback-only retry via a shared private
  `fetchMatching` helper; strict results never re-ranked or diluted.
- **project.yml** — FuzzySearch.swift added to the explicit MishMailTests
  sources list (rescue job; the initial ship missed that this target
  enumerates Support files instead of globbing, which broke the build).

## Verification

- `make test` in the worktree: **1207 tests, 0 failures** (5 skipped),
  TEST SUCCEEDED. First run failed to build ("Cannot find 'FuzzySearch' in
  scope") → rescue fix → clean pass.
- Targeted `-only-testing:MishMailTests/FuzzySearchTests`: **10/10 passed**,
  including the user's exact scenario (seeded "Levi's Jeans - 40% off";
  query "levis" finds it; "levi" still finds it; garbage finds nothing;
  strict hits not diluted; multi-token "levis jeans" works).
- Caution for future runs: a background `xcodebuild` launched from the main
  checkout silently "succeeded" with 0 tests executed — always confirm the
  cwd/worktree in the log before trusting a pass.

## Notes / accepted trade-offs

- Fuzzy expansion only runs when strict search is empty, so the per-keystroke
  hot path (prefix FTS with 2/3-char prefix indexes) is unchanged. The vocab
  scan (ORDER BY doc DESC LIMIT 5000 per token) is bounded and only paid on
  zero-hit queries.
- Tokenization in FuzzySearch is a documented unicode61 approximation
  (lowercase, split on non-alphanumerics) — acceptable for candidate ranking;
  actual matching still goes through real FTS5.
- Server search (`searchAllGmail`) intentionally untouched.
- No unrequested changes found in the diff.

## Verdict

**SHIP** — merged to main.
