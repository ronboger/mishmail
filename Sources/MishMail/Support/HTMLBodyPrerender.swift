import AppKit
import Foundation
import WebKit

/// Offscreen pre-paint of neighbor-thread HTML into pooled `WKWebView`s.
///
/// After the open thread's body settles, previous/next newest-message HTML is
/// loaded into parked views (JS-off, remote images always blocked — see
/// `HTMLBodyPrerenderPolicy`). Up/down navigation can then claim a painted
/// view instead of starting a cold `loadHTMLString`. An open that allows
/// remote images uses a different pool key and will not reuse a blocked
/// pre-render.
///
/// Cancelled when the user navigates before work starts or completes. Oversized
/// bodies (`HTMLBodyRenderPolicy.requiresExplicitLoad`) are skipped.
@MainActor
enum HTMLBodyNeighborPrerender {
    /// Brief idle after the open body paints so j/k bursts don't thrash WebKit.
    static let settleNanoseconds: UInt64 = 80_000_000

    private static var generation = 0
    private static var task: Task<Void, Never>?

    /// Cancel in-flight pre-render work. Parked painted views are left for
    /// the next open to claim — discarding here races thread-to-thread mounts.
    static func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    /// Schedule prev/next pre-renders from neighbor ids + payload loader.
    ///
    /// `loadPayload` should hit `ThreadDetailRepository` (already warmed by
    /// `MailStore.scheduleNeighborPrefetch` when the open settled).
    ///
    /// Remote images are always blocked for neighbor pre-render (see
    /// `HTMLBodyPrerenderPolicy`) so focus-past-a-row never fires tracking
    /// pixels for mail the user never opened.
    static func schedule(
        openedThreadId: String,
        displayOrder: [String],
        fontScale: Double,
        loadPayload: @escaping (String) async -> ThreadDetailPayload
    ) {
        generation &+= 1
        let gen = generation
        task?.cancel()

        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: settleNanoseconds)
            } catch {
                return
            }
            guard gen == generation, !Task.isCancelled else { return }

            // Free slots for this neighborhood only after the open body has
            // claimed any matching pre-render (and after the settle delay).
            HTMLWebViewPool.discardAllPrerenders()

            let (prev, next) = NeighborPrefetch.neighbors(
                selected: openedThreadId, in: displayOrder)
            let neighborIds = [prev, next].compactMap { $0 }
            for threadId in neighborIds {
                guard gen == generation, !Task.isCancelled else { return }
                let payload = await loadPayload(threadId)
                guard gen == generation, !Task.isCancelled else { return }
                guard let message = ForwardComposer.newestSentMessage(
                    in: payload.messages) else { continue }
                guard let candidate = HTMLBodyPrerenderSelection.candidate(
                    messageId: message.id,
                    bodyHTML: message.bodyHTML) else { continue }

                let key = HTMLBodyLoadKey(
                    contentID: candidate.contentID,
                    allowRemoteImages: HTMLBodyPrerenderPolicy.allowRemoteImages,
                    fontScale: fontScale)
                if HTMLWebViewPool.hasPrerendered(for: key) { continue }

                await paintAndPark(candidate: candidate, key: key, generation: gen)
            }
        }
    }

    private static func paintAndPark(
        candidate: HTMLBodyPrerenderSelection.Candidate,
        key: HTMLBodyLoadKey,
        generation gen: Int
    ) async {
        guard gen == generation, !Task.isCancelled else { return }

        let webView = HTMLWebViewPool.dequeue()
        webView.setValue(false, forKey: "drawsBackground")
        // Park offscreen so layout still runs without flashing the UI.
        webView.frame = NSRect(x: -10_000, y: -10_000, width: 720, height: 900)

        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: key.allowRemoteImages)
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: key.fontScale)
        let document = HTMLBodyDocument.assemble(
            html: candidate.html, cspMeta: csp, styleCSS: css)
        let fallback = HTMLBodyDocument.trustedWrapper(
            html: candidate.html, cspMeta: csp, styleCSS: css)

        let painted: Bool = await withCheckedContinuation { continuation in
            let loader = PrerenderNavigationLoader { success in
                continuation.resume(returning: success)
            }
            // Retain loader for the navigation lifetime via the delegate slot.
            objc_setAssociatedObject(
                webView, prerenderLoaderAssocKey, loader,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            webView.navigationDelegate = loader
            loader.load(
                document: document,
                trustedFallback: fallback,
                allowRemoteImages: key.allowRemoteImages,
                in: webView)
        }

        // The one-shot loader has finished its navigation — drop the retain
        // so it does not live for the WebView's pooled lifetime.
        webView.navigationDelegate = nil
        objc_setAssociatedObject(
            webView, prerenderLoaderAssocKey, nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        guard gen == generation, !Task.isCancelled else {
            HTMLWebViewPool.recycle(webView)
            return
        }
        if painted {
            HTMLWebViewPool.parkPrerender(webView, for: key)
        } else {
            HTMLWebViewPool.recycle(webView)
        }
    }
}

/// Stable key for the associated-object retain below. `&` of a `static var`
/// does not guarantee a unique stable address across calls; a file-scope
/// allocation does.
private nonisolated(unsafe) let prerenderLoaderAssocKey: UnsafeMutableRawPointer =
    malloc(1)!

/// One-shot navigation delegate that finishes a continuation after first paint.
private final class PrerenderNavigationLoader: NSObject, WKNavigationDelegate {
    /// A pre-render that never terminates (WebKit stall, malformed document)
    /// must not pin its continuation — and with it a pooled WKWebView —
    /// forever. Local loadHTMLString paints settle well under a second.
    static let timeoutSeconds: TimeInterval = 5

    private let completion: (Bool) -> Void
    private var finished = false
    private var loadToken = UUID()
    private var navigationGate = HTMLNavigationIdentityGate()
    private var timeoutWork: DispatchWorkItem?

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    deinit {
        timeoutWork?.cancel()
    }

    func load(document: String, trustedFallback: String,
              allowRemoteImages: Bool, in webView: WKWebView) {
        let token = UUID()
        loadToken = token
        navigationGate.reset()
        // Deadline covers the whole pipeline: a rule-list callback that never
        // fires, a navigation that never commits, and a paint that never
        // reports all resolve the continuation as failed.
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(false)
        }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.timeoutSeconds, execute: timeout)
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()

        if allowRemoteImages {
            startNavigation(webView, document: document)
            return
        }

        HTMLRemoteImageBlocker.ruleList { [weak self, weak webView] ruleList in
            guard let self, let webView, self.loadToken == token else { return }
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            if let ruleList {
                controller.add(ruleList)
                self.startNavigation(webView, document: document)
            } else {
                self.startNavigation(webView, document: trustedFallback)
            }
        }
    }

    private func startNavigation(_ webView: WKWebView, document: String) {
        let navigation = webView.loadHTMLString(document, baseURL: nil)
        navigationGate.didStart(navigation)
    }

    private func finish(_ success: Bool) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        completion(success)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigationGate.accepts(navigation) else { return }
        // Install layout measure so the DOM settles before we park.
        webView.evaluateJavaScript(HTMLBodyLayout.installLayoutAndMeasureJS) { [weak self] _, _ in
            self?.finish(true)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        guard navigationGate.accepts(navigation) else { return }
        finish(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard navigationGate.accepts(navigation) else { return }
        finish(false)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            return
        }
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        if navigationAction.request.url == nil || scheme == "about" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}
