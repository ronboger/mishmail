# review: Review working tree diff

- Job: review-ms748cx3-s8brrs
- Kind: review
- Workspace: /Users/ronboger/mishmail
- Started: 2026-07-30T06:11:27.230Z
- Completed: 2026-07-30T06:13:35.326Z
- Codex session: 019fb1a6-36c0-7763-865c-929667b76805

---

# Codex Review

Target: working tree diff

Two intended privacy protections remain bypassable: unrelated SPF/DKIM success is treated as authenticating the visible sender, and asynchronous website-data deletion does not complete before a web view is reused.

Full review comments:

- [P2] Require From-domain alignment before trusting authentication — /Users/ronboger/mishmail/Sources/MishMail/Gmail/MessageParsing.swift:64-66
  When a message spoofs a VIP in `From:` but legitimately passes SPF or DKIM for an attacker-controlled domain (for example, `spf=pass smtp.mailfrom=evil.example; dmarc=fail`), this returns true and automatically loads the attacker's tracking images. SPF/DKIM pass alone does not authenticate the visible sender unless its domain aligns with `From:`; require an aligned DMARC pass or explicitly validate the authenticated identifiers against the sender domain.

- [P2] Wait for website-data removal before pooling the view — /Users/ronboger/mishmail/Sources/MishMail/Support/WebViewPool.swift:235-237
  When a recycled view is dequeued immediately, `removeData` may still be running because its completion is ignored, so the next message can begin remote-image requests with the previous message's cookies/cache; the deletion may also complete during the new load. Keep the view unavailable until the completion fires, or replace its data store/view before returning it to the pool.
