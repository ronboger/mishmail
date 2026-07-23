---
date: 2026-07-23 14:20
kind: adversarial-review (grok)
target: branch diff d3f2f95..91969ab (nav-speed merge)
verdict: needs-attention (H1-H4 fixed in 3ec8393)
job_id: areview-20260723T140516-46316
invoked_from: /Users/ronboger/berkeley/ron_perfect_email/.claude/worktrees/session-b27c91
git_branch: claude/email-nav-speed-proposal-755941
---

I'll adversarially review the two-branch perf merge against `d3f2f95`, focusing on races, WebView lifecycle, privacy, cache keying, and memory.Next I'll dig into the full implementations of cache keying, prerender claim/recycle, and WebView coordinator lifecycle.Checking a few more race details around abandon/recycle and height filtering:# Adversarial Review: MishMail thread-browse perf merge

**Base:** `d3f2f95` → `91969ab`  
**Scope:** instant open + cancel-on-supersede, off-main HTML prep, launch rule-list, WebView pool/prerender/double-buffer  
**Mode:** read-only (no file changes)

---

## 1. Severity-ordered findings

### Critical / High

#### H1. Double-buffer swap can double-own / double-recycle WebViews (lifecycle)

**Where:** `ThreadDetailView.swift` `Coordinator.swap` (~2210–2215), `revealIncoming` (~2412–2451), `dismantle` (~2328–2354); `WebViewPool.recycle` (~161–169)

**Bug:** Animated reveal captures `previous`/`next` and completes asynchronously (~80ms). A second `swap` (or `dismantle`) can recycle the same views again, while `finishSwap` still assigns `current = next` for a view already returned to the free list.

Concrete sequence:

1. `swap(B, alreadyPainted: true)` → `incoming = B`, starts fade, schedules `finishSwap` with `previous = A`.
2. Before completion, `updateNSView` → `swap(C)`: abandons `B` via `recycle(B)` **without** `removeFromSuperview`.
3. First `finishSwap` runs: `recycle(A)`, `current = B` (B is already free / possibly wiped).
4. Second `finishSwap` may `recycle(A)` again and promote `C`.

`recycle` has **no** “already pooled” guard:

```161:169:Sources/MishMail/Support/WebViewPool.swift
    static func recycle(_ webView: WKWebView) {
        clearForReuse(webView)
        guard let view = webView as? PassthroughWebView else { return }
        lock.lock()
        defer { lock.unlock() }
        guard ledger.parkedCount < capacity else { return }
        ledger.parkFree()
        free.append(view)
    }
```

**Impact:** Same `PassthroughWebView` can appear twice in `free`, or be both live `current` and pooled → wrong DOM, blank pane, or two coordinators fighting one view under rapid content-key changes (quote expand, Load images, font scale) or tear-down mid-fade.

**Triggers:** Not only j/k — any path that calls `swap` again within `swapFadeDuration` (0.08s), plus thread change during fade.

---

#### H2. Abandoned incoming stays in the view hierarchy while recycled

**Where:** `ThreadDetailView.swift:2211–2215`

```2211:2215:Sources/MishMail/UI/ThreadDetailView.swift
            if let abandoned = incoming, abandoned !== current {
                abandoned.navigationDelegate = nil
                abandoned.removeHeightHandlerIfNeeded()
                HTMLWebViewPool.recycle(abandoned)
            }
```

Failure paths *do* `removeFromSuperview` (~2475–2479); abandon does not.

**Impact:** Pooled view still parented under a live container; `clearForReuse` loads `""` into a subview that may still be on-screen (alpha 0). Next `dequeue` can hand out a view with a non-nil superview. Classic WebKit reuse bug; high under double-buffer churn.

---

#### H3. Privacy regression: shared ephemeral `WKWebsiteDataStore` across messages

**Where:** `WebViewPool.swift:40–53,55–58` vs pre-merge per-view `.nonPersistent()`

Pre-merge intentionally isolated cookies/cache per new view. Now:

```51:58:Sources/MishMail/Support/WebViewPool.swift
    /// Shared ephemeral store across pooled views — cookies/cache do not
    /// persist to disk. JS remains disabled on every configuration.
    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    ...
        config.websiteDataStore = sharedDataStore
```

**Impact:** With remote images allowed (policy always / VIP / Load images), trackers can set cookies in the shared store; later messages that allow images send those cookies. Disk persistence is still off; **cross-message session bleed** is new. JS-off is intact; content-rule blocking for Ask still applies per load — this is cookie/cache isolation, not CSP.

This is the strongest intentional privacy delta in the merge.

---

#### H4. Outgoing WebView height reports accepted during double-buffer → wrong height cache

**Where:** `ThreadDetailView.swift:2373–2400` vs reveal guard at 2402–2404

Reveal correctly requires `webView === incoming` when `incoming != nil`. Height apply does not:

```2373:2377:Sources/MishMail/UI/ThreadDetailView.swift
        private func applyMeasuredHeight(_ result: Any?, from webView: WKWebView? = nil) {
            guard acceptsHeightReports else { return }
            if let webView, let incoming, webView !== incoming, webView !== current {
                return
            }
```

With `incoming` set, **both** `current` (outgoing) and `incoming` pass. After `updateNSView` has already set `contentID` to the new key, an outgoing ResizeObserver tick can:

1. Publish the **old** document height into the **new** card binding  
2. `HTMLBodyHeightCacheStore.store(height, for: contentID)` under the **new** id  

Especially bad on prerender claim (`alreadyPainted` sets `acceptsHeightReports = true` immediately while outgoing is still live).

**Impact:** Sticky wrong card heights across opens; layout jumps that the height cache was meant to prevent.

---

### Medium

#### M1. `cancel()` leaves stale prerenders; only a later successful schedule discards

**Where:** `HTMLBodyPrerender.swift:22–28,53–55`; `ThreadDetailView.swift:404–405,503–504`

```22:28:Sources/MishMail/Support/HTMLBodyPrerender.swift
    /// Cancelled when the user navigates before work starts or completes. Parked painted views are left for
    /// the next open to claim — discarding here races thread-to-thread mounts.
    static func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
```

Under held j/k, open cancels prerender every hop; painted neighbors for threads you never stop on remain until some later open settles (~80ms) and runs `discardAllPrerenders()`. Claim keying by `messageId|r|f` avoids **wrong-message** paint, but **memory** of up to capacity painted DOMs accumulates during thrash.

---

#### M2. Prerender loader retained via associated object; incomplete detach on recycle

**Where:** `HTMLBodyPrerender.swift:100–114,129–130`; `WebViewPool.clearForReuse` never clears the assoc object

Loader is retained with `OBJC_ASSOCIATION_RETAIN_NONATOMIC`. `navigationDelegate = nil` does not drop it. Late `evaluateJavaScript` completion is mostly safe (`finished` + weak self), but:

- Loader (and its closure) live for the WebView’s lifetime  
- No generation/token invalidation on `stopLoading`  
- Cancelled paints still run to completion before the post-await `gen` check  

Wasted WebKit work under j/k; minor retain bloat.

---

#### M3. Payload LRU memory: 10 entries × up to 4 assembled documents each

**Where:** `ThreadDetailCache.swift:29–45,254–256,124–159`

Each prep can hold authored/full × blocked/allowed full HTML strings (CSP+CSS expanded). Plus raw `bodyHTML` on messages. Neighbor prefetch + browse-intent prefetch (`MailStore.swift:3161–3165,3216–3238`) fills the LRU aggressively.

**Impact:** Large transactional mail (near 2 MB auto budget) can push tens of MB of duplicated strings. Capacity 10 is intentional; growth is real and untested at scale. Height cache (64) is small by comparison.

---

#### M4. `messageBody` can mark whole cache entry `fontScale` without reassembling siblings

**Where:** `ThreadDetailCache.swift:314–320`

```314:320:Sources/MishMail/Support/ThreadDetailCache.swift
        if var entry = cache.value(for: loaded.threadId),
           let idx = entry.payload.messages.firstIndex(where: { $0.id == id }) {
            entry.payload.messages[idx] = loaded
            entry.payload.bodyPrepByMessageId[id] = prep
            entry.fontScale = fontScale
            cache.insert(entry, for: loaded.threadId)
        }
```

After a scale change, expanding one card sets `entry.fontScale` to the new scale while other messages keep old `documents.fontScale`. Later `payload()` cache hit skips `reassemblePayloadDocuments` (scale “matches”).

**Mitigation (display):** `MessageCard` drops preassembled when `abs(docs.fontScale - fontScale) >= 0.001` (~1474–1477) → main-thread assemble. **Correctness OK, cache correctness / perf not OK.** No test covers this.

---

#### M5. Neighbor prerender never sees thread/message image opt-in

**Where:** `ThreadDetailView.swift:754–760` always `messageOptIn: false, threadOptIn: false`

If user already chose Load images, live key is `r=1` but prerender parks `r=0` → claim miss (safe, just cold). Not a privacy bug; perf miss after opt-in.

---

#### M6. Height cache key ignores `fontScale` / `allowRemoteImages`

**Where:** `HTMLBodyPerformance.swift:21–47`; store at `ThreadDetailView.swift:2397–2398`

Only `contentID` (`messageId:authored|:full`). Scale or image policy change reuses stale height → brief wrong frame (then ResizeObserver corrects). Low–medium UX.

---

### Low

#### L1. `browseKeyIsRepeat` is sticky process state for browse opens

**Where:** `ContentView.swift:46,962–966,1003,1045–1047`

Set on every keyDown, never cleared on mouse/other intents. Clicks use `openDetail` directly (OK). Any future/non-key `.browse` path would inherit last key’s repeat flag. Edge case.

#### L2. Key-repeat settle 50 ms ≈ system repeat interval

**Where:** `SelectionAdvance.swift:154–161`

Coalesce window is tight; busy main thread can still open intermediate rows while holding j/k. Tradeoff, not a correctness bug; weaker than old 150 ms.

#### L3. `PrerenderNavigationLoader` always async `ruleList`, not `preparedRuleList`

**Where:** `HTMLBodyPrerender.swift:154–164`

Launch compile helps live path; prerender still hops async if cache cold. Minor.

#### L4. No discard of prerenders on memory pressure before drain

**Where:** `MishMailApp.swift:19–20` calls `HTMLWebViewPool.drain()` — OK. In-flight `paintAndPark` views are not parked yet and not drained until complete. Minor.

---

## 2. What looks solid

- **Cancel-on-supersede detail open:** `scheduleDetailSelection` cancels prior task; guards `selectedThreadId == id` (`ContentView.swift:1045–1058`). Generation guards on detail load (`ThreadDetailView.swift:398–414`).
- **Browse vs open separation:** List focus stays sync; only pane open is delayed on key-repeat. Auto-advance still immediate (`DetailOpenPolicy.opensImmediately`).
- **Document keying at paint time:** `MessageHTMLDocuments` stores both image policies; card picks by `allowRemoteImages` + authored/full; scale mismatch falls back to live assemble. Appearance via `prefers-color-scheme` in CSS is a sound single-document choice.
- **contentVersion invalidation:** repository still reloads on version mismatch; tests cover that path.
- **Oversized body policy:** prep skips auto documents above budget; prerender selection skips oversized — consistent with render policy.
- **JS-off:** still forced in `makeConfiguration()`; not weakened by prerender.
- **Remote-image rules on cold load:** `removeAllContentRuleLists` + sync `preparedRuleList` or fail-closed trusted wrapper; loadToken still gates async compile.
- **Prerender pool key** includes contentID + remote + fontScale (`poolKey`) — prevents cross-message claim.
- **Hostless tests** for ledger, prep assembly, selection settle policy are good unit coverage of pure logic.

---

## 3. Recommended next actions (smallest safe fixes)

1. **Fix double-buffer ownership (H1/H2)**  
   - On abandon: `removeFromSuperview` + recycle.  
   - Generation/token on each swap; `finishSwap` no-ops if superseded.  
   - `recycle`: ignore if already free/prerendered (identity set), or always `removeFromSuperview` first.  
   - Consider non-animated swap while `incoming != nil` or cancel in-flight animation explicitly.

2. **Height source filter (H4)** — one-liner intent:

   `when incoming != nil, only accept heights from incoming`  
   (mirror the reveal guard). Do not write height cache from outgoing.

3. **Shared data store (H3)** — pick one:
   - **Safest:** restore per-view non-persistent stores (accept more create cost), or  
   - **Middle:** shared store only for prerender free pool, **new store when `allowRemoteImages` becomes true**, or wipe website data on recycle when last load allowed images.

4. **Prerender cancel (M1/M2)**  
   - Clear associated loader on `clearForReuse`.  
   - Optionally `discardAllPrerenders()` on cancel after a short delay, or when `openedThreadId` changes if claim already attempted.

5. **Cache fontScale (M4)** — on `messageBody`, either don’t bump `entry.fontScale` until all preps reassembled, or call `reassemblePayloadDocuments` for the entry when scale changes.

6. **Tests the 772 don’t cover (highest value):**
   - Coordinator swap: abandon mid-fade → free list has unique views; no double append (host test with mock pool ledger + identity tracking).
   - Height apply with `incoming != nil` and synthetic messages from “outgoing” webView must not publish/store.
   - Repository: hydrate one body after fontScale change → sibling docs still get reassemble on next payload (or entry.fontScale stays old).
   - Optional: website data isolation policy test as a documented invariant comment + regression if you reintroduce per-view stores.

---

## Test-gap summary

| Area | Covered | Missing |
|------|---------|---------|
| Pool ledger / selection pure logic | Yes | Real pool double-recycle / superview |
| HTML prep assembly / byte budget | Yes | Partial fontScale cache update |
| Detail open settle policy | Yes | ContentView sticky `browseKeyIsRepeat`, j/k task cancel integration |
| contentVersion reload | Yes | Neighbor prefetch + prerender generation races |
| Height cache LRU | Yes | Wrong-source height under double-buffer; scale/remote in key |
| Remote image blocker | Existing suite | Claimed prerender keeps rules; shared store cookies |
| WebView lifecycle | None | Delegate/handler/animation races |

---

**Bottom line:** The architectural direction (0 ms single press, off-main prep, warm rule list, claimable prerenders) is coherent and the pure cache/key design is mostly sound. The dangerous surface is **WebView ownership under double-buffer supersede** (H1/H2) plus **height poisoning** (H4), and a **deliberate privacy tradeoff** on the shared data store (H3). I would not ship the double-buffer path without H1/H2/H4 fixed; H3 should be an explicit product decision, not an accidental comment flip.
