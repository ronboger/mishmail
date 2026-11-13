import AppKit
import WebKit
import XCTest

/// Runs the real layout script in a WKWebView and mirrors the reading pane's
/// measure → frame loop: every published height becomes the view's frame
/// (as `.frame(height: htmlHeight)` does), which is also the page viewport.
/// Mail sized in viewport units used to walk the card through many heights
/// right after open (visible jitter in the thread view).
@MainActor
final class HTMLBodyHeightLoopTests: XCTestCase {
    private final class Host: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let webView: WKWebView
        var stability = HTMLHeightStability()
        var reports = 0
        var published: [CGFloat] = []

        init(width: CGFloat) {
            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            config.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 120),
                                configuration: config)
            super.init()
            config.userContentController.add(self, name: HTMLBodyLayout.heightHandlerName)
            webView.navigationDelegate = self
        }

        func apply(_ body: Any?) {
            guard let n = body as? NSNumber else { return }
            reports += 1
            let observation = stability.observe(
                HTMLBodyLayout.clampContentHeight(CGFloat(truncating: n)))
            guard observation.shouldPublish else { return }
            let height = observation.height
            published.append(height)
            DispatchQueue.main.async {
                var frame = self.webView.frame
                frame.size.height = height
                self.webView.frame = frame
            }
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            apply(message.body)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(HTMLBodyLayout.installLayoutAndMeasureJS) { result, _ in
                self.apply(result)
            }
        }
    }

    private func publishedHeights(for html: String) async throws -> [CGFloat] {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = Host(width: 640)
        window.contentView?.addSubview(host.webView)
        defer {
            host.webView.configuration.userContentController
                .removeScriptMessageHandler(forName: HTMLBodyLayout.heightHandlerName)
            host.webView.removeFromSuperview()
        }
        let document = HTMLBodyDocument.assemble(
            html: html,
            cspMeta: HTMLBodyCSP.metaTag(allowRemoteImages: false),
            styleCSS: HTMLBodyDarkMode.injectedCSS(fontScale: 1.0))
        host.webView.loadHTMLString(document, baseURL: nil)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        if host.reports == 0 {
            throw XCTSkip("WebKit produced no height reports in this environment")
        }
        return host.published
    }

    private static let viewportSizedBodies: [(String, String)] = [
        ("flex min-height 90vh", """
        <div style="display:flex;flex-direction:column;min-height:90vh">\
        <div style="flex:1">a</div><div>footer</div></div>
        """),
        ("table min-height 80vh", "<table style=\"min-height:80vh;width:100%\"><tr><td>row</td></tr></table>"),
        ("calc 100vh", "<div style=\"height:calc(100vh - 20px)\">calc</div><p>tail</p>"),
        ("padding 50vh", "<div style=\"padding-bottom:50vh\">pad</div>"),
        ("stylesheet vh", """
        <style>.hero{min-height:60vh;padding:5vh 0} @media screen{.x{height:40dvh}}</style>\
        <div class=hero><p>h</p></div><div class=x>x</div>
        """),
        ("vmin padding", "<div style=\"padding:10vmin\">vmin</div>"),
    ]

    func testViewportSizedMailSettlesInOneHeight() async throws {
        for (name, html) in Self.viewportSizedBodies {
            let heights = try await publishedHeights(for: html)
            XCTAssertEqual(heights.count, 1, "\(name) published \(heights)")
        }
    }

    func testViewportLengthsArePinnedNotCollapsed() async throws {
        // padding-bottom:50vh keeps its space (pinned to px), it does not
        // track the card frame.
        let heights = try await publishedHeights(
            for: "<div style=\"padding-bottom:50vh\">pad</div>")
        let expected = CGFloat(HTMLBodyLayout.pinnedViewportHeight) / 2
        XCTAssertGreaterThan(heights.last ?? 0, expected)
    }
}
