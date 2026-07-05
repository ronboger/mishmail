# Snippets v2: slash trigger, move-to-bcc, sender variables — Design

Date: 2026-07-05
Status: approved for implementation (autonomous session; Ron asked to work to completion and merge)

## Motivation

Ron uses Notion Mail snippets heavily for intro-handling emails:

> "thanks {person_1} for the intro! moving to bcc. hi {person_2}, it'd be great
> to chat. my availability attached but also happy to work around your schedule"

PerfectMail already has snippets (DB table, `{{variable}}` expander, inline
panel, settings CRUD). This design closes the gaps with Notion Mail:

1. **Slash trigger**: typing `/` in the compose body pops a filtered snippet
   picker; typing narrows it; Enter inserts.
2. **Single-brace variables**: `{first_name}` works alongside `{{first_name}}`
   (Notion syntax; matches Ron's habit).
3. **Move-to-bcc action**: a per-snippet toggle. On insert into a reply, the
   current To recipients (the introducer) move to Bcc and any Cc recipients are
   promoted to To (standard intro etiquette).
4. **Sender + bcc variables**: `{my_name}`, `{my_first_name}` from the
   account's sender name; `{bcc_name}`, `{bcc_first_name}` refer to the person
   moved to Bcc (the introducer). `{first_name}`/`{name}`/`{email}` resolve
   against the first To recipient *after* the move — i.e. the new contact.
5. **Keyboard access**: ⌘/ toggles the snippets panel while composing (fixed
   shortcut — single-letter KeyBindings don't apply while a text field has
   focus). Documented in the ? cheat sheet's fixed section.

## Non-goals

- Per-snippet custom To/Cc/Subject content (Notion's "Add subject / Add to"):
  YAGNI for Ron's flow; only move-to-bcc is needed.
- Rich text snippets, attachments-in-snippets, icons.
- Rebindable ⌘/ (fixed, like Cmd-K).

## Approaches considered

- **A. Special syntax in the body** (e.g. `{{bcc}}` marker): fragile, invisible
  semantics, hard to edit. Rejected.
- **B. Per-snippet boolean `movesToBcc` (chosen)**: explicit toggle in the
  snippet editor, a "moves intro to Bcc" hint in lists, deterministic behavior.
- **C. Full per-snippet recipient templating**: most general, most UI, not
  needed. Rejected (YAGNI).

## Changes by component

### Store/Database.swift
- Migration `v9`: `ALTER TABLE snippet ADD COLUMN movesToBcc BOOLEAN NOT NULL
  DEFAULT 0`.
- `Snippet` gains `var movesToBcc: Bool = false`.

### Support/SnippetExpander.swift
- Accept single-brace `{var}` in addition to `{{var}}` (regex pass, same
  case-insensitive/whitespace-tolerant rules; unknown placeholders untouched).
- `Context` gains `myName: String` and `bccName: String`; new variables:
  `my_name`, `my_first_name`, `bcc_name`, `bcc_first_name`, `bcc_email`.

### Support/SnippetInsertion.swift (new, test-target)
- Pure helper `SnippetInsertion.apply(...)` that, given snippet +
  to/cc/bcc token arrays, returns the new token arrays (To→Bcc, Cc→To when
  `movesToBcc`) so recipient logic is unit-testable outside SwiftUI.
- Pure helper for slash-trigger parsing: given the body text and cursor-end
  state, find an active `/query` token at the end of the text (start of line or
  preceded by whitespace), return the query range so the UI can filter and
  replace. Lives here so it's unit-testable.

### UI/ComposeView.swift
- Slash trigger: on body change, detect active `/query` at end of text →
  show floating snippet picker (reuses SnippetsPanel look) above the footer;
  further typing filters; `.onKeyPress` handles ↑/↓/Enter/Esc while visible;
  Enter removes the `/query` text and inserts the expanded snippet.
- ⌘/ toggles the snippets panel (`showSnippets`).
- `insertSnippet` applies `SnippetInsertion.apply` to the token bindings and
  builds the richer expander context (sender name from account, bcc person =
  first To recipient pre-move).

### UI/SettingsView.swift (SnippetEditor + rows)
- "Move recipients to Bcc on insert" toggle in the editor; row hint when set.

### UI/ShortcutsHelpView.swift + docs
- Add ⌘/ and `/` trigger to the fixed-shortcut list; README shortcut section.

## Testing

- SnippetExpanderTests: single-brace syntax, my_name/my_first_name,
  bcc_* variables, mixed brace styles, unknown single-brace left alone.
- SnippetInsertionTests (new): move-to-bcc token shuffling (empty cc, empty to,
  dedupe), slash-token detection (start of text, mid-text after space, no
  trigger inside words/URLs, query extraction).
- Database migration covered by existing migrator test pattern (if present) —
  at minimum `make test` exercises the migration on a fresh DB.
- Manual: `make run`, compose, type `/`, pick snippet, verify recipient moves.

## Error handling

- No To recipient: `{first_name}` etc. expand to "" (existing behavior);
  move-to-bcc with empty To is a no-op; Cc still promotes.
- Slash picker with zero matches hides itself; `/` remains literal text.
