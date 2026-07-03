import SwiftUI
import WebKit

struct ThreadDetailView: View {
    @EnvironmentObject var store: MailStore
    let thread: MailThread
    let onReply: (Message) -> Void

    @State private var messages: [Message] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .padding(.horizontal)
                ForEach(messages) { message in
                    MessageCard(message: message,
                                isLast: message.id == messages.last?.id,
                                onReply: { onReply(message) })
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { store.archive(thread) } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                Button { store.toggleStar(thread) } label: {
                    Label("Star", systemImage: thread.isStarred ? "star.fill" : "star")
                }
                Button(role: .destructive) { store.trash(thread) } label: {
                    Label("Trash", systemImage: "trash")
                }
                if let last = messages.last {
                    Button { onReply(last) } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                }
            }
        }
        .task(id: thread.id) {
            messages = store.messages(inThread: thread.id)
            if thread.isUnread { store.setRead(thread, read: true) }
        }
    }
}

struct MessageCard: View {
    @EnvironmentObject var store: MailStore
    let message: Message
    let isLast: Bool
    let onReply: () -> Void
    @State private var expanded: Bool
    @State private var htmlHeight: CGFloat = 120
    @State private var loadRemoteImages = false

    init(message: Message, isLast: Bool, onReply: @escaping () -> Void) {
        self.message = message
        self.isLast = isLast
        self.onReply = onReply
        _expanded = State(initialValue: isLast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(MessageParser.displayName(fromHeader: message.fromHeader))
                        .font(.system(size: 13, weight: .semibold))
                        .textSelection(.enabled)
                    if expanded {
                        Text("to \(message.toHeader)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if expanded, message.bodyHTML != nil, !loadRemoteImages {
                    Button("Load images") { loadRemoteImages = true }
                        .buttonStyle(.link).font(.caption)
                        .help("Remote images are blocked by default (they can track opens)")
                }
                Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            if expanded {
                if let html = message.bodyHTML, !html.isEmpty {
                    HTMLBodyView(html: html, allowRemoteImages: loadRemoteImages, height: $htmlHeight)
                        .frame(height: htmlHeight)
                } else {
                    Text(message.bodyText)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                }
                let attachments = store.attachments(for: message.id)
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(attachments) { att in
                                Button {
                                    store.openAttachment(att, message: message)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "paperclip").font(.caption)
                                        Text(att.filename).font(.caption).lineLimit(1)
                                        Text(byteSize(att.size)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Download and open")
                            }
                        }
                    }
                }
            } else {
                Text(message.snippet)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { expanded = true } }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func byteSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Sandboxed HTML rendering: page JavaScript disabled; remote content blocked
/// by CSP unless the user opts in per message. Sizes itself to its content.
/// External links open in the default browser.
struct HTMLBodyView: NSViewRepresentable {
    let html: String
    let allowRemoteImages: Bool
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let key = "\(allowRemoteImages):\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        context.coordinator.setHeight = { self.height = $0 }
        let imgSrc = allowRemoteImages ? "data: cid: https: http:" : "data: cid:"
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src \(imgSrc); style-src 'unsafe-inline'\">"
        let style = """
            <style>
            body { font: 13px -apple-system, sans-serif; color: canvastext; margin: 0; }
            img { max-width: 100%; height: auto; }
            @media (prefers-color-scheme: dark) { body { color: #ddd; } a { color: #6cb2ff; } }
            </style>
            """
        webView.loadHTMLString("<html><head>\(csp)\(style)</head><body>\(html)</body></html>", baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedKey: String?
        var setHeight: ((CGFloat) -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView, attempt: 0)
        }

        /// Content (images, layout) can settle after didFinish; re-measure a
        /// few times and keep the tallest stable value.
        private func measure(_ webView: WKWebView, attempt: Int) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] result, _ in
                if let h = result as? CGFloat, h > 0 {
                    DispatchQueue.main.async { self?.setHeight?(max(h, 40)) }
                }
                if attempt < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self?.measure(webView, attempt: attempt + 1)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
