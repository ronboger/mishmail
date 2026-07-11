# Report phishing — deferred

**Status:** not shipping. Left as a conscious product gap vs Notion Mail.

## Why Notion can show it and we don't (yet)

Notion Mail's ⋯ menu offers **Report phishing** alongside spam/block. MishMail
uses the same **public Gmail REST API** (personal OAuth Desktop client). That
API has no documented `reportPhishing` (or equivalent) endpoint.

What *is* available:

- Add `SPAM` / remove `INBOX` — what **Mark as spam** already does
- Local **Block sender** (blocklist → future mail to Spam)

Gmail web/app "Report phishing" feeds Google's abuse / Safe Browsing pipeline.
Third-party clients cannot call that path through the public API. Notion either:

1. Maps the menu label to mark-as-spam (and/or block) for UX parity, and/or
2. Has partner/internal access we shouldn't assume for a BYO OAuth client.

We deliberately **do not** label mark-as-spam as "Report phishing" — that would
imply a Google phishing signal we cannot guarantee.

## If we add it later

Honest options only:

| Option | Behavior |
|--------|----------|
| Soft map | Mark spam (+ optional block) with copy like "Report as phishing (moves to Spam)" |
| Hand off | Open the thread in Gmail so the user can use Google's real control |
| Skip | Keep current ⋯ menu (spam / block / open in Gmail) — status quo |

Do not invent a local "phishing report" that pretends to notify Google.

## Related

- Reading-pane ⋯ menu: `ThreadDetailView` (spam, block, open in Gmail)
- Spam shortcut `!`: `ShortcutCommand.markSpam` / Settings → Keyboard shortcuts
