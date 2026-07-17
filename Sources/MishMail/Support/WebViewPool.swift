import AppKit
import WebKit

/// Scroll events pass through to the enclosing SwiftUI `ScrollView` so the
/// message pane never traps the wheel/trackpad.
final class PassthroughWebView: WKWebView {
    /// Tracks whether `HTMLBodyLayout.heightHandlerName` is registered on this
    /// view's `userContentController`. `removeScriptMessageHandler` raises if
    /// the name is absent, so we only remove when we know we added it.
    var hasHeightMessageHandler = false

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

/// Small recycle pool for HTML email `WKWebView`s.
///
/// Creating a `WKWebView` is expensive. The reading pane expands/collapses
/// cards frequently, so we keep up to `capacity` views after dismantle,
/// clearing the DOM first. Each *new* view gets its own ephemeral data store
/// (JS off) so remote-image cookies/cache do not bleed across messages;
/// a recycled view reuses its instance store after DOM clear.
enum HTMLWebViewPool {
    // A single warm spare avoids repeated construction while bounding idle
    // WebKit DOM/process memory after moving between HTML-heavy threads.
    static let capacity = 1

    private static let lock = NSLock()
    private static var pool: [PassthroughWebView] = []

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // Fresh non-persistent store per new view: cookies/cache do not
        // persist to disk and do not share with other message views.
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

    /// Dequeue a recycled view or create a new one.
    static func dequeue() -> PassthroughWebView {
        lock.lock()
        let recycled = pool.popLast()
        lock.unlock()
        if let recycled {
            return recycled
        }
        return PassthroughWebView(frame: .zero, configuration: makeConfiguration())
    }

    /// Drop heavy DOM and return the view to the pool (or let it deallocate).
    ///
    /// Callers must remove any `WKScriptMessageHandler` they registered (e.g.
    /// `HTMLBodyLayout.heightHandlerName`) *before* recycle — a recycled view
    /// reuses its `WKUserContentController`, and double-adding a handler name
    /// crashes. Layout teardown JS runs first so ResizeObservers from the
    /// previous message cannot fire into a deallocated coordinator.
    static func recycle(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        // Best-effort: disconnect ResizeObserver before wiping the DOM.
        webView.evaluateJavaScript(HTMLBodyLayout.teardownJS, completionHandler: nil)
        if let view = webView as? PassthroughWebView {
            view.removeHeightHandlerIfNeeded()
        } else {
            // Non-pooled path (shouldn't happen for HTML bodies).
            webView.configuration.userContentController
                .removeScriptMessageHandler(forName: HTMLBodyLayout.heightHandlerName)
        }
        // Release the previous message's DOM/images before parking or dropping.
        webView.loadHTMLString("", baseURL: nil)
        guard let view = webView as? PassthroughWebView else { return }
        lock.lock()
        defer { lock.unlock() }
        guard pool.count < capacity else { return }
        pool.append(view)
    }

    /// Release the warm spare under memory pressure or when a caller wants to
    /// return WebKit memory to the system. Active message views are untouched.
    static func drain() {
        lock.lock()
        let drained = pool
        pool.removeAll()
        lock.unlock()
        // Keep deallocation outside the pool lock; WebKit teardown can do
        // substantial work even though these views already have empty DOMs.
        withExtendedLifetime(drained) {}
    }
}
