import SwiftUI
import WebKit

struct ThreadDetailView: View {
    @EnvironmentObject var store: MailStore
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("readingPaneHidden") private var readingPaneHidden = false
    let thread: MailThread
    let onReply: (Message) -> Void

    @State private var messages: [Message] = []
    @State private var threadAttachments: [(message: Message, attachment: AttachmentRow)] = []
    @State private var scrolledMessageId: String?
    @State private var aiSummary: String?
    @State private var summarizing = false
    @State private var summaryError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.system(size: 19 * fontScale, weight: .semibold))
                    .textSelection(.enabled)
                    .padding(.horizontal)

                threadMetaRow

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

                ForEach(messages) { message in
                    MessageCard(message: message,
                                isLast: message.id == messages.last?.id,
                                onReply: { onReply(message) })
                        .padding(.horizontal)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical)
        }
        .toolbar {
            // Notion Mail-style left cluster: close the pane, prev/next thread.
            // Separate ToolbarItems, not a ToolbarItemGroup: on macOS 26 a
            // group shares one glass capsule, so the whole cluster (plus the
            // adjacent view icon) rendered as a single pill that lit up
            // together on any interaction. The ToolbarSpacers on either side
            // detach the trio from the list column's icon and "Inbox" title
            // so it reads as its own group instead of one crammed row.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .navigation)
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    // Keep the selection so the list stays where you are.
                    readingPaneHidden = true
                } label: {
                    Label("Close", systemImage: "chevron.right.2")
                }
                .help("Close (esc)")
                .focusable(false)
                .focusEffectDisabled()
            }
            ToolbarItem(placement: .navigation) {
                Button { store.moveSelection(-1) } label: {
                    Label("Previous", systemImage: "chevron.up")
                }
                .help("Previous thread (\(store.keyBindings.key(for: .prev)))")
                .focusable(false)
                .focusEffectDisabled()
            }
            ToolbarItem(placement: .navigation) {
                Button { store.moveSelection(1) } label: {
                    Label("Next", systemImage: "chevron.down")
                }
                .help("Next thread (\(store.keyBindings.key(for: .next)))")
                .focusable(false)
                .focusEffectDisabled()
            }
            // Detach the close/prev/next trio from the list column's "Inbox"
            // title so it reads as its own group instead of one crammed row.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .navigation)
            }
            ToolbarItemGroup {
                Button { store.archive(thread) } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                Button { store.toggleStar(thread) } label: {
                    Label("Star", systemImage: thread.isStarred ? "star.fill" : "star")
                        .foregroundStyle(thread.isStarred ? .yellow : .primary)
                }
                Button { store.openLabelPicker() } label: {
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
        // Long threads open with the top of the newest message at the top of
        // the pane — positioned before display, not scrolled, so there's no
        // visible jump.
        .scrollPosition(id: $scrolledMessageId, anchor: .top)
        .task(id: thread.id) {
            messages = store.messages(inThread: thread.id)
            threadAttachments = messages.flatMap { msg in
                store.attachments(for: msg.id).map { (message: msg, attachment: $0) }
            }
            scrolledMessageId = messages.count > 1 ? messages.last?.id : nil
            aiSummary = nil; summaryError = nil; summarizing = false
            if thread.isUnread { store.setRead(thread, read: true) }
        }
    }

    /// Notion Mail-style meta row under the subject: an attachments menu
    /// (every file in the thread, one click to Quick Look), removable
    /// category chips (Gmail categories, Important, and user labels), and
    /// "Add category" opening the label picker.
    private var threadMetaRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if !threadAttachments.isEmpty {
                    Menu {
                        ForEach(threadAttachments, id: \.attachment.id) { pair in
                            Button {
                                store.quickLookAttachment(pair.attachment, message: pair.message)
                            } label: {
                                Label(pair.attachment.filename, systemImage: "doc")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 11 * fontScale))
                            Text(threadAttachments.count == 1
                                 ? "1 attachment"
                                 : "\(threadAttachments.count) attachments")
                                .font(.system(size: 12 * fontScale))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Attachments in this thread — click to Quick Look")
                }
                ForEach(categoryChipItems, id: \.id) { chip in
                    HStack(spacing: 5) {
                        if let tint = chip.tint {
                            Circle().fill(tint).frame(width: 7, height: 7)
                        }
                        Text(chip.name)
                            .font(.system(size: 11.5 * fontScale, weight: .medium))
                        Button {
                            store.toggleLabel(thread, labelId: chip.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .pmHitTarget(extra: 8)
                        }
                        .buttonStyle(PressScaleButtonStyle()).foregroundStyle(.secondary)
                        .help("Remove \(chip.name)")
                    }
                    .foregroundStyle(chip.tint == nil ? Color.secondary : .primary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((chip.tint?.opacity(0.15) ?? Color.secondary.opacity(0.1)),
                                in: RoundedRectangle(cornerRadius: 5))
                }
                Button {
                    store.openLabelPicker()
                } label: {
                    Text("Add category")
                        .font(.system(size: 12 * fontScale))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Label this thread (\(store.keyBindings.key(for: .label)))")
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
        }
    }

    /// Everything categorizing this thread, Notion Mail-style: Gmail's own
    /// classification (Important, Updates, …) plus the user's labels, all
    /// removable in place.
    private var categoryChipItems: [(id: String, name: String, tint: Color?)] {
        var items: [(id: String, name: String, tint: Color?)] = []
        for label in thread.labels {
            if label == "IMPORTANT" {
                items.append((label, "Important", nil))
            } else if label.hasPrefix("CATEGORY_"), label != "CATEGORY_PERSONAL" {
                items.append((label, String(label.dropFirst("CATEGORY_".count)).capitalized, nil))
            }
        }
        for labelId in userLabelIds {
            let name = store.labelName(labelId, account: thread.accountId) ?? labelId
            items.append((labelId, name, store.labelTint(name, account: thread.accountId)))
        }
        return items
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
                    .background(Color.notionAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: PMRadius.md))
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
    // Full FROM/TO/CC rows (Notion Mail's "Show more"); compact by default.
    @State private var recipientsExpanded = false
    @State private var htmlHeight: CGFloat = 120
    @State private var loadRemoteImages = false
    @State private var cardCursorPushed = false
    // The quoted reply trail below the new text stays collapsed behind a "…"
    // pill (Gmail-style) on every message — threads repeat their history in
    // each body, so showing it all drowns the actual message.
    @State private var showQuoted = false
    /// The authored text above a plain-text quoted trail; nil when there is
    /// nothing to collapse (always nil for HTML bodies).
    private let textHead: String?
    /// Whether this message carries a collapsible quoted trail — HTML bodies
    /// hide it with CSS, plain text via `textHead`.
    private let hasQuotedTrail: Bool

    /// The trail scans are whole-body regexes and the parent ForEach re-inits
    /// every card whenever the store publishes, so results are cached per
    /// message — bodies are immutable. Cleared wholesale when it grows past
    /// a few threads' worth.
    private static var trailCache: [String: (head: String?, hasTrail: Bool)] = [:]

    init(message: Message, isLast: Bool, onReply: @escaping () -> Void) {
        self.message = message
        self.isLast = isLast
        self.onReply = onReply
        _expanded = State(initialValue: isLast)
        if let cached = Self.trailCache[message.id] {
            (textHead, hasQuotedTrail) = cached
        } else {
            if let html = message.bodyHTML, !html.isEmpty {
                textHead = nil
                hasQuotedTrail = QuotedReply.hasHTMLQuote(html)
            } else {
                textHead = QuotedReply.splitText(message.bodyText)?.head
                hasQuotedTrail = textHead != nil
            }
            if Self.trailCache.count > 512 { Self.trailCache.removeAll() }
            Self.trailCache[message.id] = (textHead, hasQuotedTrail)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                // Notion Mail-style header: sender name + address, with a
                // compact "To me ⌄" summary that expands into full FROM/TO/CC
                // rows. Every participant is clickable (draft/search/copy).
                VStack(alignment: .leading, spacing: 3) {
                    if expanded {
                        if recipientsExpanded {
                            recipientGrid
                        } else {
                            participantMenu(message.fromHeader, nameSize: 14, nameWeight: .semibold)
                            Button {
                                withAnimation(.easeOut(duration: 0.12)) { recipientsExpanded = true }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(recipientSummary)
                                        .font(.system(size: 12 * fontScale))
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 7 * fontScale, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show all senders and recipients")
                        }
                    } else {
                        Text(MessageParser.displayName(fromHeader: message.fromHeader))
                            .font(.system(size: 14 * fontScale, weight: .semibold))
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
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
                                 fontScale: fontScale,
                                 collapseQuote: hasQuotedTrail && !showQuoted,
                                 height: $htmlHeight)
                        .frame(height: htmlHeight)
                } else {
                    Text((showQuoted ? nil : textHead) ?? message.bodyText)
                        .font(.system(size: 14.5 * fontScale))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                if hasQuotedTrail {
                    // Same pill as the compose card: the trail is one click
                    // away, and one more click tucks it back.
                    Button {
                        // Collapsing shrinks the content, and a reloaded web
                        // view can't measure below its current frame — drop
                        // back to the default height and let it grow to fit.
                        // Expanding only grows, so the height stays put until
                        // the new load reports in (no visible snap).
                        if showQuoted { htmlHeight = 120 }
                        withAnimation { showQuoted.toggle() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13 * fontScale, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(showQuoted ? "Hide quoted text" : "Show quoted text")
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
                                        store.quickLookAttachment(att, message: message)
                                    } label: {
                                        Image(systemName: "eye")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Quick Look")

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
                                // Nested chips: flat fill only. Elevation lives on the
                                // parent MessageCard so we don't stack soft shadows.
                                .background(Color.secondary.opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: PMRadius.md))
                                .contextMenu {
                                    Button("Quick Look") { store.quickLookAttachment(att, message: message) }
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
        .background(RoundedRectangle(cornerRadius: PMRadius.md).fill(Color(nsColor: .controlBackgroundColor)))
        // Layered elevation reads cleaner than a hard separator ring on varied
        // backgrounds (light/dark, reading-pane chrome).
        .pmCardElevation(cornerRadius: PMRadius.md)
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

    /// Compact recipient line: "To me", "To Van Ju +3" (extras include Cc).
    private var recipientSummary: String {
        let own = Set(store.accounts.map { $0.id.lowercased() })
        let recipients = MessageParser.splitAddresses(message.toHeader)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let ccCount = MessageParser.splitAddresses(message.ccHeader)
            .filter { $0.contains("@") }.count
        guard let first = recipients.first else { return "To —" }
        let firstName = own.contains(MessageParser.emailAddress(first).lowercased())
            ? "me" : MessageParser.displayName(fromHeader: first)
        let extra = recipients.count - 1 + ccCount
        return extra > 0 ? "To \(firstName) +\(extra)" : "To \(firstName)"
    }

    /// Full participant details, Notion Mail-style: FROM / TO / CC rows with
    /// one clickable participant per line, and "Show less" to tuck it back.
    private var recipientGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            recipientRows("FROM", header: message.fromHeader)
            recipientRows("TO", header: message.toHeader)
            recipientRows("CC", header: message.ccHeader)
            GridRow {
                Text("")
                Button("Show less") {
                    withAnimation(.easeOut(duration: 0.12)) { recipientsExpanded = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12 * fontScale))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func recipientRows(_ role: String, header: String) -> some View {
        let addresses = MessageParser.splitAddresses(header)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        ForEach(Array(addresses.enumerated()), id: \.offset) { index, address in
            GridRow {
                Text(index == 0 ? role : "")
                    .font(.system(size: 10 * fontScale, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .gridColumnAlignment(.leading)
                participantMenu(address)
            }
        }
    }

    /// A clickable participant: name + address, opening a Notion Mail-style
    /// menu (draft to them, search their mail, copy either part).
    @ViewBuilder
    private func participantMenu(_ raw: String, nameSize: CGFloat = 12.5,
                                 nameWeight: Font.Weight = .regular) -> some View {
        let email = MessageParser.emailAddress(raw)
        let name = MessageParser.displayName(fromHeader: raw)
        Menu {
            Button {
                store.composeRequest = .init(replyTo: nil, prefillTo: email)
            } label: {
                Label("Draft email to \(name)", systemImage: "square.and.pencil")
            }
            Button {
                store.commitSearch("from:\(email)")
            } label: {
                Label("Search emails from \(name)", systemImage: "magnifyingglass")
            }
            Divider()
            Button("Copy \"\(email)\"") { copyToPasteboard(email) }
            if name.lowercased() != email.lowercased() {
                Button("Copy \"\(name)\"") { copyToPasteboard(name) }
            }
            // Split/block only make sense for other people's addresses.
            if !store.accounts.contains(where: { $0.id.lowercased() == email.lowercased() }) {
                Divider()
                Button {
                    store.splitFromInbox(matching: email, named: name)
                } label: {
                    Label("Split \(name) from Inbox", systemImage: "arrow.triangle.branch")
                }
                if let domain = email.split(separator: "@").last.map(String.init),
                   domain.contains(".") {
                    Button {
                        store.splitFromInbox(matching: "@\(domain)", named: domain)
                    } label: {
                        Label("Split \(domain) from Inbox", systemImage: "at")
                    }
                }
                Divider()
                if store.isBlocked(email) {
                    Button {
                        store.unblockSender(email)
                    } label: {
                        Label("Unblock \(email)", systemImage: "person.crop.circle.badge.checkmark")
                    }
                } else {
                    Button(role: .destructive) {
                        store.blockSender(email)
                    } label: {
                        Label("Block \(email)", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: nameSize * fontScale, weight: nameWeight))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if name.lowercased() != email.lowercased() {
                    Text(email)
                        .font(.system(size: (nameSize - 1.5) * fontScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(email)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
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
    /// Hides the quoted reply trail (Gmail/Apple Mail/Outlook containers)
    /// while the message card's "…" pill is collapsed.
    var collapseQuote: Bool = false
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
        let key = "\(allowRemoteImages):\(fontScale):\(collapseQuote):\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        context.coordinator.setHeight = { self.height = $0 }
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: allowRemoteImages)
        // Notion-style dark override: most HTML mail hardcodes color:#000 /
        // black on spans (Outlook/Word, corporate sigs). A non-!important body
        // rule loses to those inlines → black-on-gray. Force light text with
        // !important; clear only pure-white panels so brand banners keep their
        // fills and images stay untouched.
        let style = """
            <style>
            :root { color-scheme: light dark; }
            html, body { height: auto !important; min-height: 0 !important; }
            body { font: \(Int(14.5 * fontScale))px -apple-system, sans-serif; color: canvastext; margin: 0; background: transparent; }
            img { max-width: 100%; height: auto; }
            @media (prefers-color-scheme: dark) {
              body, body :not(a):not(a *) { color: #e6e6e6 !important; }
              a, a * { color: #6cb2ff !important; }
              body [style*="background-color:white" i],
              body [style*="background-color: white" i],
              body [style*="background-color:#fff" i],
              body [style*="background-color: #fff" i],
              body [style*="background-color:#ffffff" i],
              body [style*="background-color: #ffffff" i],
              body [style*="background:white" i],
              body [style*="background: white" i],
              body [style*="background:#fff" i],
              body [style*="background: #fff" i],
              body [style*="background:#ffffff" i],
              body [style*="background: #ffffff" i],
              body [bgcolor="white" i],
              body [bgcolor="#fff" i],
              body [bgcolor="#ffffff" i] {
                background-color: transparent !important;
                background-image: none !important;
              }
            }
            \(collapseQuote ? QuotedReply.hideQuoteCSS : "")
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
            webView.evaluateJavaScript("Math.ceil(Math.max(document.body.scrollHeight, document.body.getBoundingClientRect().height))") { [weak self] result, _ in
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
