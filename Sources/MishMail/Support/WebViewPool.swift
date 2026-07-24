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

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // Per-view ephemeral store: recycled views keep their store, but a
        // view only ever renders one message at a time and the store dies
        // with the view — never shared across live views.
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

    /// Dequeue a recycled/empty view or create a new one. May steal the oldest
    /// pre-render when the free list is empty so total parked stay bounded.
    ///
    /// Stolen pre-renders still show foreign HTML until the async blank load
    /// commits — they are flagged `hasForeignContent` so attachers hide them.
    /// Free-list views were already cleared when parked and are not flagged.
    static func dequeue() -> PassthroughWebView {
        lock.lock()
        let acquire = ledger.acquireForDequeue()
        switch acquire {
        case .free:
            // Still flagged from clearForReuse when parked: the blank load is
            // async and may not have committed yet, so the previous document
            // (possibly an unopened neighbor's pre-render) could still be the
            // live DOM. Attachers keep flagged views hidden until own paint.
            let view = free.popLast()!
            lock.unlock()
            return view
        case .stolenPrerender(let key):
            let view = prerendered.removeValue(forKey: key)!
            lock.unlock()
            clearForReuse(view)
            return view
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
    static func recycle(_ webView: WKWebView) {
        clearForReuse(webView)
        guard let view = webView as? PassthroughWebView else { return }
        lock.lock()
        defer { lock.unlock() }
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
    /// views are untouched.
    static func drain() {
        lock.lock()
        let drained = free + Array(prerendered.values)
        free.removeAll()
        prerendered.removeAll()
        ledger.drain()
        lock.unlock()
        withExtendedLifetime(drained) {}
    }

    /// Wipe navigation state and DOM so the view is safe to reuse or drop.
    private static func clearForReuse(_ webView: WKWebView) {
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
        // The blank load above is async: until it commits, the previous
        // document is still the live DOM. Flag the view so attachers hide it
        // until its own content paints; cleared in attach()/swap().
        if let view = webView as? PassthroughWebView {
            view.hasForeignContent = true
        }
    }
}
