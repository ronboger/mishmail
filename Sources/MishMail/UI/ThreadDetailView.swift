import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ThreadDetailView: View {
    @EnvironmentObject var store: MailStore
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("readingPaneHidden") private var readingPaneHidden = false
    let thread: MailThread
    let compactMode: Bool
    /// Full-app conversation (⌘↩) — back control exits focus, not the thread.
    var focusMode: Bool = false
    let onBack: () -> Void
    let onReply: (Message) -> Void

    @State private var messages: [Message] = []
    @State private var threadAttachments: [(message: Message, attachment: AttachmentRow)] = []
    @State private var scrolledMessageId: String?
    @State private var aiSummary: String?
    @State private var summarizing = false
    @State private var summaryError: String?
    /// Session opt-in: Load images for every card in this thread.
    @State private var loadRemoteImagesForThread = false
    /// Message ids we already tried to hydrate — avoids re-querying forever
    /// for genuinely empty bodies (`needsBodyLoad` stays true).
    @State private var bodyLoadAttempted: Set<String> = []
    /// Only one sent message owns a live body renderer at a time. This keeps
    /// HTML-heavy threads from accumulating WKWebViews and helper processes.
    @State private var expandedMessageId: String?

    var body: some View {
        ScrollView {
            // Message cards are cheap while collapsed and only expanded cards
            // mount WKWebView. An eager stack avoids LazyVStack's geometry
            // cache repeatedly invalidating around dynamically sized WebViews.
            VStack(alignment: .leading, spacing: 12) {
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.system(size: 19 * fontScale, weight: .semibold))
                    .textSelection(.enabled)
                    .padding(.horizontal)
                    .accessibilityIdentifier("threadSubject")

                threadMetaRow

                summarySection

                // Slim cue for long threads only: on short threads the draft
                // card is already in the first viewport, so a second orange
                // affordance is noise. Continues the newest draft.
                if showDraftBanner {
                    Button {
                        store.editDraft(inThread: thread)
                    } label: {
                        HStack(spacing: 8) {
                            Text("Draft")
                                .font(.system(size: 11 * fontScale, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.orange, in: Capsule())
                            Text("Unsent reply in this conversation")
                                .font(.system(size: 12.5 * fontScale))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("Continue")
                                .font(.system(size: 12.5 * fontScale, weight: .medium))
                                .foregroundStyle(Color.notionAccent)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10 * fontScale, weight: .semibold))
                                .foregroundStyle(Color.notionAccent)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: PMRadius.md)
                                .fill(Color.orange.opacity(0.10))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: PMRadius.md)
                                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: PMRadius.md))
                    }
                    .buttonStyle(.plain)
                    .help("Continue editing the unsent draft")
                    .padding(.horizontal)
                }

                ForEach(messages) { message in
                    if ForwardComposer.hasDraftLabel(message.labelIds) {
                        // Drafts are not ordinary messages: no quote trail, no
                        // Reply/Forward, clear "not sent" chrome. Edit lives on
                        // the card so you don't have to scroll to the top.
                        DraftMessageCard(
                            message: message,
                            onNeedBody: { loadBodyIfNeeded(id: message.id) })
                            .padding(.horizontal)
                            .id(message.id)
                    } else {
                        MessageCard(message: message,
                                    isLast: message.id == lastNonDraftId,
                                    expandedMessageId: $expandedMessageId,
                                    loadImagesForThread: $loadRemoteImagesForThread,
                                    onReply: { onReply(message) },
                                    onNeedBody: { loadBodyIfNeeded(id: message.id) })
                            .padding(.horizontal)
                            .id(message.id)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical)
        }
        .navigationTitle(store.selectedView.title)
        .toolbar {
            // Notion Mail-style left cluster: close the pane, prev/next thread.
            // Separate ToolbarItems (not a group) + hidden shared glass on
            // macOS 26 so they don't merge into one capsule that lights up
            // when the thread scrolls. Spacers keep the trio off the title.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .navigation)
            }
            ToolbarItem(placement: .navigation) {
                if focusMode {
                    Button(action: onBack) {
                        Label("Exit Focus",
                              systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Exit full-app conversation (esc or ⌘↩)")
                    .accessibilityIdentifier("exitFocusButton")
                    .focusable(false)
                    .focusEffectDisabled()
                } else if compactMode {
                    Button(action: onBack) {
                        Label("Back to inbox", systemImage: "chevron.left")
                    }
                    .help("Back to conversation list (esc)")
                    .accessibilityIdentifier("compactBackButton")
                    .focusable(false)
                    .focusEffectDisabled()
                } else {
                    Button {
                        // Keep the selection so the list stays where you are.
                        readingPaneHidden = true
                    } label: {
                        Label("Hide Reading Pane", systemImage: "chevron.right.2")
                    }
                    // Collapses the reading pane so the list fills the window;
                    // selection stays put — click a thread (or press Enter) to reopen.
                    .help("Hide reading pane (esc)")
                    .focusable(false)
                    .focusEffectDisabled()
                }
            }
            .pmHideSharedBackground()
            ToolbarItem(placement: .navigation) {
                Button { store.moveSelection(-1) } label: {
                    Label("Previous", systemImage: "chevron.up")
                }
                .help("Previous conversation (\(store.keyBindings.key(for: .prev)))")
                .focusable(false)
                .focusEffectDisabled()
            }
            .pmHideSharedBackground()
            ToolbarItem(placement: .navigation) {
                Button { store.moveSelection(1) } label: {
                    Label("Next", systemImage: "chevron.down")
                }
                .help("Next conversation (\(store.keyBindings.key(for: .next)))")
                .focusable(false)
                .focusEffectDisabled()
            }
            .pmHideSharedBackground()
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .navigation)
            }
            ToolbarItemGroup {
                Button { store.archive(thread) } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .help("Archive (\(store.keyBindings.key(for: .archive)))")
                Button { store.toggleStar(thread) } label: {
                    Label(thread.isStarred ? "Unstar" : "Star",
                          systemImage: thread.isStarred ? "star.fill" : "star")
                        .foregroundStyle(thread.isStarred ? .yellow : .primary)
                }
                .help(thread.isStarred
                      ? "Unstar (\(store.keyBindings.key(for: .toggleStar)))"
                      : "Star (\(store.keyBindings.key(for: .toggleStar)))")
                Button { store.openLabelPicker() } label: {
                    Label("Label", systemImage: "tag")
                }
                .help("Labels (\(store.keyBindings.key(for: .label)))")
                Button(role: .destructive) { store.trash(thread) } label: {
                    Label("Trash", systemImage: "trash")
                }
                .help("Move to Trash (\(store.keyBindings.key(for: .trash)))")
                // Reply/forward target the newest *sent* message — never a draft
                // (shared ForwardComposer.newestSentMessage; drafts open via
                // Continue / editDraft, not Reply).
                if let last = ForwardComposer.newestSentMessage(in: messages) {
                    Button { onReply(last) } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .help("Reply (\(store.keyBindings.key(for: .reply)))")
                    if ReplyComposer.hasAdditionalReplyAllRecipients(
                        last, ownAddresses: store.ownEmailAddresses) {
                        Button {
                            store.openCompose(.init(replyTo: last, replyAll: true))
                        } label: {
                            Label("Reply all", systemImage: "arrowshape.turn.up.left.2")
                        }
                        .help("Reply all (\(store.keyBindings.key(for: .replyAll)))")
                    }
                    Button {
                        store.openCompose(.init(replyTo: last, forward: true))
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    .help("Forward newest message (\(store.keyBindings.key(for: .forward))) · starts a new conversation")
                }
                // Overflow holds secondary actions that already exist via
                // keyboard (read, snooze) plus spam / open-in-Gmail. Always
                // multi-item so the chevron never looks like a one-action menu.
                Menu {
                    // Hide when only one non-draft message (drafts are excluded
                    // from the package — counting them would falsely enable this).
                    if ForwardComposer.forwardableMessages(messages).count > 1,
                       let last = ForwardComposer.newestSentMessage(in: messages) {
                        Button {
                            store.openCompose(.init(
                                replyTo: last, forward: true, forwardAll: true))
                        } label: {
                            Label("Forward all", systemImage: "arrowshape.turn.up.forward")
                        }
                    }
                    Divider()
                    Button {
                        copyThreadAsMarkdown()
                    } label: {
                        Label("Copy as Markdown", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        saveThreadAsMarkdown()
                    } label: {
                        Label("Save as Markdown…", systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    Button {
                        store.setRead(thread, read: thread.isUnread)
                    } label: {
                        Label(thread.isUnread ? "Mark as read" : "Mark as unread",
                              systemImage: thread.isUnread
                                ? "envelope.open" : "envelope.badge")
                    }
                    Button {
                        store.snoozingThread = thread
                    } label: {
                        Label("Snooze", systemImage: "clock")
                    }
                    Divider()
                    if thread.inSpam {
                        Button {
                            store.markNotSpam(thread)
                        } label: {
                            Label("Not spam", systemImage: "tray")
                        }
                        .help("Not spam (\(store.keyBindings.key(for: .markSpam)))")
                    } else {
                        Button {
                            store.markSpam(thread)
                        } label: {
                            Label("Mark as spam", systemImage: "exclamationmark.octagon")
                        }
                        .help("Mark as spam (\(store.keyBindings.key(for: .markSpam)))")
                    }
                    // Report phishing deferred — public Gmail API has no
                    // phishing endpoint (Notion may soft-map to spam). See
                    // docs/plans/2026-07-11-report-phishing-deferred.md.
                    // Block is the local equivalent (From → Spam on sight).
                    let blockEmail = thread.fromEmail
                    if !blockEmail.isEmpty,
                       !store.accounts.contains(where: {
                           $0.id.lowercased() == blockEmail.lowercased()
                       }) {
                        if store.isBlocked(blockEmail) {
                            Button {
                                store.unblockSender(blockEmail)
                            } label: {
                                Label("Unblock \(blockEmail)",
                                      systemImage: "person.crop.circle.badge.checkmark")
                            }
                        } else {
                            Button(role: .destructive) {
                                store.blockThreadSender(thread)
                            } label: {
                                Label("Block sender",
                                      systemImage: "person.crop.circle.badge.xmark")
                            }
                        }
                    }
                    Button {
                        store.openInGmail(thread)
                    } label: {
                        Label("Open in Gmail", systemImage: "safari")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("More actions")
            }
        }
        // Long threads open with the top of the newest *sent* message at the
        // top of the pane (matches which card is expanded). Drafts sit below
        // and stay visible without stealing the scroll anchor.
        .scrollPosition(id: $scrolledMessageId, anchor: .top)
        .task(id: thread.id) {
            // Headers only first — skip pulling every body on open. Hydrate the
            // expanded sent message and any draft cards (preview needs body).
            bodyLoadAttempted = []
            loadRemoteImagesForThread = false
            expandedMessageId = nil
            var loaded = store.messageHeaders(inThread: thread.id)
            // Expand the newest sent message; also pull bodies for draft cards
            // so the compact preview is ready without a second hop.
            var hydrateIds: [String] = []
            if let sentId = ForwardComposer.newestSentMessage(in: loaded)?.id {
                hydrateIds.append(sentId)
            }
            for draft in loaded where ForwardComposer.hasDraftLabel(draft.labelIds) {
                if !hydrateIds.contains(draft.id) { hydrateIds.append(draft.id) }
            }
            for id in hydrateIds {
                guard let idx = loaded.firstIndex(where: { $0.id == id }),
                      let full = store.messageBody(id: id) else { continue }
                loaded[idx] = full
                bodyLoadAttempted.insert(id)
            }
            messages = loaded
            // Attachment rows key off messageId; header rows are enough.
            threadAttachments = loaded.flatMap { msg in
                store.attachments(for: msg.id).map { (message: msg, attachment: $0) }
            }
            // Anchor on newest sent when multi-message; draft-only falls back
            // to the last row so a pure-draft pane still positions.
            scrolledMessageId = messages.count > 1
                ? (ForwardComposer.newestSentMessage(in: messages)?.id ?? messages.last?.id)
                : nil
            aiSummary = nil; summaryError = nil; summarizing = false
            // Dwell before auto mark-read so j/k / scroll-select through the
            // inbox does not clear every unread badge. Archive (`e`) marks
            // read immediately in MailStore.archive; `.task(id:)` cancels
            // this sleep when selection leaves.
            guard thread.isUnread else { return }
            do {
                try await Task.sleep(nanoseconds: MarkReadOnOpen.dwellNanoseconds)
            } catch {
                return
            }
            // Require a live list row — never fall back to the captured
            // `thread` snapshot. After archive of the last visible row,
            // selection can still point here while the row is gone; using
            // the stale model would re-save inInbox=true via setRead.
            let liveThread = store.threads.first(where: { $0.id == thread.id })
            guard MarkReadOnOpen.shouldMarkRead(
                selectedId: store.selectedThreadId,
                threadId: thread.id,
                liveIsUnread: liveThread?.isUnread),
                  let liveThread else { return }
            store.setRead(liveThread, read: true)
        }
        // The store reloaded from the DB (sync, draft discard, send…): refresh
        // the open thread in place so e.g. a discarded draft's card disappears
        // without navigating away. Scroll anchor and summary stay put.
        .onChange(of: store.threadContentVersion) {
            refreshMessages()
        }
    }

    /// Re-query this thread's rows and merge into the visible list, keeping
    /// already-hydrated bodies so open cards don't collapse back to
    /// "Loading…". No-op when nothing about the thread changed.
    private func refreshMessages() {
        let fresh = store.messageHeaders(inThread: thread.id)
        let merged = ThreadRefresh.merge(current: messages, fresh: fresh)
        guard merged != messages else { return }
        withAnimation(.easeOut(duration: 0.1)) {
            messages = merged
        }
        threadAttachments = merged.flatMap { msg in
            store.attachments(for: msg.id).map { (message: msg, attachment: $0) }
        }
    }

    /// True when a reading-pane message still needs a body fetch.
    static func needsBodyLoad(_ message: Message) -> Bool {
        ThreadRefresh.needsBodyLoad(message)
    }

    /// Any DRAFT-labeled message currently in the open thread.
    private var hasThreadDraft: Bool {
        messages.contains { ForwardComposer.hasDraftLabel($0.labelIds) }
    }

    /// Banner only when the draft card is likely below the first viewport
    /// (≥4 messages). Shorter threads already show the draft card on screen.
    private var showDraftBanner: Bool {
        hasThreadDraft && messages.count > 3
    }

    /// Expand the newest *sent* message by default — drafts get their own card
    /// and must not steal the "last card is expanded" affordance from the
    /// conversation the user is reading.
    private var lastNonDraftId: String? {
        ForwardComposer.newestSentMessage(in: messages)?.id
    }

    /// Hydrate one message's body into `messages` when the user expands it.
    private func loadBodyIfNeeded(id: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        guard Self.needsBodyLoad(messages[idx]) else { return }
        guard !bodyLoadAttempted.contains(id) else { return }
        bodyLoadAttempted.insert(id)
        guard let full = store.messageBody(id: id) else { return }
        messages[idx] = full
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
        // Summary needs full bodies; hydrate anything still header-only.
        let ids = messages.map(\.id)
        let fullById = Dictionary(uniqueKeysWithValues:
            store.messagesWithBodies(ids: ids).map { ($0.id, $0) })
        let body = messages.map { fullById[$0.id]?.bodyText ?? $0.bodyText }
            .joined(separator: "\n\n---\n\n")
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

    // MARK: - Share (Markdown)

    /// Hydrate every body so export is complete even for collapsed cards.
    private func messagesForExport() -> [Message] {
        let ids = messages.map(\.id)
        let fullById = Dictionary(uniqueKeysWithValues:
            store.messagesWithBodies(ids: ids).map { ($0.id, $0) })
        return messages.map { fullById[$0.id] ?? $0 }
    }

    private func exportMarkdown() -> String {
        let full = messagesForExport()
        let refs = threadAttachments.map {
            ThreadExporter.AttachmentRef(
                messageId: $0.message.id, filename: $0.attachment.filename)
        }
        return ThreadExporter.markdown(
            subject: thread.subject, messages: full, attachments: refs)
    }

    private func copyThreadAsMarkdown() {
        let md = exportMarkdown()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    private func saveThreadAsMarkdown() {
        let md = exportMarkdown()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .utf8PlainText]
        // UTType for markdown if available — fall back stays .md via nameField.
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType, .plainText]
        }
        panel.nameFieldStringValue = ThreadExporter.suggestedFilename(
            subject: thread.subject, date: thread.lastDate)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // Keep the export: clipboard fallback + tell the user what happened.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(md, forType: .string)
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't save the file"
                    alert.informativeText =
                        "\(error.localizedDescription)\n\nThe Markdown was copied to the clipboard instead."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}

/// Saved Gmail draft rendered in the thread — not a regular MessageCard.
///
/// Gmail/Notion cues: orange "Draft" pill, warm tint, left accent, compact
/// authored preview (no HTML quote trail / "…" gap), and Continue/Discard
/// actions on the card itself so edit isn't only at the top of the pane.
struct DraftMessageCard: View {
    @EnvironmentObject var store: MailStore
    @AppStorage("fontScale") private var fontScale = 1.0
    let message: Message
    let onNeedBody: () -> Void
    @State private var cursorPushed = false

    private var preview: String {
        QuotedReply.authoredPreview(text: message.bodyText, html: message.bodyHTML)
    }

    private var toSummary: String {
        let names = MessageParser.splitAddresses(message.toHeader)
            .map { MessageParser.displayName(fromHeader: $0) }
            .filter { !$0.isEmpty }
        if names.isEmpty { return "No recipients" }
        if names.count == 1 { return "To \(names[0])" }
        return "To \(names[0]) +\(names.count - 1)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Draft")
                    .font(.system(size: 11 * fontScale, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                Text("Not sent")
                    .font(.system(size: 12 * fontScale, weight: .medium))
                    .foregroundStyle(Color.orange)
                Spacer(minLength: 8)
                Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(MessageParser.displayName(fromHeader: message.fromHeader))
                    .font(.system(size: 13.5 * fontScale, weight: .semibold))
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(toSummary)
                    .font(.system(size: 12.5 * fontScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if ThreadDetailView.needsBodyLoad(message) {
                Text("Loading draft…")
                    .font(.system(size: 13.5 * fontScale))
                    .foregroundStyle(.secondary)
            } else if preview.isEmpty {
                Text("Empty draft — click Continue to write")
                    .font(.system(size: 13.5 * fontScale))
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                // No textSelection: the whole card opens compose, so a
                // selection gesture would fight the tap-to-edit hit target.
                Text(preview)
                    .font(.system(size: 14 * fontScale))
                    .lineSpacing(3)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button {
                    store.editDraft(message)
                } label: {
                    Label("Continue", systemImage: "pencil")
                        .font(.system(size: 12.5 * fontScale))
                }
                .buttonStyle(.borderedProminent)
                .help("Continue editing this draft")
                Button(role: .destructive) {
                    store.confirmingDraftDelete = message
                } label: {
                    Text("Discard")
                        .font(.system(size: 12.5 * fontScale))
                }
                .buttonStyle(.bordered)
                .help("Delete this draft")
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .padding(.leading, 4) // room for the accent bar inside the card
        .background(
            RoundedRectangle(cornerRadius: PMRadius.md)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(alignment: .leading) {
            // Gmail-ish draft accent: solid orange rail, not a full red banner.
            UnevenRoundedRectangle(
                topLeadingRadius: PMRadius.md,
                bottomLeadingRadius: PMRadius.md,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(Color.orange)
            .frame(width: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.md)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        }
        .pmCardElevation(cornerRadius: PMRadius.md)
        .contentShape(RoundedRectangle(cornerRadius: PMRadius.md))
        .onTapGesture { store.editDraft(message) }
        .onHover { inside in
            if inside {
                if !cursorPushed { NSCursor.pointingHand.push(); cursorPushed = true }
            } else if cursorPushed {
                NSCursor.pop(); cursorPushed = false
            }
        }
        .onDisappear {
            // Discard-under-cursor removes the card while still hovered;
            // without this the pointingHand stays pushed on the stack.
            if cursorPushed { NSCursor.pop(); cursorPushed = false }
        }
        .onAppear { onNeedBody() }
        .help("Continue editing this draft")
    }
}

struct MessageCard: View {
    @EnvironmentObject var store: MailStore
    @AppStorage("fontScale") private var fontScale = 1.0
    /// Settings → Appearance. Default `.ask` so tracking pixels stay blocked.
    @AppStorage(RemoteImagePolicy.defaultsKey) private var remoteImagePolicyRaw =
        RemoteImagePolicy.ask.rawValue
    let message: Message
    let isLast: Bool
    @Binding var expandedMessageId: String?
    /// Session-wide opt-in shared by every card in the open thread.
    @Binding var loadImagesForThread: Bool
    let onReply: () -> Void
    /// Parent loads the body when a collapsed header-only card expands.
    let onNeedBody: () -> Void
    // Full FROM/TO/CC rows (Notion Mail's "Show more"); compact by default.
    @State private var recipientsExpanded = false
    @State private var htmlHeight: CGFloat = 120
    /// Per-message opt-in when policy is ask/vip and the sender isn't allowed.
    @State private var loadRemoteImages = false
    /// Manual escape hatch: render multipart plain text instead of HTML.
    /// Useful for privacy-sensitive transactional mail when remote images are
    /// blocked and the HTML shell is unreadable — not an automatic switch.
    @State private var showPlainText = false
    /// Giant HTML bodies require an explicit click before WebKit receives the
    /// full document. This stays scoped to the card/session.
    @State private var approvedOversizedHTML = false
    @State private var cardCursorPushed = false
    // The quoted reply trail below the new text stays collapsed behind a "…"
    // pill (Gmail-style) on every message — threads repeat their history in
    // each body, so showing it all drowns the actual message.
    @State private var showQuoted = false
    /// The authored text above a plain-text quoted trail; nil when there is
    /// nothing to collapse (always nil for HTML bodies).
    private let textHead: String?
    /// Raw authored HTML above a structured quote container. Loading this
    /// instead of hiding the full trail with CSS avoids parsing repeated mail.
    private let htmlHead: String?
    private let htmlBytes: Int
    private let htmlHeadBytes: Int
    /// Whether this message carries a collapsible quoted trail — HTML bodies
    /// load only `htmlHead`, plain text renders `textHead`.
    private let hasQuotedTrail: Bool

    /// The trail scans are whole-body regexes and the parent ForEach re-inits
    /// every card whenever the store publishes, so results are cached per
    /// message — bodies are immutable. Count and byte budgets keep cached raw
    /// HTML heads bounded. Only cache when a body is present so lazy-loaded
    /// headers don't poison the entry with an empty-body result.
    private final class TrailCacheEntry {
        let textHead: String?
        let htmlHead: String?
        let hasTrail: Bool
        let htmlBytes: Int
        let htmlHeadBytes: Int

        init(textHead: String?, htmlHead: String?, hasTrail: Bool,
             htmlBytes: Int, htmlHeadBytes: Int) {
            self.textHead = textHead
            self.htmlHead = htmlHead
            self.hasTrail = hasTrail
            self.htmlBytes = htmlBytes
            self.htmlHeadBytes = htmlHeadBytes
        }

        var cacheCost: Int {
            htmlHeadBytes + (textHead?.utf8.count ?? 0)
        }
    }

    private static let maximumTrailCacheCost = 2 * 1_024 * 1_024
    private static let maximumTrailCacheEntries = 128
    private static let trailCache: NSCache<NSString, TrailCacheEntry> = {
        let cache = NSCache<NSString, TrailCacheEntry>()
        cache.countLimit = maximumTrailCacheEntries
        cache.totalCostLimit = maximumTrailCacheCost
        return cache
    }()

    private static func cacheTrail(_ entry: TrailCacheEntry, for id: String) {
        guard entry.cacheCost <= maximumTrailCacheCost else { return }
        trailCache.setObject(entry, forKey: id as NSString, cost: entry.cacheCost)
    }

    init(message: Message, isLast: Bool,
         expandedMessageId: Binding<String?>,
         loadImagesForThread: Binding<Bool> = .constant(false),
         onReply: @escaping () -> Void,
         onNeedBody: @escaping () -> Void = {}) {
        self.message = message
        self.isLast = isLast
        self._expandedMessageId = expandedMessageId
        self._loadImagesForThread = loadImagesForThread
        self.onReply = onReply
        self.onNeedBody = onNeedBody
        let hasBody = !ThreadDetailView.needsBodyLoad(message)
        if hasBody, let cached = Self.trailCache.object(forKey: message.id as NSString) {
            textHead = cached.textHead
            htmlHead = cached.htmlHead
            hasQuotedTrail = cached.hasTrail
            htmlBytes = cached.htmlBytes
            htmlHeadBytes = cached.htmlHeadBytes
        } else if hasBody {
            let fullHTMLBytes = message.bodyHTML?.utf8.count ?? 0
            // Prefer structured HTML collapse (gmail_quote / cite). When HTML
            // has no marker but plain text still has a `>` / "On … wrote:"
            // trail, keep a text head so "…" can hide it (some clients ship
            // nested history as plain `>` lines inside a single HTML div).
            // Giant bodies skip all whole-body trail scans and go straight to
            // the explicit-load placeholder; scanning them on the main actor
            // would defeat the guard before WebKit even mounts.
            let detectedHTMLHead: String? = {
                guard let html = message.bodyHTML, !html.isEmpty else { return nil }
                if fullHTMLBytes <= HTMLBodyRenderPolicy.maximumAutomaticBytes {
                    return QuotedReply.authoredHTMLHead(html)
                }
                return QuotedReply.authoredHTMLHead(
                    html,
                    scanCharacterLimit: HTMLBodyRenderPolicy.oversizedQuoteScanCharacterLimit)
            }()
            if let head = detectedHTMLHead {
                textHead = nil
                htmlHead = head
                hasQuotedTrail = true
            } else if fullHTMLBytes <= HTMLBodyRenderPolicy.maximumAutomaticBytes,
                      let head = QuotedReply.splitText(message.bodyText)?.head {
                textHead = head
                htmlHead = nil
                hasQuotedTrail = true
            } else {
                textHead = nil
                htmlHead = nil
                hasQuotedTrail = false
            }
            htmlBytes = fullHTMLBytes
            htmlHeadBytes = htmlHead?.utf8.count ?? 0
            Self.cacheTrail(TrailCacheEntry(
                textHead: textHead,
                htmlHead: htmlHead,
                hasTrail: hasQuotedTrail,
                htmlBytes: htmlBytes,
                htmlHeadBytes: htmlHeadBytes), for: message.id)
        } else {
            textHead = nil
            htmlHead = nil
            hasQuotedTrail = false
            htmlBytes = 0
            htmlHeadBytes = 0
        }
    }

    private func toggleExpanded() {
        let willExpand = !expanded
        withAnimation(.easeOut(duration: 0.12)) {
            expandedMessageId = willExpand ? message.id : nil
        }
        if willExpand { onNeedBody() }
    }

    private func expandCard() {
        if !expanded {
            withAnimation(.easeOut(duration: 0.12)) {
                expandedMessageId = message.id
            }
            onNeedBody()
        }
    }

    private var expanded: Bool {
        expandedMessageId == message.id
    }

    private var remoteImagePolicy: RemoteImagePolicy {
        RemoteImagePolicy(rawValue: remoteImagePolicyRaw) ?? .ask
    }

    /// Policy + VIP list + per-message / per-thread opt-in.
    private var allowRemoteImages: Bool {
        RemoteImagePolicy.allows(
            policy: remoteImagePolicy,
            senderEmail: MessageParser.emailAddress(message.fromHeader),
            vipEmails: store.vipEmails,
            messageOptIn: loadRemoteImages,
            threadOptIn: loadImagesForThread)
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
                            compactRecipientGrid
                        }
                    } else {
                        Text(MessageParser.displayName(fromHeader: message.fromHeader))
                            .font(.system(size: 14 * fontScale, weight: .semibold))
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if expanded, message.bodyHTML != nil, !message.bodyText.isEmpty {
                    Button {
                        showPlainText.toggle()
                    } label: {
                        Text(showPlainText ? "Show HTML" : "Show plain text")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(showPlainText
                          ? "Render the HTML body again"
                          : "Show the multipart plain-text alternative (no remote images; useful when HTML is unreadable)")
                }
                if expanded, message.bodyHTML != nil, !allowRemoteImages, !showPlainText {
                    // Click loads this message; chevron / long-press offers the thread.
                    Menu {
                        Button("This conversation") { loadImagesForThread = true }
                    } label: {
                        Text("Load images")
                            .font(.caption)
                    } primaryAction: {
                        loadRemoteImages = true
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Remote images can track opens. Click for this message; menu for the whole conversation. VIP auto-load and Always are in Settings → Appearance.")
                }
                if expanded {
                    Button {
                        store.openCompose(.init(replyTo: message))
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.system(size: 12 * fontScale))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Reply (\(store.keyBindings.key(for: .reply)))")
                    if ReplyComposer.hasAdditionalReplyAllRecipients(
                        message, ownAddresses: store.ownEmailAddresses) {
                        Button {
                            store.openCompose(.init(replyTo: message, replyAll: true))
                        } label: {
                            Image(systemName: "arrowshape.turn.up.left.2")
                                .font(.system(size: 12 * fontScale))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Reply all (\(store.keyBindings.key(for: .replyAll)))")
                    }
                    Button {
                        store.openCompose(.init(replyTo: message, forward: true))
                    } label: {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.system(size: 12 * fontScale))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Forward this message (\(store.keyBindings.key(for: .forward))) · starts a new conversation")
                }
                Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(expanded ? "Collapse" : "Expand")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                toggleExpanded()
            }
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            if expanded {
                // Collapsed cards never mount HTMLBodyView (gated on expanded).
                // Header-only rows show nothing until the parent hydrates the body.
                //
                // When we only have a plain-text head (no structured HTML quote),
                // show that head while collapsed — even if bodyHTML exists —
                // so nested `>` history doesn't stay visible by default.
                if hasQuotedTrail, let head = textHead, !showQuoted {
                    Text(head)
                        .font(.system(size: 14.5 * fontScale))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                } else if showPlainText, !message.bodyText.isEmpty {
                    // Manual plain-text escape hatch (see header control).
                    Text(message.bodyText)
                        .font(.system(size: 14.5 * fontScale))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                } else if let html = message.bodyHTML, !html.isEmpty {
                    // Structured quotes are removed before WebKit sees the
                    // document. Besides avoiding repeated history parsing,
                    // this gives head/full loads distinct constant-time ids.
                    let useAuthoredHTML = textHead == nil && !showQuoted
                        && htmlHead != nil
                    let renderedHTML = useAuthoredHTML ? (htmlHead ?? html) : html
                    let renderedBytes = useAuthoredHTML ? htmlHeadBytes : htmlBytes
                    if HTMLBodyRenderPolicy.requiresExplicitLoad(
                        byteCount: renderedBytes,
                        userApproved: approvedOversizedHTML) {
                        oversizedHTMLPlaceholder(byteCount: renderedBytes)
                    } else {
                        HTMLBodyView(
                            contentID: message.id + (useAuthoredHTML ? ":authored" : ":full"),
                            html: renderedHTML,
                            allowRemoteImages: allowRemoteImages,
                            fontScale: fontScale,
                            height: $htmlHeight)
                            .frame(height: htmlHeight)
                    }
                } else if !message.bodyText.isEmpty {
                    // Collapsed plain-text heads are handled above; this branch
                    // is full body (no trail, or showQuoted).
                    Text(message.bodyText)
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
                        // Showing the full trail is itself an explicit request
                        // to load it. Keep the authored head visible instead of
                        // replacing it with another confirmation placeholder.
                        if !showQuoted,
                           HTMLBodyRenderPolicy.quoteExpansionApprovesFullBody(
                               byteCount: htmlBytes) {
                            approvedOversizedHTML = true
                        }
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
                        store.openCompose(.init(replyTo: message))
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                            .font(.system(size: 12.5 * fontScale))
                    }
                    .buttonStyle(.bordered)
                    if ReplyComposer.hasAdditionalReplyAllRecipients(
                        message, ownAddresses: store.ownEmailAddresses) {
                        Button {
                            store.openCompose(.init(replyTo: message, replyAll: true))
                        } label: {
                            Label("Reply all", systemImage: "arrowshape.turn.up.left.2")
                                .font(.system(size: 12.5 * fontScale))
                        }
                        .buttonStyle(.bordered)
                        .help("Reply all (\(store.keyBindings.key(for: .replyAll)))")
                    }
                    Button {
                        store.openCompose(.init(replyTo: message, forward: true))
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                            .font(.system(size: 12.5 * fontScale))
                    }
                    .buttonStyle(.bordered)
                    .help("Forward this message · starts a new conversation")
                }
                .padding(.top, 4)

                // Which of your Gmail filters match this message — collapsed
                // by default; toggle the header to expand. Hidden until the
                // account's filters have loaded and at least one hits.
                MatchingFiltersSection(message: message, fontScale: fontScale)
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
                expandCard()
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
        .onAppear {
            // Last card starts expanded; ask parent to hydrate if still headers-only.
            if isLast, expandedMessageId == nil {
                expandedMessageId = message.id
                onNeedBody()
            } else if expanded {
                onNeedBody()
            }
        }
    }

    private func oversizedHTMLPlaceholder(byteCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Large HTML message", systemImage: "doc.richtext")
                .font(.system(size: 13 * fontScale, weight: .semibold))
            Text("This body is \(byteSize(byteCount)). Loading it may briefly slow the reading pane.")
                .font(.system(size: 12.5 * fontScale))
                .foregroundStyle(.secondary)
            // Gmail's snippet is already short. Do not call authoredPreview
            // here: its plain-text/HTML quote detection is intentionally
            // thorough and would scan the giant body this placeholder avoids.
            let preview = message.snippet.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !preview.isEmpty {
                Text(String(preview.prefix(HTMLBodyRenderPolicy.previewCharacterLimit)))
                    .font(.system(size: 13 * fontScale))
                    .lineLimit(8)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("Load full HTML") {
                approvedOversizedHTML = true
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Compact recipient value: "me", "Van Ju +3" (extras include Cc).
    private var recipientSummary: String {
        let own = Set(store.accounts.map { $0.id.lowercased() })
        let recipients = MessageParser.splitAddresses(message.toHeader)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let ccCount = MessageParser.splitAddresses(message.ccHeader)
            .filter { $0.contains("@") }.count
        guard let first = recipients.first else { return "—" }
        let firstName = own.contains(MessageParser.emailAddress(first).lowercased())
            ? "me" : MessageParser.displayName(fromHeader: first)
        let extra = recipients.count - 1 + ccCount
        return extra > 0 ? "\(firstName) +\(extra)" : firstName
    }

    /// The compact and expanded headers share the same fixed role column.
    /// This keeps bare email addresses and the disclosure chevron optically
    /// aligned instead of centering the glyph against a wrapped text block.
    private var compactRecipientGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: 12,
             verticalSpacing: 3) {
            GridRow {
                recipientRole("FROM")
                participantMenu(
                    message.fromHeader,
                    nameSize: 14,
                    nameWeight: .semibold)
            }
            GridRow {
                recipientRole("TO")
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        recipientsExpanded = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(recipientSummary)
                            .font(.system(size: 12.5 * fontScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8 * fontScale,
                                          weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12, height: 12,
                                   alignment: .center)
                    }
                    .frame(minWidth: 40, minHeight: 40, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("To \(recipientSummary)")
                .accessibilityHint("Show all senders and recipients")
                .help("Show all senders and recipients")
            }
        }
    }

    private func recipientRole(_ role: String) -> some View {
        Text(role)
            .font(.system(size: 10 * fontScale, weight: .medium))
            .foregroundStyle(.tertiary)
            .gridColumnAlignment(.leading)
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
                store.openCompose(.init(replyTo: nil, prefillTo: email))
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
                    .truncationMode(.middle)
                if name.lowercased() != email.lowercased() {
                    Text(email)
                        .font(.system(size: (nameSize - 1.5) * fontScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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

// MARK: - Matching Gmail filters (per message)

/// Collapsible disclosure under an expanded message listing the account's
/// Gmail filters whose criteria match this message. Loads filters lazily
/// via `MailStore.ensureFiltersLoaded`; hidden when none match or filters
/// aren't readable yet (scope / empty account).
private struct MatchingFiltersSection: View {
    @EnvironmentObject var store: MailStore
    let message: Message
    var fontScale: Double = 1.0
    @State private var expanded = false

    private var matches: [GFilter] {
        store.matchingFilters(for: message)
    }

    private var isLoading: Bool {
        store.filtersLoading.contains(message.accountId)
            && store.filtersByAccount[message.accountId] == nil
    }

    var body: some View {
        Group {
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.easeOut(duration: 0.1)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 11 * fontScale))
                            Text(matches.count == 1
                                 ? "1 matching filter"
                                 : "\(matches.count) matching filters")
                                .font(.system(size: 12 * fontScale, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9 * fontScale, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded
                          ? "Hide matching Gmail filters"
                          : "Show Gmail filters that match this message")

                    if expanded {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(matches) { filter in
                                GmailFilterSentenceRow(
                                    filter: filter,
                                    accountId: message.accountId,
                                    compact: true)
                            }
                            Button("Edit filters in Gmail…") {
                                if let url = GmailWebLinks.filtersSettingsURL(
                                    accountEmail: message.accountId) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.system(size: 11 * fontScale))
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 2)
                        .transition(.opacity)
                    }
                }
                .padding(.top, 6)
            } else if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking filters…")
                        .font(.system(size: 11 * fontScale))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
            }
        }
        .task(id: message.accountId) {
            await store.ensureFiltersLoaded(for: message.accountId)
        }
    }
}

/// Sandboxed HTML rendering: page JavaScript disabled; remote images blocked
/// by a WebKit content rule plus CSP unless the user opts in (per message or
/// Settings → Appearance default).
/// Sizes itself to its content. External links open in the default browser.
///
/// Web views are drawn from `HTMLWebViewPool` (recycle + per-view ephemeral
/// store) so expanding/collapsing cards does not thrash WKWebView creation.
///
/// Height updates come from a `ResizeObserver` + image load/error handlers
/// (`HTMLBodyLayout`) posting to a `WKScriptMessageHandler`, not a fixed
/// multi-second poll. Blocked/failed images keep capped authored dimensions
/// so table-based transactional layouts do not collapse under Ask policy.
struct HTMLBodyView: NSViewRepresentable {
    /// Stable O(1)-sized identity supplied by the message card. Never derive
    /// this by hashing the untrusted, potentially multi-megabyte HTML string.
    let contentID: String
    let html: String
    let allowRemoteImages: Bool
    var fontScale: Double = 1.0
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let webView = HTMLWebViewPool.dequeue()
        webView.navigationDelegate = context.coordinator
        // Flag-guarded: recycled views never double-add the handler name.
        webView.installHeightHandler(context.coordinator)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Refresh the binding callback even when the document identity did not
        // change. Capture the Binding only — capturing `self` retains `html`.
        let heightBinding = _height
        context.coordinator.setHeight = { heightBinding.wrappedValue = $0 }

        let key = HTMLBodyLoadKey(
            contentID: contentID,
            allowRemoteImages: allowRemoteImages,
            fontScale: fontScale)
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        context.coordinator.beginRender(
            byteCount: html.utf8.count,
            variant: contentID.hasSuffix(":authored") ? "authored" : "full")
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: allowRemoteImages)
        // Force light text over dark chrome; per-element contrast from
        // effective background (attribute fast path + applyContrastJS).
        // Includes HTMLBodyLayout.imageCSS for blocked-image placeholders.
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: fontScale)
        // Fragments get a synthetic shell; complete documents keep author
        // head styles and receive CSP/CSS via head injection.
        let document = HTMLBodyDocument.assemble(
            html: html, cspMeta: csp, styleCSS: css)
        context.coordinator.load(
            document: document,
            trustedFallback: {
                HTMLBodyDocument.trustedWrapper(
                    html: html, cspMeta: csp, styleCSS: css)
            },
            allowRemoteImages: allowRemoteImages,
            in: webView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.detach(from: nsView)
        HTMLWebViewPool.recycle(nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedKey: HTMLBodyLoadKey?
        var setHeight: ((CGFloat) -> Void)?
        private var loadToken = UUID()
        private var heightStability = HTMLHeightStability()
        private var heightUpdateCount = 0
        private var renderInterval: PerfMetrics.Interval?
        private var renderTimeout: DispatchWorkItem?
        private var acceptsHeightReports = false
        private var navigationGate = HTMLNavigationIdentityGate()

        func beginRender(byteCount: Int, variant: String) {
            finishRender(reason: "superseded")
            acceptsHeightReports = false
            navigationGate.reset()
            heightStability.reset()
            heightUpdateCount = 0
            renderInterval = PerfMetrics.begin(
                .openHTML,
                meta: "bytes=\(byteCount) variant=\(variant)")

            // ResizeObserver normally produces a confirming height quickly.
            // End diagnostics even for malformed documents that never settle.
            let timeout = DispatchWorkItem { [weak self] in
                self?.finishRender(reason: "timeout")
            }
            renderTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        }

        /// Apply/remove the network-level remote-image rule before navigating.
        /// A generation token prevents a late compile callback from mutating a
        /// recycled view or superseding a newer Load-images request.
        func load(document: String, trustedFallback: @escaping () -> String,
                  allowRemoteImages: Bool, in webView: WKWebView) {
            let token = UUID()
            loadToken = token
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
                    // Compilation is expected to be infallible for the static
                    // rule, but privacy fails closed if WebKit rejects it.
                    self.startNavigation(webView, document: trustedFallback())
                }
            }
        }

        private func startNavigation(_ webView: WKWebView, document: String) {
            let navigation = webView.loadHTMLString(document, baseURL: nil)
            navigationGate.didStart(navigation)
        }

        /// Drop height callbacks before the view is recycled so a late
        /// ResizeObserver tick cannot write into a new card. Handler removal
        /// and observer teardown live in `HTMLWebViewPool.recycle` (single
        /// owner — double-remove of a script handler raises).
        func detach(from webView: WKWebView) {
            loadToken = UUID()
            loadedKey = nil
            setHeight = nil
            acceptsHeightReports = false
            navigationGate.reset()
            finishRender(reason: "detached")
            heightStability.reset()
            webView.evaluateJavaScript(HTMLBodyLayout.teardownJS, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigationGate.accepts(navigation) else { return }
            // Primary contrast pass runs as WKUserScript at document-end
            // (WebViewPool) for every navigation, including recycled views.
            // Run the expensive DOM/getComputedStyle walk once, then install
            // layout preservation + continuous measurement.
            acceptsHeightReports = true
            installLayoutAndMeasure(webView)
        }

        private func installLayoutAndMeasure(_ webView: WKWebView) {
            webView.evaluateJavaScript(HTMLBodyLayout.installLayoutAndMeasureJS) { [weak self] result, _ in
                self?.applyMeasuredHeight(result)
            }
        }

        private func applyMeasuredHeight(_ result: Any?) {
            guard acceptsHeightReports else { return }
            let floor = CGFloat(HTMLBodyLayout.minContentHeight)
            let rawHeight: CGFloat?
            if let h = result as? CGFloat {
                rawHeight = h
            } else if let n = result as? NSNumber {
                rawHeight = CGFloat(truncating: n)
            } else if let d = result as? Double {
                rawHeight = CGFloat(d)
            } else if let i = result as? Int {
                rawHeight = CGFloat(i)
            } else {
                rawHeight = nil
            }
            guard let rawHeight, rawHeight > 0 else { return }

            let height = max(rawHeight, floor)
            let observation = heightStability.observe(height)
            if observation.shouldPublish {
                heightUpdateCount += 1
                DispatchQueue.main.async { [weak self] in self?.setHeight?(height) }
            }
            if observation.isStable {
                finishRender(reason: "stable")
            }
        }

        private func finishRender(reason: String) {
            renderTimeout?.cancel()
            renderTimeout = nil
            guard let interval = renderInterval else { return }
            renderInterval = nil
            interval.end(extraMeta: "heightUpdates=\(heightUpdateCount) \(reason)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            guard navigationGate.accepts(navigation) else { return }
            acceptsHeightReports = false
            finishRender(reason: "navigationError")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard navigationGate.accepts(navigation) else { return }
            acceptsHeightReports = false
            finishRender(reason: "provisionalError")
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == HTMLBodyLayout.heightHandlerName else { return }
            applyMeasuredHeight(message.body)
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
