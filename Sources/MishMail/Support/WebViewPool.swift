import AppKit
import WebKit

/// Scroll events pass through to the enclosing SwiftUI `ScrollView` so the
/// message pane never traps the wheel/trackpad.
final class PassthroughWebView: WKWebView {
    /// Tracks whether `HTMLBodyLayout.heightHandlerName` is registered on this
    /// view's `userContentController`. `removeScriptMessageHandler` raises if
    /// the name is absent, so we only remove when we know we added it.
    var hasHeightMessageHandler = false
    /// Set when this view was stolen from a pre-render slot and still holds
    /// another message's painted DOM (blank load is async). Callers must keep
    /// it at alpha 0 until its own first navigation commits.
    var hasForeignContent = false

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    func installHeightHandler(_ handler: WKScriptMessageHandler) {
        if hasHeightMessageHandler {
            configuration.userContentController
                .removeScriptMessageHandler(forName: HTMLBodyLayout.heightHandlerName)
            hasHeightMessageHandler = false
        }
        configuration.userContentController
            .add(handler, name: HTMLBodyLayout.heightHandlerName)
        hasHeightMessageHandler = true
    }

    func removeHeightHandlerIfNeeded() {
        guard hasHeightMessageHandler else { return }
        configuration.userContentController
            .removeScriptMessageHandler(forName: HTMLBodyLayout.heightHandlerName)
        hasHeightMessageHandler = false
    }
}

/// Small recycle + pre-render pool for HTML email `WKWebView`s.
///
/// Creating a `WKWebView` is expensive. The reading pane expands/collapses
/// cards and browses neighbors frequently, so we keep up to `capacity` views
/// parked after dismantle (empty free slots and/or pre-painted neighbors).
/// Each view gets its own ephemeral `WKWebsiteDataStore.nonPersistent()` so
/// cookies set by one message's remote images never accompany another
/// message's requests (JS stays off). Remote-image content rules are applied
/// per load by the caller.
enum HTMLWebViewPool {
    /// Current body + prev/next pre-renders. Bound total live parked views.
    static let capacity = 3

    private static let lock = NSLock()
    private static var free: [PassthroughWebView] = []
    private static var prerendered: [String: PassthroughWebView] = [:]
    private static var ledger = HTMLWebViewPoolLedger(capacity: capacity)
    /// Bumped by `drain()`. Pending post-wipe park callbacks capture it and
    /// refuse to repopulate a pool that memory pressure explicitly emptied.
    private static var generation = 0

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // Per-view ephemeral store, wiped on every recycle (clearForReuse):
        // one message's remote-image cookies never accompany the next
        // message's requests, and the store dies with the view regardless.
        config.websiteDataStore = .nonPersistent()
        // Per-element contrast from effective background (before first paint).
        // App-injected user scripts run even with allowsContentJavaScript off;
        // email content scripts stay disabled.
        let contrast = WKUserScript(
            source: HTMLBodyDarkMode.applyContrastJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true)
        config.userContentController.addUserScript(contrast)
        return config
    }

    /// Claim a pre-painted view for `key`, if one is parked.
    static func claimPrerendered(for key: HTMLBodyLoadKey) -> PassthroughWebView? {
        let poolKey = key.poolKey
        lock.lock()
        guard ledger.claimPrerender(key: poolKey),
              let view = prerendered.removeValue(forKey: poolKey) else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return view
    }

    /// True when a painted view is parked for `key` (does not claim).
    static func hasPrerendered(for key: HTMLBodyLoadKey) -> Bool {
        let poolKey = key.poolKey
        lock.lock()
        defer { lock.unlock() }
        return prerendered[poolKey] != nil
    }

    /// Dequeue a recycled/empty view or create a new one. May evict the
    /// oldest pre-render when the free list is empty: the evicted view wipes
    /// and re-parks as a free slot (net parked count unchanged — the caller
    /// gets a fresh view rather than one mid-wipe).
    ///
    /// Free-list views are flagged `hasForeignContent` from clearForReuse:
    /// the blank load is async and may not have committed yet, so the
    /// previous document could still be the live DOM. Attachers keep flagged
    /// views hidden until own paint.
    static func dequeue() -> PassthroughWebView {
        lock.lock()
        let acquire = ledger.acquireForDequeue()
        switch acquire {
        case .free:
            let view = free.popLast()!
            lock.unlock()
            return view
        case .stolenPrerender(let key):
            let view = prerendered.removeValue(forKey: key)!
            let gen = generation
            lock.unlock()
            // The stolen view holds another message's DOM *and* network
            // state; the wipe (including the data-store removal) is async.
            // Hand out a fresh view now and park the stolen one only after
            // its wipe completes, so no load ever races the deletion.
            clearForReuse(view) { parkFreeIfRoom(view, generation: gen) }
            return PassthroughWebView(frame: .zero, configuration: makeConfiguration())
        case .createNew:
            lock.unlock()
            return PassthroughWebView(frame: .zero, configuration: makeConfiguration())
        }
    }

    /// Park a view that already painted `key`. DOM is kept. May drop an older
    /// free slot or pre-render to stay within capacity.
    static func parkPrerender(_ webView: PassthroughWebView, for key: HTMLBodyLoadKey) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeHeightHandlerIfNeeded()
        let poolKey = key.poolKey
        // Hold the lock across the whole ledger + dictionary mutation —
        // dropping it mid-way lets a concurrent dequeue()/claim desync the
        // ledger from `prerendered` and hit dequeue's force unwraps. WebKit
        // cleanup on evicted views runs after unlock instead.
        var evicted: [PassthroughWebView] = []
        lock.lock()
        // Replace existing slot for the same key.
        if let previous = prerendered.removeValue(forKey: poolKey) {
            _ = ledger.claimPrerender(key: poolKey)
            evicted.append(previous)
        }
        let droppedKey = ledger.parkPrerender(key: poolKey)
        if let droppedKey, let dropped = prerendered.removeValue(forKey: droppedKey) {
            evicted.append(dropped)
        }
        // Free slots may have been trimmed by the ledger without a key.
        while free.count > ledger.freeCount {
            evicted.append(free.removeFirst())
        }
        let parked = ledger.prerenderOrder.contains(poolKey)
        if parked {
            prerendered[poolKey] = webView
        }
        lock.unlock()

        for view in evicted {
            clearForReuse(view)
        }
        withExtendedLifetime(evicted) {}
        if !parked {
            // No room — drop the view.
            clearForReuse(webView)
            withExtendedLifetime(webView) {}
        }
    }

    /// Drop heavy DOM and return the view to the free pool (or deallocate).
    ///
    /// Callers must remove any `WKScriptMessageHandler` they registered (e.g.
    /// `HTMLBodyLayout.heightHandlerName`) *before* recycle — a recycled view
    /// reuses its `WKUserContentController`, and double-adding a handler name
    /// crashes. Layout teardown JS runs first so ResizeObservers from the
    /// previous message cannot fire into a deallocated coordinator.
    ///
    /// Parking waits for the data-store wipe inside clearForReuse: a dequeued
    /// view never shares cookies/cache with the message it previously held.
    static func recycle(_ webView: WKWebView) {
        lock.lock()
        let gen = generation
        lock.unlock()
        clearForReuse(webView) {
            guard let view = webView as? PassthroughWebView else { return }
            parkFreeIfRoom(view, generation: gen)
        }
    }

    /// Park a wiped view on the free list, room permitting. Only called from
    /// `clearForReuse`'s post-wipe completion, and only honored when the pool
    /// hasn't been drained since the wipe started.
    private static func parkFreeIfRoom(_ view: PassthroughWebView, generation gen: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard gen == generation else { return }
        // A superseded swap and its completion handler can both try to
        // recycle the same view — never park the same instance twice.
        guard !free.contains(where: { $0 === view }),
              !prerendered.values.contains(where: { $0 === view }) else { return }
        guard ledger.parkedCount < capacity else { return }
        ledger.parkFree()
        free.append(view)
    }

    /// Drop every pre-painted neighbor (navigation cancelled / new thread).
    static func discardAllPrerenders() {
        lock.lock()
        let dropped = Array(prerendered.values)
        prerendered.removeAll()
        ledger.discardAllPrerenders()
        lock.unlock()
        for view in dropped {
            clearForReuse(view)
        }
        withExtendedLifetime(dropped) {}
    }

    /// Release warm spares under memory pressure or app exit. Active message
    /// views are untouched. Bumps the generation so wipe completions already
    /// in flight cannot refill the pool after it was explicitly emptied.
    static func drain() {
        lock.lock()
        generation += 1
        let drained = free + Array(prerendered.values)
        free.removeAll()
        prerendered.removeAll()
        ledger.drain()
        lock.unlock()
        withExtendedLifetime(drained) {}
    }

    /// Wipe navigation state, DOM, and network state so the view is safe to
    /// reuse or drop. `completion` fires after the data-store removal lands —
    /// callers that park the view for reuse must park from there, never
    /// before (a dequeued view's first load must not race the deletion);
    /// callers dropping the view pass nil.
    private static func clearForReuse(_ webView: WKWebView, completion: (() -> Void)? = nil) {
        // Flag FIRST: the blank load and data-store removal below are async,
        // and their completion can run (and re-park the view) on the main
        // queue before this function returns on another thread. Until the
        // blank load commits, the previous document is still the live DOM —
        // attachers hide flagged views until their own content paints;
        // cleared in attach()/swap().
        if let view = webView as? PassthroughWebView {
            view.hasForeignContent = true
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        // A pooled view must never stay parented to a live container —
        // dequeue would otherwise hand out a view still in the hierarchy.
        webView.removeFromSuperview()
        // Best-effort: disconnect ResizeObserver before wiping the DOM.
        webView.evaluateJavaScript(HTMLBodyLayout.teardownJS, completionHandler: nil)
        if let view = webView as? PassthroughWebView {
            view.removeHeightHandlerIfNeeded()
        } else {
            webView.configuration.userContentController
                .removeScriptMessageHandler(forName: HTMLBodyLayout.heightHandlerName)
        }
        webView.configuration.userContentController.removeAllContentRuleLists()
        webView.loadHTMLString("", baseURL: nil)
        // Wipe network state too: the per-view ephemeral store keeps cookies/
        // cache otherwise, and a reused view must not carry one message's (or
        // one account's) remote-image state into the next message's loads.
        // Parked pre-renders keep their store on purpose — same message.
        webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast) { completion?() }
    }
}
