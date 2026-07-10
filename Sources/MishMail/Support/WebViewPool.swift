import AppKit
import WebKit

/// Scroll events pass through to the enclosing SwiftUI `ScrollView` so the
/// message pane never traps the wheel/trackpad.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
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
    static let capacity = 3

    private static let lock = NSLock()
    private static var pool: [PassthroughWebView] = []

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // Fresh non-persistent store per new view: cookies/cache do not
        // persist to disk and do not share with other message views.
        config.websiteDataStore = .nonPersistent()
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
    static func recycle(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        // Release the previous message's DOM/images before parking or dropping.
        webView.loadHTMLString("", baseURL: nil)
        guard let view = webView as? PassthroughWebView else { return }
        lock.lock()
        defer { lock.unlock() }
        guard pool.count < capacity else { return }
        pool.append(view)
    }
}
