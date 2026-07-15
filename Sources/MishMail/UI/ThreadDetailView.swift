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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
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
            if thread.isUnread { store.setRead(thread, read: true) }
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
    /// Session-wide opt-in shared by every card in the open thread.
    @Binding var loadImagesForThread: Bool
    let onReply: () -> Void
    /// Parent loads the body when a collapsed header-only card expands.
    let onNeedBody: () -> Void
    @State private var expanded: Bool
    // Full FROM/TO/CC rows (Notion Mail's "Show more"); compact by default.
    @State private var recipientsExpanded = false
    @State private var htmlHeight: CGFloat = 120
    /// Per-message opt-in when policy is ask/vip and the sender isn't allowed.
    @State private var loadRemoteImages = false
    /// Manual escape hatch: render multipart plain text instead of HTML.
    /// Useful for privacy-sensitive transactional mail when remote images are
    /// blocked and the HTML shell is unreadable — not an automatic switch.
    @State private var showPlainText = false
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
    /// a few threads' worth. Only cache when a body is present so lazy-loaded
    /// headers don't poison the entry with an empty-body result.
    private static var trailCache: [String: (head: String?, hasTrail: Bool)] = [:]

    init(message: Message, isLast: Bool,
         loadImagesForThread: Binding<Bool> = .constant(false),
         onReply: @escaping () -> Void,
         onNeedBody: @escaping () -> Void = {}) {
        self.message = message
        self.isLast = isLast
        self._loadImagesForThread = loadImagesForThread
        self.onReply = onReply
        self.onNeedBody = onNeedBody
        _expanded = State(initialValue: isLast)
        let hasBody = !ThreadDetailView.needsBodyLoad(message)
        if hasBody, let cached = Self.trailCache[message.id] {
            (textHead, hasQuotedTrail) = cached
        } else if hasBody {
            // Prefer structured HTML collapse (gmail_quote / cite). When HTML
            // has no marker but plain text still has a `>` / "On … wrote:"
            // trail, keep a text head so "…" can hide it (some clients ship
            // nested history as plain `>` lines inside a single HTML div).
            if let html = message.bodyHTML, !html.isEmpty,
               QuotedReply.hasHTMLQuote(html) {
                textHead = nil
                hasQuotedTrail = true
            } else if let head = QuotedReply.splitText(message.bodyText)?.head {
                textHead = head
                hasQuotedTrail = true
            } else {
                textHead = nil
                hasQuotedTrail = false
            }
            if Self.trailCache.count > 512 { Self.trailCache.removeAll() }
            Self.trailCache[message.id] = (textHead, hasQuotedTrail)
        } else {
            textHead = nil
            hasQuotedTrail = false
        }
    }

    private func toggleExpanded() {
        let willExpand = !expanded
        withAnimation { expanded.toggle() }
        if willExpand { onNeedBody() }
    }

    private func expandCard() {
        if !expanded {
            withAnimation { expanded = true }
            onNeedBody()
        }
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
                    HTMLBodyView(html: html, allowRemoteImages: allowRemoteImages,
                                 fontScale: fontScale,
                                 // Structured HTML only: plain-text heads use
                                 // the branch above when collapsed.
                                 collapseQuote: textHead == nil
                                     && hasQuotedTrail && !showQuoted,
                                 height: $htmlHeight)
                        .frame(height: htmlHeight)
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
            if expanded { onNeedBody() }
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

/// Sandboxed HTML rendering: page JavaScript disabled; remote content blocked
/// by CSP unless the user opts in (per message or Settings → Appearance default).
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
    let html: String
    let allowRemoteImages: Bool
    var fontScale: Double = 1.0
    /// Hides the quoted reply trail (Gmail/Apple Mail/Outlook containers)
    /// while the message card's "…" pill is collapsed.
    var collapseQuote: Bool = false
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
        let key = "\(allowRemoteImages):\(fontScale):\(collapseQuote):\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        context.coordinator.setHeight = { self.height = $0 }
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: allowRemoteImages)
        // Force light text over dark chrome; per-element contrast from
        // effective background (attribute fast path + applyContrastJS).
        // Includes HTMLBodyLayout.imageCSS for blocked-image placeholders.
        let css = HTMLBodyDarkMode.injectedCSS(
            fontScale: fontScale, collapseQuote: collapseQuote, html: html)
        // Fragments get a synthetic shell; complete documents keep author
        // head styles and receive CSP/CSS via head injection.
        let document = HTMLBodyDocument.assemble(
            html: html, cspMeta: csp, styleCSS: css)
        webView.loadHTMLString(document, baseURL: nil)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.detach(from: nsView)
        HTMLWebViewPool.recycle(nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedKey: String?
        var setHeight: ((CGFloat) -> Void)?

        /// Drop height callbacks before the view is recycled so a late
        /// ResizeObserver tick cannot write into a new card. Handler removal
        /// and observer teardown live in `HTMLWebViewPool.recycle` (single
        /// owner — double-remove of a script handler raises).
        func detach(from webView: WKWebView) {
            loadedKey = nil
            setHeight = nil
            webView.evaluateJavaScript(HTMLBodyLayout.teardownJS, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Primary contrast pass runs as WKUserScript at document-end
            // (WebViewPool) before first paint. Re-run here for recycled views
            // / late styles, then install layout preservation + continuous
            // measure (ResizeObserver + image events).
            webView.evaluateJavaScript(HTMLBodyDarkMode.applyContrastJS) { [weak self] _, _ in
                self?.installLayoutAndMeasure(webView)
            }
        }

        private func installLayoutAndMeasure(_ webView: WKWebView) {
            webView.evaluateJavaScript(HTMLBodyLayout.installLayoutAndMeasureJS) { [weak self] result, _ in
                self?.applyMeasuredHeight(result)
            }
        }

        private func applyMeasuredHeight(_ result: Any?) {
            let floor = CGFloat(HTMLBodyLayout.minContentHeight)
            if let h = result as? CGFloat, h > 0 {
                DispatchQueue.main.async { self.setHeight?(max(h, floor)) }
            } else if let n = result as? NSNumber {
                let h = CGFloat(truncating: n)
                if h > 0 {
                    DispatchQueue.main.async { self.setHeight?(max(h, floor)) }
                }
            } else if let d = result as? Double, d > 0 {
                DispatchQueue.main.async { self.setHeight?(max(CGFloat(d), floor)) }
            } else if let i = result as? Int, i > 0 {
                DispatchQueue.main.async { self.setHeight?(max(CGFloat(i), floor)) }
            }
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
