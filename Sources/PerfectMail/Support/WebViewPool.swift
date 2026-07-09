import AppKit
import WebKit

/// Scroll events pass through to the enclosing SwiftUI `ScrollView` so the
/// message pane never traps the wheel/trackpad.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// Shared configuration + small recycle pool for HTML email `WKWebView`s.
///
/// Creating a `WKWebView` is expensive (process + configuration). The reading
/// pane expands/collapses cards frequently, so we:
/// 1. Share one ephemeral, JS-off configuration across all instances.
/// 2. Keep up to `capacity` views after dismantle, clearing the DOM first.
enum HTMLWebViewPool {
    static let capacity = 3

    private static let lock = NSLock()
    private static var pool: [PassthroughWebView] = []

    /// Ephemeral store + JS disabled. Safe to reuse for many web views.
    static let sharedConfiguration: WKWebViewConfiguration = {
        makeConfiguration()
    }()

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // Ephemeral store: any remote image an email is allowed to load can't
        // drop cookies/cache that persist or bleed across accounts.
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
        return PassthroughWebView(frame: .zero, configuration: sharedConfiguration)
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
