import SwiftUI
import WebKit

struct ThreadDetailView: View {
    @EnvironmentObject var store: MailStore
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("readingPaneHidden") private var readingPaneHidden = false
    let thread: MailThread
    let onReply: (Message) -> Void

    @State private var messages: [Message] = []
    @State private var labelsExpanded = false
    @State private var aiSummary: String?
    @State private var summarizing = false
    @State private var summaryError: String?

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent(proxy)
        }
    }

    private func scrollContent(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.system(size: 19 * fontScale, weight: .semibold))
                    .textSelection(.enabled)
                    .padding(.horizontal)

                summarySection

                // Draft threads get an obvious way back into compose.
                if thread.labels.contains("DRAFT") {
                    HStack(spacing: 8) {
                        Button {
                            store.editDraft(inThread: thread)
                        } label: {
                            Label("Edit Draft", systemImage: "pencil")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Delete Draft", role: .destructive) {
                            store.confirmingDraftDelete = thread
                        }
                    }
                    .padding(.horizontal)
                }

                // Labels on this thread, collapsed behind a disclosure by
                // default. Expanding shows chips with add/remove; "l" still
                // opens the picker regardless.
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) { labelsExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tag")
                            Text(userLabelIds.isEmpty ? "Labels" : "Labels (\(userLabelIds.count))")
                            Image(systemName: labelsExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8 * fontScale, weight: .semibold))
                        }
                        .font(.system(size: 11 * fontScale))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show labels on this thread (\(store.keyBindings.key(for: .label)) labels it)")

                    if labelsExpanded {
                        HStack(spacing: 6) {
                            ForEach(userLabelIds, id: \.self) { labelId in
                                let name = store.labelName(labelId, account: thread.accountId) ?? labelId
                                let tint = store.labelTint(name)
                                HStack(spacing: 4) {
                                    Circle().fill(tint).frame(width: 7, height: 7)
                                    Text(name).font(.system(size: 11.5 * fontScale))
                                    Button {
                                        store.toggleLabel(thread, labelId: labelId)
                                    } label: {
                                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(tint.opacity(0.15), in: Capsule())
                            }
                            Button {
                                store.showLabelPicker = true
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "plus")
                                    Text(userLabelIds.isEmpty ? "Add label" : "")
                                }
                                .font(.system(size: 11 * fontScale))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Label this thread (\(store.keyBindings.key(for: .label)))")
                        }
                    }
                }
                .padding(.horizontal)

                ForEach(messages) { message in
                    MessageCard(message: message,
                                isLast: message.id == messages.last?.id,
                                onReply: { onReply(message) })
                        .padding(.horizontal)
                        .id(message.id)
                }
            }
            .padding(.vertical)
        }
        .toolbar {
            // Notion Mail-style left cluster: close the pane, prev/next thread.
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    // Keep the selection so the list stays where you are.
                    readingPaneHidden = true
                } label: {
                    Label("Close", systemImage: "chevron.right.2")
                }
                .help("Close (esc)")
                Button { store.moveSelection(-1) } label: {
                    Label("Previous", systemImage: "chevron.up")
                }
                .help("Previous thread (\(store.keyBindings.key(for: .prev)))")
                Button { store.moveSelection(1) } label: {
                    Label("Next", systemImage: "chevron.down")
                }
                .help("Next thread (\(store.keyBindings.key(for: .next)))")
            }
            ToolbarItemGroup {
                Button { store.archive(thread) } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                Button { store.toggleStar(thread) } label: {
                    Label("Star", systemImage: thread.isStarred ? "star.fill" : "star")
                        .foregroundStyle(thread.isStarred ? .yellow : .primary)
                }
                Button { store.showLabelPicker = true } label: {
                    Label("Label", systemImage: "tag")
                }
                Button(role: .destructive) { store.trash(thread) } label: {
                    Label("Trash", systemImage: "trash")
                }
                if let last = messages.last {
                    Button { onReply(last) } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                }
                Menu {
                    Button {
                        store.markSpam(thread)
                    } label: {
                        Label("Mark as spam", systemImage: "exclamationmark.octagon")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .task(id: thread.id) {
            messages = store.messages(inThread: thread.id)
            aiSummary = nil; summaryError = nil; summarizing = false
            if thread.isUnread { store.setRead(thread, read: true) }
            scrollToLatest(proxy)
        }
    }

    /// Long threads open at the newest message instead of the top. The jump
    /// repeats a few times because expanded HTML bodies report their real
    /// height asynchronously, which shifts the layout after the first scroll.
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard messages.count > 1, let lastId = messages.last?.id else { return }
        let threadId = thread.id
        proxy.scrollTo(lastId, anchor: .top)
        for delay in [0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.thread.id == threadId, self.messages.last?.id == lastId else { return }
                proxy.scrollTo(lastId, anchor: .top)
            }
        }
    }

    /// On-device AI summary. Only offered for multi-message threads (a single
    /// short message doesn't need one). Collapses to a one-line affordance
    /// until asked; the summary streams in locally.
    @ViewBuilder
    private var summarySection: some View {
        if messages.count >= 2 || (messages.first?.bodyText.count ?? 0) > 800 {
            VStack(alignment: .leading, spacing: 6) {
                if let aiSummary {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11 * fontScale))
                            .foregroundStyle(.tint)
                        Text(aiSummary)
                            .font(.system(size: 12.5 * fontScale))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(Color.notionAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Button { summarizeThread() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: summarizing ? "hourglass" : "sparkles")
                            Text(summarizing ? "Summarizing…" : "Summarize with AI")
                        }
                        .font(.system(size: 11 * fontScale))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(summarizing)
                    .help("Generate a local, private TL;DR of this thread (Ollama)")
                }
                if let summaryError {
                    Text(summaryError)
                        .font(.system(size: 11 * fontScale))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }

    private func summarizeThread() {
        summarizing = true
        summaryError = nil
        aiSummary = nil
        let body = messages.map(\.bodyText).joined(separator: "\n\n---\n\n")
        let prompt = Ollama.summarize(subject: thread.subject, body: body)
        Task {
            do {
                var accumulated = ""
                for try await piece in Ollama.generateStream(prompt: prompt) {
                    accumulated += piece
                    let snapshot = accumulated
                    await MainActor.run { aiSummary = snapshot }
                }
                if accumulated.isEmpty {
                    await MainActor.run { summaryError = "No summary was produced." }
                }
            } catch {
                await MainActor.run { summaryError = error.localizedDescription }
            }
            await MainActor.run { summarizing = false }
        }
    }

    /// User-created labels on this thread (system labels stay hidden).
    private var userLabelIds: [String] {
        let known = Set(store.userLabels(forAccount: thread.accountId).map(\.gmailLabelId))
        return thread.labels.filter { known.contains($0) }.sorted {
            (store.labelName($0, account: thread.accountId) ?? $0)
                < (store.labelName($1, account: thread.accountId) ?? $1)
        }
    }
}

struct MessageCard: View {
    @EnvironmentObject var store: MailStore
    @AppStorage("fontScale") private var fontScale = 1.0
    let message: Message
    let isLast: Bool
    let onReply: () -> Void
    @State private var expanded: Bool
    @State private var htmlHeight: CGFloat = 120
    @State private var loadRemoteImages = false
    @State private var cardCursorPushed = false

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
                        .font(.system(size: 14 * fontScale, weight: .semibold))
                        .textSelection(.enabled)
                    if expanded {
                        Text("to \(message.toHeader)")
                            .font(.system(size: 12 * fontScale)).foregroundStyle(.secondary).lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if expanded, message.bodyHTML != nil, !loadRemoteImages {
                    Button("Load images") { loadRemoteImages = true }
                        .buttonStyle(.link).font(.caption)
                        .help("Remote images are blocked by default (they can track opens)")
                }
                if expanded {
                    Button {
                        store.composeRequest = .init(replyTo: message)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.system(size: 12 * fontScale))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Reply (\(store.keyBindings.key(for: .reply)))")
                    Button {
                        store.composeRequest = .init(replyTo: message, forward: true)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.system(size: 12 * fontScale))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Forward (\(store.keyBindings.key(for: .forward)))")
                }
                Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(expanded ? "Collapse" : "Expand")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation { expanded.toggle() }
            }
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            if expanded {
                if let html = message.bodyHTML, !html.isEmpty {
                    HTMLBodyView(html: html, allowRemoteImages: loadRemoteImages,
                                 fontScale: fontScale, height: $htmlHeight)
                        .frame(height: htmlHeight)
                } else {
                    Text(message.bodyText)
                        .font(.system(size: 14.5 * fontScale))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                let attachments = store.attachments(for: message.id)
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if attachments.count > 1 {
                                Button {
                                    store.saveAllAttachments(attachments, message: message)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.down.to.line")
                                        Text("Download all (\(attachments.count))")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(Color.notionAccent.opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .help("Save every attachment to a folder you choose")
                            }
                            ForEach(attachments) { att in
                                HStack(spacing: 8) {
                                    Button {
                                        store.openAttachment(att, message: message)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: iconName(for: att.mimeType))
                                                .font(.system(size: 20))
                                                .foregroundStyle(Color.stable(for: att.filename))
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(att.filename)
                                                    .font(.system(size: 12.5, weight: .medium))
                                                    .lineLimit(1)
                                                Text(byteSize(att.size))
                                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open (uses a private temporary file)")

                                    Button {
                                        store.saveAttachment(att, message: message)
                                    } label: {
                                        Image(systemName: "arrow.down.circle")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Save As… (you choose where)")
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                                .contextMenu {
                                    Button("Open") { store.openAttachment(att, message: message) }
                                    Button("Save As…") { store.saveAttachment(att, message: message) }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                // Notion Mail-style action bar on every message.
                HStack(spacing: 8) {
                    Button {
                        store.composeRequest = .init(replyTo: message)
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                            .font(.system(size: 12.5 * fontScale))
                    }
                    .buttonStyle(.bordered)
                    Button {
                        store.composeRequest = .init(replyTo: message, forward: true)
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                            .font(.system(size: 12.5 * fontScale))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            } else {
                Text(message.snippet.decodingHTMLEntities())
                    .font(.system(size: 12.5 * fontScale)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .contentShape(Rectangle())
        .onTapGesture {
            if !expanded {
                withAnimation { expanded = true }
                if cardCursorPushed { NSCursor.pop(); cardCursorPushed = false }
            }
        }
        // Collapsed cards are clickable everywhere, so show the pointing hand
        // over the whole card (the header row handles its own cursor when expanded).
        .onHover { inside in
            if inside, !expanded {
                if !cardCursorPushed { NSCursor.pointingHand.push(); cardCursorPushed = true }
            } else if cardCursorPushed {
                NSCursor.pop(); cardCursorPushed = false
            }
        }
    }

    private func byteSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func iconName(for mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("zip") || mime.contains("compressed") { return "doc.zipper" }
        if mime.contains("spreadsheet") || mime.contains("csv") || mime.contains("excel") { return "tablecells" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        return "doc"
    }
}

/// Sandboxed HTML rendering: page JavaScript disabled; remote content blocked
/// by CSP unless the user opts in per message. Sizes itself to its content.
/// External links open in the default browser.
struct HTMLBodyView: NSViewRepresentable {
    let html: String
    let allowRemoteImages: Bool
    var fontScale: Double = 1.0
    @Binding var height: CGFloat

    /// The web view is sized to its full content, so it must never trap
    /// scroll events — forward them to the enclosing SwiftUI ScrollView.
    final class PassthroughWebView: WKWebView {
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // Ephemeral store: any remote image an email is allowed to load can't
        // drop cookies/cache that persist or bleed across accounts.
        config.websiteDataStore = .nonPersistent()
        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let key = "\(allowRemoteImages):\(fontScale):\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        context.coordinator.setHeight = { self.height = $0 }
        let imgSrc = allowRemoteImages ? "data: cid: https: http:" : "data: cid:"
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src \(imgSrc); style-src 'unsafe-inline'\">"
        let style = """
            <style>
            body { font: \(Int(14.5 * fontScale))px -apple-system, sans-serif; color: canvastext; margin: 0; }
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
            let url = navigationAction.request.url

            // A user clicking a link is handed to the OS (real browser / mail
            // client); we never navigate the message pane itself. A crafted
            // file:// or app-scheme link stays inert.
            if navigationAction.navigationType == .linkActivated {
                if let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }

            // Default-deny for everything else. The only navigation an email is
            // allowed to perform is the synthetic initial document load from
            // loadHTMLString (URL is nil or about:blank). This blocks
            // meta-refresh, form submission, JS/redirect, and iframe loads —
            // all of which would otherwise let crafted HTML reach the network
            // (defeating remote-image blocking) or replace the body with a
            // phishing page. Remote images, when opted in, are resource loads,
            // not navigations, so they are unaffected.
            let scheme = url?.scheme?.lowercased()
            if url == nil || scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
