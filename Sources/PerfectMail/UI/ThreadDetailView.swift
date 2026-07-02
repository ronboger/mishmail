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
                    .keyboardShortcut("r", modifiers: [])
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
    let message: Message
    let isLast: Bool
    let onReply: () -> Void
    @State private var expanded: Bool

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
                    if expanded {
                        Text("to \(message.toHeader)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { expanded.toggle() } }

            if expanded {
                if let html = message.bodyHTML, !html.isEmpty {
                    HTMLBodyView(html: html)
                        .frame(minHeight: 120)
                } else {
                    Text(message.bodyText)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                }
            } else {
                Text(message.snippet)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// Sandboxed HTML rendering: no JavaScript, remote images blocked by CSP.
/// External links open in the default browser.
struct HTMLBodyView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'\">"
        let style = """
            <style>
            body { font: 13px -apple-system, sans-serif; color: canvastext; margin: 0; }
            @media (prefers-color-scheme: dark) { body { color: #ddd; } a { color: #6cb2ff; } }
            </style>
            """
        webView.loadHTMLString("<html><head>\(csp)\(style)</head><body>\(html)</body></html>", baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
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
