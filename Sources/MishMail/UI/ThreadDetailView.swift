import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Per-message card heights — re-scroll when WKWebView grows after a bottom pin.
private struct ThreadMessageHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Disarms auto-pin on trackpad scroll. Offset observation (macOS 15+) is
/// preferred; scroll-wheel monitor covers macOS 14 and single-message threads
/// where `scrollPosition` id never changes.
private final class InlineScrollDisarmGate {
    var onUserScroll: (() -> Void)?
    private var wheelMonitor: Any?

    func setWheelArmed(_ armed: Bool) {
        if armed {
            guard wheelMonitor == nil else { return }
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if abs(event.scrollingDeltaY) > 0.5 || abs(event.scrollingDeltaX) > 0.5 {
                    DispatchQueue.main.async { self?.onUserScroll?() }
                }
                return event
            }
        } else if let monitor = wheelMonitor {
            NSEvent.removeMonitor(monitor)
            wheelMonitor = nil
        }
    }

    deinit {
        if let monitor = wheelMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

/// Scroll anchor for `.scrollPosition(id:)`, held outside plain `@State`.
/// The binding's setter fires every time a message card crosses the top of
/// the viewport while the user scrolls. As `@State`, each of those writes
/// invalidated the entire (eager) thread body — on a thread with many replies
/// that re-diffed every message card per crossing and made scrolling stutter.
/// As an `@Observable` box, user-scroll writes only touch the scroll-position
/// machinery that reads it; programmatic moves also go through
/// `ScrollViewProxy.scrollTo` explicitly.
@Observable
private final class ThreadScrollAnchor {
    var id: String?

    init(id: String? = nil) {
        self.id = id
    }
}

struct ThreadDetailView: View {
    @Environment(MailStore.self) var store
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("readingPaneHidden") private var readingPaneHidden = false
    let thread: MailThread
    let compactMode: Bool
    /// Full-app conversation (⌘↩) — back control exits focus, not the thread.
    var focusMode: Bool = false
    /// Left column of side-by-side compose (⇧⌘↩): back control exits split,
    /// and prev/next hide (selection is decoupled from this conversation).
    var splitMode: Bool = false
    let onBack: () -> Void
    let onReply: (Message) -> Void

    @State private var messages: [Message] = []
    @State private var attachmentsByMessageId: [String: [AttachmentRow]] = [:]
    /// Off-main quote-trail + assembled HTML from `ThreadDetailRepository`.
    @State private var bodyPrepByMessageId: [String: MessageHTMLPrep] = [:]
    @State private var threadAttachments: [(message: Message, attachment: AttachmentRow)] = []
    @State private var scrollAnchor = ThreadScrollAnchor()
    @State private var aiSummary: String?
    @State private var summarizing = false
    @State private var summaryError: String?
    /// Persisted MCP / agent summary (`threadSummary` row). Shown only when no
    /// ephemeral model summary is present.
    @State private var persistedSummary: ThreadSummaryRow?
    /// Session opt-in: Load images for every card in this thread.
    @State private var loadRemoteImagesForThread = false
    /// Message ids we already tried to hydrate — avoids re-querying forever
    /// for genuinely empty bodies (`needsBodyLoad` stays true).
    @State private var bodyLoadAttempted: Set<String> = []
    /// Session-only HTML with `cid:` rewritten to `data:` (not persisted).
    @State private var cidInlinedHTMLById: [String: String] = [:]
    /// Byte count of the body *before* `cid:` → `data:` rewrite, for the
    /// oversized-HTML gate. The resolve handler overwrites the in-memory
    /// `bodyHTML` with the inlined string, so the card can't recover the
    /// pre-inline size from the message itself.
    @State private var cidPreInlineBytesById: [String: Int] = [:]
    /// Avoid re-fetching the same message for Content-ID recovery every expand.
    @State private var cidResolveAttempted: Set<String> = []
    /// Avoid re-fetching the same message for missing-attachment recovery every expand.
    @State private var attachmentRecoverAttempted: Set<String> = []
    /// Open message cards (live HTML body renderers). The reading pane keeps
    /// this to one id (`MessageExpandPolicy.single`); side-by-side compose
    /// opens every sent card so the draft can reference the full thread.
    @State private var expandedMessageIds: Set<String> = []
    /// Reading position to restore when inline compose closes.
    @State private var inlineScrollRestore: InlineScrollRestore = .unset
    @State private var inlineScrollTargetId: String?
    @State private var lastPinnedTargetHeight: CGFloat = 0
    @State private var autoPinInlineScroll = false
    @State private var pinnedComposeRequestId: UUID?
    @State private var writingScrollOffset = false
    @State private var pinnedScrollOffsetY: CGFloat?
    @State private var scrollDisarmGate = InlineScrollDisarmGate()
    @State private var refreshTask: Task<Void, Never>?
    @State private var detailLoadGeneration = 0
    /// Content revision this pane's messages were built from, so a change to
    /// some *other* conversation never triggers a reload here.
    @State private var seenContentRevision: ThreadContentRevision?
    /// Arm neighbor HTML pre-render once per open after the body first settles.
    @State private var neighborPrerenderArmed = false
    /// Message whose Gmail-style Unsubscribe confirm is showing.
    @State private var unsubscribeTarget: Message?
    /// Message ids we already tried to backfill List-Unsubscribe for.
    @State private var unsubscribeRefreshAttempted: Set<String> = []

    /// `.id(thread.id)` remounts this view for every conversation, so `@State`
    /// starts empty and `.task` cannot run until *after* the first body
    /// evaluation — the pane would paint blank for a frame no matter how fast
    /// the payload arrives. Seeding here puts the conversation in that first
    /// frame whenever the caller already had it.
    init(thread: MailThread,
         compactMode: Bool,
         focusMode: Bool = false,
         splitMode: Bool = false,
         initialPayload: ThreadDetailPayload? = nil,
         onBack: @escaping () -> Void,
         onReply: @escaping (Message) -> Void) {
        self.thread = thread
        self.compactMode = compactMode
        self.focusMode = focusMode
        self.splitMode = splitMode
        self.onBack = onBack
        self.onReply = onReply
        guard let initialPayload else { return }
        _messages = State(initialValue: initialPayload.messages)
        _attachmentsByMessageId = State(
            initialValue: initialPayload.attachmentsByMessageId)
        _bodyPrepByMessageId = State(
            initialValue: initialPayload.bodyPrepByMessageId)
        _threadAttachments = State(
            initialValue: ThreadRefresh.threadAttachments(in: initialPayload))
        _scrollAnchor = State(
            initialValue: ThreadScrollAnchor(
                id: ThreadRefresh.initialScrolledMessageId(
                    in: initialPayload.messages)))
        _bodyLoadAttempted = State(
            initialValue: Set(ThreadRefresh.initialBodyLoadSeedIds(
                in: initialPayload.messages)))
    }

    var body: some View {
        ScrollViewReader { proxy in
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
                        .id(ComposePlacement.threadTopScrollId)

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
                        if ForwardComposer.isLiveDraft(message.labelIds) {
                            // Live unsent drafts only — DRAFT+TRASH (discarded)
                            // keeps ordinary MessageCard chrome so Trash still
                            // shows content for discarded-compose threads.
                            // The card steps aside while its own compose editor
                            // is open, and returns when compose closes.
                            if !ComposingDraftVisibility.hidesDraftCard(
                                messageId: message.id,
                                composingDraftIds: store.composingDraftMessageIds) {
                                DraftMessageCard(
                                    message: message,
                                    onNeedBody: { loadBodyIfNeeded(id: message.id) })
                                    .padding(.horizontal)
                                    .id(message.id)
                                    .background { messageHeightReader(id: message.id) }
                            }
                        } else {
                            MessageCard(message: message,
                                        isLast: message.id == lastNonDraftId,
                                        attachments: attachmentsByMessageId[message.id] ?? [],
                                        bodyPrep: bodyPrepByMessageId[message.id],
                                        cidInlinedHTML: cidInlinedHTMLById[message.id],
                                        cidPreInlineBytes: cidPreInlineBytesById[message.id],
                                        expandPolicy: messageExpandPolicy,
                                        expandedMessageIds: $expandedMessageIds,
                                        loadImagesForThread: $loadRemoteImagesForThread,
                                        onReply: { onReply(message) },
                                        onNeedBody: { loadBodyIfNeeded(id: message.id) },
                                        onBodySettled: { armNeighborPrerenderIfNeeded() },
                                        onUnsubscribe: { unsubscribeTarget = message },
                                        onNeedUnsubscribeHeaders: {
                                            Task { await refreshUnsubscribeHeaders(message) }
                                        })
                                .padding(.horizontal)
                                .id(message.id)
                                .background { messageHeightReader(id: message.id) }
                        }
                    }

                }
                .scrollTargetLayout()
                .padding(.vertical)
            }
            // Stable top anchor for reading; inline reply uses one-shot bottom
            // scrollTo so dismiss does not flip anchors and jump the thread.
            .scrollPosition(id: scrollAnchorBinding, anchor: .top)
            .modifier(ScrollOffsetDisarmModifier { oldY, newY in
                noteScrollOffsetChange(from: oldY, to: newY)
            })
            .navigationTitle(store.selectedView.title)
            // `.navigation` placement pins to the window's far leading edge
            // (traffic lights / above the sidebar) on macOS 26. Use
            // `.principal` so the close/prev/next trio sits in the detail
            // column's title region — left of the thread chrome, not over
            // the sidebar.
            .toolbarRole(.editor)
            .toolbar {
            // Notion Mail-style left cluster: close the pane, prev/next thread.
            // Separate ToolbarItems (not a group) + hidden shared glass on
            // macOS 26 so they don't merge into one capsule that lights up
            // when the thread scrolls. Spacers keep the trio off the title.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .principal)
            }
            ToolbarItem(placement: .principal) {
                if splitMode {
                    Button(action: onBack) {
                        Label("Exit Side by Side",
                              systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Exit side by side (esc or ⇧⌘↩)")
                    .accessibilityIdentifier("exitSplitButton")
                    .focusable(false)
                    .focusEffectDisabled()
                } else if focusMode {
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
            // Prev/next drive the list selection, which split's conversation
            // column is decoupled from — hide them there.
            if !splitMode {
                ToolbarItem(placement: .principal) {
                    Button { store.moveSelection(-1, intent: .explicitOpen) } label: {
                        Label("Previous", systemImage: "chevron.up")
                    }
                    .help("Previous conversation (\(store.keyBindings.key(for: .prev)))")
                    .focusable(false)
                    .focusEffectDisabled()
                }
                .pmHideSharedBackground()
                ToolbarItem(placement: .principal) {
                    Button { store.moveSelection(1, intent: .explicitOpen) } label: {
                        Label("Next", systemImage: "chevron.down")
                    }
                    .help("Next conversation (\(store.keyBindings.key(for: .next)))")
                    .focusable(false)
                    .focusEffectDisabled()
                }
                .pmHideSharedBackground()
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .principal)
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
                    if let msg = ListUnsubscribe.preferredMessage(in: messages) {
                        Button {
                            unsubscribeTarget = msg
                        } label: {
                            Label("Unsubscribe",
                                  systemImage: "envelope.badge.minus")
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
            .task(id: thread.id) {
                detailLoadGeneration &+= 1
                let loadGeneration = detailLoadGeneration
                // Seed before the load: anything that lands after this point
                // is a real change and must refresh, anything already folded
                // into this payload must not.
                seenContentRevision = store.contentRevision(of: thread.id)
                bodyLoadAttempted = []
                cidInlinedHTMLById = [:]
                cidPreInlineBytesById = [:]
                cidResolveAttempted = []
                loadRemoteImagesForThread = false
                expandedMessageIds = []
                neighborPrerenderArmed = false
                unsubscribeTarget = nil
                unsubscribeRefreshAttempted = []
                // Cancel any in-flight neighbor paints from the previous open.
                HTMLBodyNeighborPrerender.cancel()
                // Did `init` already seed from the mirror? When this is 1 the
                // first rendered frame already showed the conversation; when
                // it is 0 the pane painted empty until this task ran.
                let preseeded = messages.isEmpty ? 0 : 1
                let readyInterval = PerfMetrics.begin(
                    .openReady, meta: "thread=\(thread.id) preseeded=\(preseeded)")
                // Paint from the main-actor mirror when the payload is already
                // known — no `await`, so the pane lands in the same frame as
                // the row removal. This is the common case on the advance path
                // (the neighbour was warmed by `scheduleNeighborPrefetch`), and
                // it is the whole point: going to the repository costs a
                // round-trip whose return hop waits on the SwiftUI work the
                // delete just queued, which measured 176–209 ms.
                if let warm = store.warmThreadDetail(threadId: thread.id) {
                    applyDetailPayload(warm, proxy: proxy)
                    readyInterval.end(extraMeta: "warm n=\(warm.messages.count)")
                } else {
                    let load = await store.threadDetailPayload(threadId: thread.id)
                    guard !Task.isCancelled else {
                        readyInterval.end(extraMeta: "cancelled")
                        return
                    }
                    if loadGeneration == detailLoadGeneration,
                       splitMode || store.openedThreadId == thread.id {
                        applyDetailPayload(load.payload, proxy: proxy)
                        readyInterval.end(
                            extraMeta: "\(load.cacheHit ? "cache_hit" : "cache_miss")"
                                + " n=\(load.payload.messages.count)")
                    } else {
                        readyInterval.end(extraMeta: "superseded")
                    }
                }
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
            // Some thread's message rows changed (sync, draft discard, send…).
            // Refresh in place — a discarded draft's card disappears without
            // navigating away — but only when it was *this* thread: a sync
            // touching other conversations must not disturb what we're reading.
            // Scroll anchor and summary stay put.
            .onChange(of: store.threadContentToken) {
                let revision = store.contentRevision(of: thread.id)
                guard revision != seenContentRevision else { return }
                seenContentRevision = revision
                refreshMessages(proxy: proxy)
            }
            // Suppression changes no content revision (it is applied to the
            // payload on the way out, not cached), so it needs its own nudge.
            // The reload behind it is a cache hit.
            .onChange(of: store.suppressedDraftMessageIds) {
                refreshMessages(proxy: proxy)
            }
            .onChange(of: inlineComposeActive) { _, active in
                if active {
                    beginInlineComposeScroll(proxy: proxy)
                } else {
                    endInlineComposeScroll(proxy: proxy)
                }
            }
            .onChange(of: store.composeRequest?.id) { oldId, newId in
                guard inlineComposeActive, let newId, oldId != nil else { return }
                guard autoPinInlineScroll else { return }
                guard newId != pinnedComposeRequestId else { return }
                pinnedComposeRequestId = newId
                lastPinnedTargetHeight = 0
                scrollInlineComposeTarget(proxy, releaseTopPin: false)
            }
            .onChange(of: autoPinInlineScroll) { _, armed in
                scrollDisarmGate.onUserScroll = { disarmAutoPin() }
                scrollDisarmGate.setWheelArmed(armed && inlineComposeActive)
            }
            .onDisappear {
                scrollDisarmGate.setWheelArmed(false)
                detailLoadGeneration &+= 1
                refreshTask?.cancel()
                refreshTask = nil
                neighborPrerenderArmed = false
                HTMLBodyNeighborPrerender.cancel()
            }
            .onPreferenceChange(ThreadMessageHeightKey.self) { heights in
                guard inlineComposeActive, autoPinInlineScroll,
                      let target = inlineScrollTargetId,
                      let height = heights[target] else { return }
                if height > lastPinnedTargetHeight + 8 {
                    lastPinnedTargetHeight = height
                    scrollInlineComposeTarget(proxy, releaseTopPin: false)
                } else if lastPinnedTargetHeight == 0 {
                    lastPinnedTargetHeight = height
                }
            }
            .alert(
                unsubscribeTarget.map {
                    ListUnsubscribe.confirmationTitle(fromHeader: $0.fromHeader)
                } ?? "Unsubscribe?",
                isPresented: Binding(
                    get: { unsubscribeTarget != nil },
                    set: { if !$0 { unsubscribeTarget = nil } })
            ) {
                Button("Unsubscribe") {
                    if let msg = unsubscribeTarget {
                        store.unsubscribe(from: msg)
                    }
                    unsubscribeTarget = nil
                }
                Button("Cancel", role: .cancel) {
                    unsubscribeTarget = nil
                }
            } message: {
                if let msg = unsubscribeTarget,
                   let action = ListUnsubscribe.offer(from: msg)?.preferredAction {
                    Text(ListUnsubscribe.confirmationDetail(for: action))
                }
            }
        }
    }

    /// User-scroll writes land here (not in a `@State`), so a fling through a
    /// long thread never invalidates the whole body. The disarm check that
    /// used to live in `.onChange(of: scrolledMessageId)` runs in the setter,
    /// deferred a turn (like `onChange` was) so the `@State` write never lands
    /// inside the scroll machinery's own update.
    private var scrollAnchorBinding: Binding<String?> {
        Binding(
            get: { scrollAnchor.id },
            set: { newValue in
                let changed = newValue != scrollAnchor.id
                scrollAnchor.id = newValue
                guard changed else { return }
                DispatchQueue.main.async {
                    guard inlineComposeActive, autoPinInlineScroll,
                          !writingScrollOffset else { return }
                    disarmAutoPin()
                }
            })
    }

    /// Programmatic anchor move: record it and scroll explicitly next turn,
    /// after the freshly assigned `messages` have produced rows to target.
    /// (`scrollAnchor` writes alone no longer re-render anything, so the old
    /// binding-driven post-layout anchoring must be an explicit `scrollTo`.)
    private func applyScrollAnchor(_ id: String?, proxy: ScrollViewProxy) {
        scrollAnchor.id = id
        guard let id else { return }
        DispatchQueue.main.async {
            var t = Transaction()
            t.animation = nil
            withTransaction(t) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private enum InlineScrollRestore: Equatable {
        case unset
        case threadTop
        case message(String)
    }

    private struct ScrollOffsetDisarmModifier: ViewModifier {
        let onOffset: (CGFloat, CGFloat) -> Void

        func body(content: Content) -> some View {
            if #available(macOS 15.0, *) {
                content.onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y
                } action: { oldY, newY in
                    onOffset(oldY, newY)
                }
            } else {
                content
            }
        }
    }

    private func messageHeightReader(id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ThreadMessageHeightKey.self,
                value: [id: geo.size.height])
        }
    }

    private var inlineComposeActive: Bool {
        guard let req = store.composeRequest,
              req.presentation == .inline,
              !store.composeMinimized,
              req.boundThreadId == thread.id else { return false }
        return true
    }

    private func disarmAutoPin() {
        guard autoPinInlineScroll else { return }
        autoPinInlineScroll = false
        pinnedScrollOffsetY = nil
    }

    private func noteScrollOffsetChange(from oldY: CGFloat, to newY: CGFloat) {
        if writingScrollOffset {
            pinnedScrollOffsetY = newY
            return
        }
        guard inlineComposeActive, autoPinInlineScroll else { return }
        if let pinned = pinnedScrollOffsetY, abs(newY - pinned) < 2 {
            return
        }
        if abs(newY - oldY) < 0.5 { return }
        disarmAutoPin()
    }

    private func beginInlineComposeScroll(proxy: ScrollViewProxy) {
        if pinnedComposeRequestId == store.composeRequest?.id {
            return
        }
        if inlineScrollRestore == .unset {
            if let id = scrollAnchor.id {
                inlineScrollRestore = .message(id)
            } else {
                inlineScrollRestore = .threadTop
            }
        }
        autoPinInlineScroll = true
        pinnedComposeRequestId = store.composeRequest?.id
        pinnedScrollOffsetY = nil
        lastPinnedTargetHeight = 0
        scrollInlineComposeTarget(proxy, releaseTopPin: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard inlineComposeActive, autoPinInlineScroll else { return }
            scrollInlineComposeTarget(proxy, releaseTopPin: false)
        }
    }

    private func endInlineComposeScroll(proxy: ScrollViewProxy) {
        let restore = inlineScrollRestore
        inlineScrollRestore = .unset
        inlineScrollTargetId = nil
        lastPinnedTargetHeight = 0
        autoPinInlineScroll = false
        pinnedComposeRequestId = nil
        pinnedScrollOffsetY = nil
        writingScrollOffset = true
        var t = Transaction()
        t.animation = nil
        withTransaction(t) {
            switch restore {
            case .unset:
                writingScrollOffset = false
            case .threadTop:
                scrollAnchor.id = nil
                DispatchQueue.main.async {
                    var inner = Transaction()
                    inner.animation = nil
                    withTransaction(inner) {
                        proxy.scrollTo(ComposePlacement.threadTopScrollId, anchor: .top)
                    }
                    DispatchQueue.main.async { writingScrollOffset = false }
                }
            case .message(let id):
                applyScrollAnchor(id, proxy: proxy)
                DispatchQueue.main.async { writingScrollOffset = false }
            }
        }
    }

    private func scrollInlineComposeTarget(_ proxy: ScrollViewProxy,
                                           releaseTopPin: Bool) {
        guard autoPinInlineScroll || releaseTopPin else { return }
        let target = ComposePlacement.scrollTargetId(
            replyTo: store.composeRequest?.replyTo,
            messages: messages)
        guard let target else { return }
        if target != inlineScrollTargetId {
            inlineScrollTargetId = target
            lastPinnedTargetHeight = 0
        }
        writingScrollOffset = true
        var t = Transaction()
        t.animation = nil
        withTransaction(t) {
            if releaseTopPin { scrollAnchor.id = nil }
            DispatchQueue.main.async {
                var inner = Transaction()
                inner.animation = nil
                withTransaction(inner) {
                    proxy.scrollTo(target, anchor: .bottom)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    writingScrollOffset = false
                }
            }
        }
    }

    /// Re-query this thread's rows and merge into the visible list, keeping
    /// already-hydrated bodies so open cards don't collapse back to
    /// "Loading…". No-op when nothing about the thread changed.
    private func refreshMessages(proxy: ScrollViewProxy) {
        detailLoadGeneration &+= 1
        let loadGeneration = detailLoadGeneration
        refreshTask?.cancel()
        refreshTask = Task {
            // No forceReload: the revision carried by the request is the source
            // of truth now. A real content change misses and re-reads; a
            // suppression-only refresh hits the warm entry.
            let load = await store.threadDetailPayload(threadId: thread.id)
            guard !Task.isCancelled,
                  loadGeneration == detailLoadGeneration,
                  splitMode || store.openedThreadId == thread.id else { return }
            // Superseded initial .task leaves messages empty; when merge is
            // the first population, apply the same anchor/seed as open.
            let wasEmpty = messages.isEmpty
            // Capture before merge so "new" means arrived-this-refresh, not
            // "user collapsed" (which would re-open on every sync).
            let priorIds = Set(messages.map(\.id))
            let merged = ThreadRefresh.merge(
                current: messages, fresh: load.payload.messages)
            attachmentsByMessageId = load.payload.attachmentsByMessageId
            // Keep prep for bodies we already hydrated that the fresh payload
            // may have as header-only; overlay with any newly computed prep.
            var mergedPrep = bodyPrepByMessageId
            for (id, prep) in load.payload.bodyPrepByMessageId {
                mergedPrep[id] = prep
            }
            bodyPrepByMessageId = mergedPrep
            threadAttachments = merged.flatMap { msg in
                (attachmentsByMessageId[msg.id] ?? []).map {
                    (message: msg, attachment: $0)
                }
            }
            guard merged != messages else { return }
            withAnimation(PMMotion.interactive) {
                messages = merged
            }
            backfillUnsubscribeHeaders()
            if wasEmpty {
                bodyLoadAttempted.formUnion(
                    ThreadRefresh.initialBodyLoadSeedIds(in: merged))
                applyScrollAnchor(
                    ThreadRefresh.initialScrolledMessageId(in: merged),
                    proxy: proxy)
                // First population via refresh (initial .task was superseded):
                // open the policy default set, same as applyDetailPayload.
                seedExpandedMessagesIfNeeded()
            } else {
                // Drop ids that left the thread (send/discard renumber).
                let live = Set(nonDraftMessageIds)
                expandedMessageIds = expandedMessageIds.intersection(live)
                // Side-by-side: open only messages that arrived this refresh.
                // Diff against prior message ids so a manual collapse survives
                // background sync / draft-suppression refreshes.
                if messageExpandPolicy == .multiple {
                    let arrived = live.subtracting(priorIds)
                    if !arrived.isEmpty {
                        expandedMessageIds.formUnion(arrived)
                        for id in arrived { loadBodyIfNeeded(id: id) }
                    }
                }
            }
        }
    }

    /// True when a reading-pane message still needs a body fetch.
    static func needsBodyLoad(_ message: Message) -> Bool {
        ThreadRefresh.needsBodyLoad(message)
    }

    /// Live (unsent, not trashed) drafts currently in the open thread.
    private var liveDraftIds: [String] {
        messages.filter { ForwardComposer.isLiveDraft($0.labelIds) }.map(\.id)
    }

    /// Banner only when the draft card is likely below the first viewport
    /// (≥4 messages) and that draft isn't already open in compose. Shorter
    /// threads already show the draft card on screen.
    private var showDraftBanner: Bool {
        ComposingDraftVisibility.showsDraftBanner(
            liveDraftIds: liveDraftIds,
            messageCount: messages.count,
            composingDraftIds: store.composingDraftMessageIds)
    }

    /// Expand the newest *sent* message by default — drafts get their own card
    /// and must not steal the "last card is expanded" affordance from the
    /// conversation the user is reading.
    private var lastNonDraftId: String? {
        ForwardComposer.newestSentMessage(in: messages)?.id
    }

    /// Side-by-side opens every sent card; the reading pane stays single-active.
    private var messageExpandPolicy: MessageExpandPolicy {
        splitMode ? .multiple : .single
    }

    /// Non-draft message ids in display order (drafts render as `DraftMessageCard`).
    private var nonDraftMessageIds: [String] {
        messages
            .filter { !ForwardComposer.isLiveDraft($0.labelIds) }
            .map(\.id)
    }

    /// Seed open cards for the active policy and hydrate each body.
    ///
    /// Multiple mode always re-applies the full seed: MessageCard's last-card
    /// `onAppear` can race and open only the newest id before this runs, which
    /// would otherwise leave older cards collapsed in side-by-side.
    private func seedExpandedMessagesIfNeeded() {
        let seed = MessageExpandPolicy.initialExpandedIds(
            policy: messageExpandPolicy,
            nonDraftIds: nonDraftMessageIds,
            lastNonDraftId: lastNonDraftId)
        switch messageExpandPolicy {
        case .multiple:
            expandedMessageIds = seed
        case .single:
            guard expandedMessageIds.isEmpty else { return }
            expandedMessageIds = seed
        }
        for id in expandedMessageIds {
            loadBodyIfNeeded(id: id)
        }
    }

    /// Hydrate one message's body into `messages` when the user expands it.
    private func loadBodyIfNeeded(id: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        guard Self.needsBodyLoad(messages[idx]) else {
            // Body already present (newest message, cache hit) — still try CID
            // and missing-attachment recovery.
            recoverAttachmentsIfNeeded(id: id)
            resolveCIDImagesIfNeeded(id: id)
            return
        }
        guard !bodyLoadAttempted.contains(id) else { return }
        bodyLoadAttempted.insert(id)
        Task {
            guard let loaded = await store.messageBodyForReadingPane(id: id),
                  splitMode || store.openedThreadId == thread.id,
                  let currentIdx = messages.firstIndex(where: { $0.id == id })
            else { return }
            messages[currentIdx] = loaded.message
            bodyPrepByMessageId[id] = loaded.prep
            recoverAttachmentsIfNeeded(id: id)
            resolveCIDImagesIfNeeded(id: id)
        }
    }

    /// Full re-fetch when this card has no attachment chips but Gmail may still
    /// have files (stale body-without-attachments cache). Session-once per id.
    private func recoverAttachmentsIfNeeded(id: String) {
        guard !attachmentRecoverAttempted.contains(id) else { return }
        guard let msg = messages.first(where: { $0.id == id }) else { return }
        let localCount = (attachmentsByMessageId[id] ?? []).count
        guard SyncEngine.shouldRecoverAttachments(
            hasAttachmentFlag: msg.hasAttachment,
            localAttachmentCount: localCount,
            accountRepairCompleted: SyncEngine.attachmentRepairCompleted(
                accountId: msg.accountId)
        ) else { return }
        attachmentRecoverAttempted.insert(id)
        Task {
            guard let result = await store.recoverAttachmentsIfNeeded(
                message: msg, localAttachmentCount: localCount)
            else { return }
            await MainActor.run {
                guard splitMode || store.openedThreadId == thread.id else { return }
                if let idx = messages.firstIndex(where: { $0.id == id }) {
                    var merged = result.message
                    // Keep any session CID-inlined HTML if we already resolved it.
                    if let inlined = cidInlinedHTMLById[id] {
                        merged.bodyHTML = inlined
                    }
                    messages[idx] = merged
                    if cidInlinedHTMLById[id] == nil {
                        bodyPrepByMessageId[id] = MessageHTMLPrepBuilder.prep(
                            bodyText: merged.bodyText,
                            bodyHTML: merged.bodyHTML,
                            fontScale: fontScale)
                    }
                }
                attachmentsByMessageId[id] = result.attachments
                threadAttachments = messages.flatMap { m in
                    (attachmentsByMessageId[m.id] ?? []).map {
                        (message: m, attachment: $0)
                    }
                }
            }
        }
    }

    /// Download / re-parse Content-ID image parts and rewrite `cid:` → `data:`
    /// for the open card. Local bytes only — not gated on Load images.
    private func resolveCIDImagesIfNeeded(id: String) {
        guard !cidResolveAttempted.contains(id) else { return }
        guard let msg = messages.first(where: { $0.id == id }),
              let html = msg.bodyHTML,
              CIDImageInliner.containsCIDReferences(html)
        else { return }
        cidResolveAttempted.insert(id)
        let atts = attachmentsByMessageId[id] ?? []
        Task {
            guard let result = await store.inlineCIDImages(
                message: msg, attachments: atts, html: html)
            else { return }
            await MainActor.run {
                guard splitMode || store.openedThreadId == thread.id else { return }
                cidInlinedHTMLById[id] = result.html
                cidPreInlineBytesById[id] = html.utf8.count
                attachmentsByMessageId[id] = result.attachments
                if let refreshed = result.refreshedMessage,
                   let idx = messages.firstIndex(where: { $0.id == id }) {
                    // Keep session-inlined HTML on the card via cidInlinedHTMLById;
                    // update headers/snippet from the re-fetch but leave the
                    // stored body prep pointing at DB HTML until rebuild below.
                    var merged = refreshed
                    merged.bodyHTML = result.html
                    messages[idx] = merged
                    bodyPrepByMessageId[id] = MessageHTMLPrepBuilder.prep(
                        bodyText: merged.bodyText,
                        bodyHTML: result.html,
                        fontScale: fontScale)
                } else if let idx = messages.firstIndex(where: { $0.id == id }) {
                    var copy = messages[idx]
                    copy.bodyHTML = result.html
                    messages[idx] = copy
                    bodyPrepByMessageId[id] = MessageHTMLPrepBuilder.prep(
                        bodyText: copy.bodyText,
                        bodyHTML: result.html,
                        fontScale: fontScale)
                }
                threadAttachments = messages.flatMap { m in
                    (attachmentsByMessageId[m.id] ?? []).map {
                        (message: m, attachment: $0)
                    }
                }
            }
        }
    }

    /// Mount a freshly loaded (or mirrored) payload. Shared by the synchronous
    /// warm path and the awaited fallback so both land identical state.
    private func applyDetailPayload(_ payload: ThreadDetailPayload,
                                    proxy: ScrollViewProxy) {
        let loaded = payload.messages
        // Newest sent + draft cards arrive hydrated; seed so we don't
        // re-query. Shared with refreshMessages' empty→full path.
        bodyLoadAttempted.formUnion(ThreadRefresh.initialBodyLoadSeedIds(in: loaded))
        messages = loaded
        attachmentsByMessageId = payload.attachmentsByMessageId
        bodyPrepByMessageId = payload.bodyPrepByMessageId
        threadAttachments = ThreadRefresh.threadAttachments(in: payload)
        // Anchor on newest sent when multi-message; draft-only falls back to
        // the last row so a pure-draft pane still positions.
        applyScrollAnchor(
            ThreadRefresh.initialScrolledMessageId(in: messages),
            proxy: proxy)
        if inlineComposeActive {
            beginInlineComposeScroll(proxy: proxy)
        }
        aiSummary = nil; summaryError = nil; summarizing = false
        // Open the policy's default card set (newest only, or every sent card
        // in side-by-side) and hydrate bodies + CID/attachment recovery.
        seedExpandedMessagesIfNeeded()
        for id in expandedMessageIds {
            recoverAttachmentsIfNeeded(id: id)
            resolveCIDImagesIfNeeded(id: id)
        }
        backfillUnsubscribeHeaders()
    }

    /// Pre-v37 rows have nil List-Unsubscribe. Fill the newest few so the
    /// Gmail-style control appears without a full resync.
    private func backfillUnsubscribeHeaders() {
        let stale = messages
            .filter { $0.listUnsubscribe == nil }
            .sorted { $0.date > $1.date }
            .prefix(3)
        for msg in stale {
            Task { await refreshUnsubscribeHeaders(msg) }
        }
    }

    private func refreshUnsubscribeHeaders(_ message: Message) async {
        guard message.listUnsubscribe == nil else { return }
        guard !unsubscribeRefreshAttempted.contains(message.id) else { return }
        unsubscribeRefreshAttempted.insert(message.id)
        guard let headers = await store.refreshUnsubscribeHeaders(message) else { return }
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[idx].listUnsubscribe = headers.0
        messages[idx].listUnsubscribePost = headers.1
    }

    /// After the open body's first stable paint, warm prev/next newest-message
    /// HTML into pooled WebViews (using payloads already in the detail LRU
    /// when neighbor prefetch has finished).
    private func armNeighborPrerenderIfNeeded() {
        guard !neighborPrerenderArmed else { return }
        guard splitMode || store.openedThreadId == thread.id else { return }
        neighborPrerenderArmed = true
        let order = store.displayOrder.isEmpty
            ? store.threads.map(\.id)
            : store.displayOrder
        let scale = fontScale
        // Never load remote images for neighbor pre-render — focus-past is not
        // an open, and VIP/always policy must not fire tracking pixels here.
        HTMLBodyNeighborPrerender.schedule(
            openedThreadId: thread.id,
            displayOrder: order,
            fontScale: scale,
            loadPayload: { [store] threadId in
                await store.threadDetailPayload(threadId: threadId).payload
            })
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

    /// AI summary. Only offered for multi-message threads (a single short
    /// message doesn't need one). Collapses to a one-line affordance until
    /// asked; the summary streams from the selected provider. Ephemeral model
    /// output takes precedence over a persisted MCP `threadSummary` row.
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
                } else if let persisted = persistedSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11 * fontScale))
                                .foregroundStyle(.tint)
                            Text(persisted.summary)
                                .font(.system(size: 12.5 * fontScale))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 8) {
                            Text("Summarized by \(persisted.model)")
                            Spacer(minLength: 8)
                            Text("Summary generated \(persisted.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                        .font(.system(size: 10.5 * fontScale))
                        .foregroundStyle(.secondary)
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
                    .help("Generate an AI TL;DR of this thread")
                }
                if let summaryError {
                    Text(summaryError)
                        .font(.system(size: 11 * fontScale))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .task(id: thread.id) {
                await loadPersistedSummary()
            }
        }
    }

    private func loadPersistedSummary() async {
        let id = thread.id
        let row = try? await AppDatabase.shared.dbPool.read { db in
            try ThreadSummaryRow.fetchOne(db, key: id)
        }
        await MainActor.run {
            guard thread.id == id else { return }
            persistedSummary = row
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
        let prompt = LLMPrompts.summarize(subject: thread.subject, body: body)
        Task {
            do {
                var accumulated = ""
                for try await piece in LLMTaskRunner.stream(task: .summaries, prompt: prompt) {
                    accumulated += piece
                    let snapshot = accumulated
                    await MainActor.run { aiSummary = snapshot }
                }
                if accumulated.isEmpty {
                    await MainActor.run { summaryError = "No summary was produced." }
                }
            } catch {
                await MainActor.run {
                    summaryError = LLMTaskRunner.errorMessage(error, task: .summaries)
                }
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
    @Environment(MailStore.self) var store
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
            // Tap-to-edit on chrome + preview only. Buttons sit outside the
            // gesture so Discard isn't stolen by editDraft on macOS (a parent
            // onTapGesture over Buttons often wins the hit test).
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
                    Text(message.date, format: message.date.messageHeaderFormat)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    // Sender/recipient chrome is muted like the preview: a draft
                    // is not a message in the conversation, so it must not read
                    // with a sent card's primary-text weight.
                    Text(MessageParser.displayName(fromHeader: message.fromHeader))
                        .font(.system(size: 13.5 * fontScale, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(toSummary)
                        .font(.system(size: 12.5 * fontScale))
                        .foregroundStyle(.tertiary)
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
                    // No textSelection: preview is tap-to-edit, so a selection
                    // gesture would fight the hit target.
                    Text(preview)
                        .font(.system(size: 14 * fontScale))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { store.editDraft(message) }

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
    @Environment(MailStore.self) var store
    @AppStorage("fontScale") private var fontScale = 1.0
    /// Settings → Appearance. Default `.ask` so tracking pixels stay blocked.
    @AppStorage(RemoteImagePolicy.defaultsKey) private var remoteImagePolicyRaw =
        RemoteImagePolicy.ask.rawValue
    let message: Message
    let isLast: Bool
    let attachments: [AttachmentRow]
    /// Off-main precomputed trail + assembled documents from the repository.
    let bodyPrep: MessageHTMLPrep?
    /// Session-only body with `cid:` images rewritten to `data:` URIs.
    /// When set, preferred over `message.bodyHTML` / preassembled docs.
    let cidInlinedHTML: String?
    let cidPreInlineBytes: Int?
    /// Single-active reading pane vs multi-open side-by-side compose.
    let expandPolicy: MessageExpandPolicy
    @Binding var expandedMessageIds: Set<String>
    /// Session-wide opt-in shared by every card in the open thread.
    @Binding var loadImagesForThread: Bool
    let onReply: () -> Void
    /// Parent loads the body when a collapsed header-only card expands.
    let onNeedBody: () -> Void
    /// Parent arms neighbor HTML pre-render after this card's body settles.
    let onBodySettled: () -> Void
    /// Parent shows the Gmail-style unsubscribe confirm for this message.
    let onUnsubscribe: () -> Void
    /// Parent fills List-Unsubscribe on pre-v37 rows (nil).
    let onNeedUnsubscribeHeaders: () -> Void
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
    /// Pre-assembled WebKit documents (nil when scale mismatched or absent).
    private let htmlDocuments: MessageHTMLDocuments?

    /// Fallback NSCache for cards opened without a repository prep (e.g. rare
    /// main-thread-only paths). Primary path is `bodyPrep` from the actor.
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
         attachments: [AttachmentRow] = [],
         bodyPrep: MessageHTMLPrep? = nil,
         cidInlinedHTML: String? = nil,
         cidPreInlineBytes: Int? = nil,
         expandPolicy: MessageExpandPolicy = .single,
         expandedMessageIds: Binding<Set<String>>,
         loadImagesForThread: Binding<Bool> = .constant(false),
         onReply: @escaping () -> Void,
         onNeedBody: @escaping () -> Void = {},
         onBodySettled: @escaping () -> Void = {},
         onUnsubscribe: @escaping () -> Void = {},
         onNeedUnsubscribeHeaders: @escaping () -> Void = {}) {
        self.message = message
        self.isLast = isLast
        self.attachments = attachments
        self.bodyPrep = bodyPrep
        self.cidInlinedHTML = cidInlinedHTML
        self.cidPreInlineBytes = cidPreInlineBytes
        self.expandPolicy = expandPolicy
        self._expandedMessageIds = expandedMessageIds
        self._loadImagesForThread = loadImagesForThread
        self.onReply = onReply
        self.onNeedBody = onNeedBody
        self.onBodySettled = onBodySettled
        self.onUnsubscribe = onUnsubscribe
        self.onNeedUnsubscribeHeaders = onNeedUnsubscribeHeaders
        let hasBody = !ThreadDetailView.needsBodyLoad(message)
        // CID-inlined HTML already embeds image bytes; prefer it over the
        // repository prep (which still has unresolved `cid:`).
        if hasBody, let inlined = cidInlinedHTML, !inlined.isEmpty {
            let fullBytes = inlined.utf8.count
            let detectedHead: String? = {
                if fullBytes <= HTMLBodyRenderPolicy.maximumAutomaticBytes {
                    return QuotedReply.authoredHTMLHead(inlined)
                }
                return QuotedReply.authoredHTMLHead(
                    inlined,
                    scanCharacterLimit: HTMLBodyRenderPolicy.oversizedQuoteScanCharacterLimit)
            }()
            if let head = detectedHead {
                textHead = nil
                htmlHead = head
                hasQuotedTrail = true
            } else {
                textHead = nil
                htmlHead = nil
                hasQuotedTrail = false
            }
            // Gate the oversized-HTML placeholder on the pre-inline body:
            // data: URI growth is image payload WebKit handles fine, and a
            // message that rendered automatically before inlining must not
            // flip into the approval placeholder because its images resolved.
            // (Can't measure message.bodyHTML — the resolve handler overwrote
            // it with the inlined string; the caller stashes the true size.)
            htmlBytes = cidPreInlineBytes ?? fullBytes
            htmlHeadBytes = min(htmlHead?.utf8.count ?? 0, htmlBytes)
            htmlDocuments = nil
        } else if hasBody, let prep = bodyPrep {
            textHead = prep.textHead
            htmlHead = prep.htmlHead
            hasQuotedTrail = prep.hasQuotedTrail
            htmlBytes = prep.htmlBytes
            htmlHeadBytes = prep.htmlHeadBytes
            htmlDocuments = prep.documents
        } else if hasBody, let cached = Self.trailCache.object(forKey: message.id as NSString) {
            textHead = cached.textHead
            htmlHead = cached.htmlHead
            hasQuotedTrail = cached.hasTrail
            htmlBytes = cached.htmlBytes
            htmlHeadBytes = cached.htmlHeadBytes
            htmlDocuments = nil
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
            htmlDocuments = nil
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
            htmlDocuments = nil
        }
    }

    private func toggleExpanded() {
        let willExpand = !expanded
        withAnimation(.easeOut(duration: 0.12)) {
            expandedMessageIds = expandPolicy.applyingToggle(
                id: message.id, currently: expandedMessageIds)
        }
        if willExpand { onNeedBody() }
    }

    private func expandCard() {
        if !expanded {
            withAnimation(.easeOut(duration: 0.12)) {
                expandedMessageIds = expandPolicy.applyingExpand(
                    id: message.id, currently: expandedMessageIds)
            }
            onNeedBody()
        }
    }

    private var expanded: Bool {
        expandedMessageIds.contains(message.id)
    }

    private var remoteImagePolicy: RemoteImagePolicy {
        RemoteImagePolicy(rawValue: remoteImagePolicyRaw) ?? .ask
    }

    /// Policy + VIP list + per-message / per-thread opt-in. VIP auto-load is
    /// gated on Gmail's auth verdict so a spoofed From: can't fire trackers.
    private var allowRemoteImages: Bool {
        RemoteImagePolicy.allows(
            policy: remoteImagePolicy,
            senderEmail: MessageParser.emailAddress(message.fromHeader),
            vipEmails: store.vipEmails,
            messageOptIn: loadRemoteImages,
            threadOptIn: loadImagesForThread,
            senderAuthenticated: message.senderAuth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                // Notion Mail-style header: sender name + address, with a
                // compact "To me ⌄" summary that expands into full FROM/TO/CC
                // rows. Every participant is clickable (draft/search/copy).
                // Claim remaining width so long From names/emails can use the
                // space left of the action cluster instead of middle-truncating
                // into "Ale…sque abda…y.edu" while Spacer steals the free room.
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
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                }
                // Sole infinite-flex child of the header HStack so leftover
                // width goes entirely to the From/To column. A trailing
                // Spacer would split free space 50/50 and reintroduce the
                // "truncated name + blank gap" symptom at half magnitude.
                .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(message.date, format: message.date.messageHeaderFormat)
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
                } else if let html = (cidInlinedHTML ?? message.bodyHTML), !html.isEmpty {
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
                        // CID-inlined bodies skip preassembled docs (those still
                        // carry unresolved `cid:` + blocked/allowed CSP variants
                        // built from the DB HTML).
                        let preassembled: String? = {
                            guard cidInlinedHTML == nil,
                                  let docs = htmlDocuments,
                                  abs(docs.fontScale - fontScale) < 0.001
                            else { return nil }
                            return docs.document(
                                authored: useAuthoredHTML,
                                allowRemoteImages: allowRemoteImages)
                        }()
                        let bodyContentID = message.id
                            + (useAuthoredHTML ? ":authored" : ":full")
                            + (cidInlinedHTML != nil ? ":cid" : "")
                        HTMLBodyView(
                            contentID: bodyContentID,
                            html: renderedHTML,
                            preassembledDocument: preassembled,
                            allowRemoteImages: allowRemoteImages,
                            fontScale: fontScale,
                            height: $htmlHeight,
                            onSettled: onBodySettled)
                            .frame(height: htmlHeight)
                            .onAppear {
                                if let cached = HTMLBodyHeightCacheStore.height(
                                    contentID: bodyContentID,
                                    fontScale: fontScale,
                                    width: nil) {
                                    htmlHeight = cached
                                }
                            }
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
                // Calendar invites get a Gmail/Notion-style Accept card; the
                // .ics itself is hidden from the generic attachment chips so
                // it isn't double-presented as a dumb file. uniqueCalendar…
                // collapses Google's text/calendar + application/ics pair
                // (and already-synced duplicate rows) to one card.
                let calendarAtts = CalendarInvite.uniqueCalendarAttachments(attachments)
                let fileAtts = attachments.filter {
                    !CalendarInvite.isCalendarAttachment(
                        mimeType: $0.mimeType, filename: $0.filename)
                }
                if !calendarAtts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(calendarAtts) { att in
                            CalendarInviteCard(message: message, attachment: att,
                                               fontScale: fontScale)
                        }
                    }
                }
                if !fileAtts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if fileAtts.count > 1 {
                                Button {
                                    store.saveAllAttachments(fileAtts, message: message)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.down.to.line")
                                        Text("Download all (\(fileAtts.count))")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(Color.notionAccent.opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .help("Save every attachment to a folder you choose")
                            }
                            ForEach(fileAtts) { att in
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
            // Parent seeds the open set on payload apply. Cards that land
            // already expanded (or the single last-card default before seed)
            // still need body hydration.
            if isLast, expandedMessageIds.isEmpty {
                expandedMessageIds = expandPolicy.applyingExpand(
                    id: message.id, currently: expandedMessageIds)
                onNeedBody()
            } else if expanded {
                onNeedBody()
            }
            if message.listUnsubscribe == nil {
                onNeedUnsubscribeHeaders()
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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    participantMenu(
                        message.fromHeader,
                        nameSize: 14,
                        nameWeight: .semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    unsubscribeButton
                }
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
                            .truncationMode(.tail)
                            .layoutPriority(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8 * fontScale,
                                          weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12, height: 12,
                                   alignment: .center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("To \(recipientSummary)")
                .accessibilityHint("Show all senders and recipients")
                .help("Show all senders and recipients")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var unsubscribeButton: some View {
        if ListUnsubscribe.offer(from: message) != nil {
            Button("Unsubscribe", action: onUnsubscribe)
                .buttonStyle(.plain)
                .font(.system(size: 12 * fontScale))
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Unsubscribe from this mailing list")
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    participantMenu(address)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if role == "FROM", index == 0 { unsubscribeButton }
                }
            }
        }
    }

    /// A clickable participant: name + address, opening a Notion Mail-style
    /// menu (draft to them, search their mail, copy, VIP, split, block).
    @ViewBuilder
    private func participantMenu(_ raw: String, nameSize: CGFloat = 12.5,
                                 nameWeight: Font.Weight = .regular) -> some View {
        let email = MessageParser.emailAddress(raw)
        let name = MessageParser.displayName(fromHeader: raw)
        let showEmail = name.lowercased() != email.lowercased()
        // Canonical "is this me" set (accounts ∪ send-as aliases) — same as
        // reply-all / participant labeling elsewhere in this file.
        let ownEmails = store.ownEmailAddresses
        let vipAction = ParticipantMenuVIP.action(
            email: email,
            vipEmails: store.vipEmails,
            ownEmails: ownEmails)
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
            if showEmail {
                Button("Copy \"\(name)\"") { copyToPasteboard(name) }
            }
            // VIP / split / block only make sense for other people's addresses.
            // VIP sits between copy and split so promoting a sender is one
            // click from the same menu that opens when you click their name.
            if let vipAction {
                Divider()
                Button {
                    switch vipAction {
                    case .add(let e): store.addVIP(e)
                    case .remove(let e): store.removeVIP(e)
                    }
                } label: {
                    Label(ParticipantMenuVIP.title(for: vipAction),
                          systemImage: ParticipantMenuVIP.systemImage(for: vipAction))
                }
            }
            if !ownEmails.contains(email.lowercased()) {
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
            // Label hugs its text so whitespace to the right still falls
            // through to the header's collapse onTapGesture. The Menu's
            // outer maxWidth frame (below) expands layout proposal only.
            participantLabel(name: name, email: email, showEmail: showEmail,
                             nameSize: nameSize, nameWeight: nameWeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(email)
    }

    /// Progressive disclosure for the participant chip: full name+email when
    /// it fits, else a tail-truncated name (email stays in `.help` / menu).
    /// Avoids dual middle-truncation that produced unreadable fragments
    /// like "Ale…sque abda…y.edu".
    @ViewBuilder
    private func participantLabel(name: String, email: String, showEmail: Bool,
                                  nameSize: CGFloat, nameWeight: Font.Weight) -> some View {
        let nameFont = Font.system(size: nameSize * fontScale, weight: nameWeight)
        let emailFont = Font.system(size: (nameSize - 1.5) * fontScale)
        if showEmail {
            // Two alternatives only: a non-fixedSize name with .tail already
            // "fits" any proposal by truncating, so a middle name-only tier
            // would never be selected.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(nameFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(email)
                        .font(emailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(name)
                    .font(nameFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text(name)
                .font(nameFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
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
        if mime.hasPrefix("text/calendar") || mime.contains("application/ics") {
            return "calendar"
        }
        return "doc"
    }
}

// MARK: - Matching Gmail filters (per message)

/// Collapsible disclosure under an expanded message listing the account's
/// Gmail filters whose criteria match this message. Loads filters lazily
/// via `MailStore.ensureFiltersLoaded`; hidden when none match or filters
/// aren't readable yet (scope / empty account).
private struct MatchingFiltersSection: View {
    @Environment(MailStore.self) var store
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
/// Web views are drawn from `HTMLWebViewPool` (recycle + shared ephemeral
/// store + optional pre-rendered neighbors) so expanding/collapsing cards and
/// up/down thread browses do not thrash WKWebView creation.
///
/// Content swaps keep the outgoing painted view visible until the incoming
/// view has painted (or is a pre-rendered claim). Settled heights are cached
/// per `contentID` so re-open does not reflow after paint. Transitions are a
/// short opacity fade (≤0.1s) or none — never a slide.
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
    /// Pre-assembled document from `ThreadDetailRepository` (CSP + CSS already
    /// injected). When present, main-thread render skips `HTMLBodyDocument.assemble`.
    var preassembledDocument: String? = nil
    let allowRemoteImages: Bool
    var fontScale: Double = 1.0
    @Binding var height: CGFloat
    /// Fired once the first stable height for the current document is known
    /// (ResizeObserver settle). Used to arm neighbor pre-renders.
    var onSettled: (() -> Void)? = nil

    /// Cross-fade when swapping painted WebViews. Project style: fade only,
    /// never a slide; keep well under 100ms.
    private static let swapFadeDuration: TimeInterval = 0.08

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        context.coordinator.container = container
        context.coordinator.contentID = contentID
        context.coordinator.onSettled = onSettled

        let heightBinding = _height
        context.coordinator.setHeight = { heightBinding.wrappedValue = $0 }
        // Cached height keeps the card frame stable before the first paint.
        // Applied async (SwiftUI forbids state writes mid-update) and only if
        // no real measurement landed first — a fast paint must not be
        // overwritten by a stale placeholder.
        if let cached = HTMLBodyHeightCacheStore.height(
            contentID: contentID, fontScale: fontScale, width: nil) {
            let expectedContentID = contentID
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard let coordinator,
                      coordinator.contentID == expectedContentID,
                      coordinator.heightUpdateCount == 0 else { return }
                heightBinding.wrappedValue = cached
            }
        }

        let key = HTMLBodyLoadKey(
            contentID: contentID,
            allowRemoteImages: allowRemoteImages,
            fontScale: fontScale)
        context.coordinator.loadedKey = key

        if let ready = HTMLWebViewPool.claimPrerendered(for: key) {
            context.coordinator.attach(
                ready, in: container, alreadyPainted: true, fade: false)
            context.coordinator.beginRender(
                byteCount: html.utf8.count,
                variant: contentID.hasSuffix(":authored") ? "authored" : "full",
                prerenderHit: true)
            context.coordinator.acceptsHeightReports = true
            context.coordinator.installLayoutAndMeasure(ready)
        } else {
            let webView = HTMLWebViewPool.dequeue()
            context.coordinator.attach(
                webView, in: container, alreadyPainted: false, fade: false)
            context.coordinator.beginRender(
                byteCount: html.utf8.count,
                variant: contentID.hasSuffix(":authored") ? "authored" : "full",
                prerenderHit: false)
            context.coordinator.loadDocument(
                html: html, preassembled: preassembledDocument,
                allowRemoteImages: allowRemoteImages,
                fontScale: fontScale, in: webView)
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.container = container
        context.coordinator.contentID = contentID
        context.coordinator.onSettled = onSettled
        // Refresh the binding callback even when the document identity did not
        // change. Capture the Binding only — capturing `self` retains `html`.
        let heightBinding = _height
        context.coordinator.setHeight = { heightBinding.wrappedValue = $0 }

        let key = HTMLBodyLoadKey(
            contentID: contentID,
            allowRemoteImages: allowRemoteImages,
            fontScale: fontScale)
        guard context.coordinator.loadedKey != key else { return }

        // Applied async like makeNSView's placeholder: updateNSView runs
        // inside SwiftUI's update pass, where a synchronous binding write is
        // undefined behavior. Guarded so a measurement that lands first wins.
        let layoutWidth = container.bounds.width
        if let cached = HTMLBodyHeightCacheStore.height(
            contentID: contentID, fontScale: fontScale,
            width: layoutWidth > 0 ? layoutWidth : nil) {
            let expectedContentID = contentID
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard let coordinator,
                      coordinator.contentID == expectedContentID,
                      coordinator.heightUpdateCount == 0 else { return }
                heightBinding.wrappedValue = cached
            }
        }

        context.coordinator.loadedKey = key
        context.coordinator.beginRender(
            byteCount: html.utf8.count,
            variant: contentID.hasSuffix(":authored") ? "authored" : "full",
            prerenderHit: false)

        if let ready = HTMLWebViewPool.claimPrerendered(for: key) {
            context.coordinator.swap(
                to: ready, alreadyPainted: true, html: html,
                preassembled: preassembledDocument,
                allowRemoteImages: allowRemoteImages, fontScale: fontScale)
        } else {
            let incoming = HTMLWebViewPool.dequeue()
            context.coordinator.swap(
                to: incoming, alreadyPainted: false, html: html,
                preassembled: preassembledDocument,
                allowRemoteImages: allowRemoteImages, fontScale: fontScale)
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedKey: HTMLBodyLoadKey?
        var setHeight: ((CGFloat) -> Void)?
        var onSettled: (() -> Void)?
        var contentID: String = ""
        weak var container: NSView?
        private(set) var current: PassthroughWebView?
        private var incoming: PassthroughWebView?
        private var loadToken = UUID()
        private var heightStability = HTMLHeightStability()
        /// Read by the makeNSView cached-height fallback: a stale cached
        /// placeholder must never overwrite a real measurement.
        private(set) var heightUpdateCount = 0
        private var renderInterval: PerfMetrics.Interval?
        private var renderTimeout: DispatchWorkItem?
        var acceptsHeightReports = false
        private var navigationGate = HTMLNavigationIdentityGate()
        private var pendingReveal = false
        private var settledNotified = false
        /// Bumped on every swap/dismantle so an in-flight fade completion
        /// from a superseded swap cannot recycle views or promote `current`.
        private var swapGeneration = 0

        func attach(_ webView: PassthroughWebView, in container: NSView,
                    alreadyPainted: Bool, fade: Bool) {
            webView.navigationDelegate = self
            webView.installHeightHandler(self)
            webView.setValue(false, forKey: "drawsBackground")
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            // Stolen pre-renders still paint foreign DOM until their own load
            // commits — never show them at alpha 1. Free-list / new views are
            // blank and may appear immediately (no slower path regression).
            let hideUntilOwnPaint = !alreadyPainted
                && (webView.hasForeignContent || (fade && current != nil))
            webView.alphaValue = hideUntilOwnPaint ? 0 : 1
            webView.hasForeignContent = false
            container.addSubview(webView)
            current = webView
            pendingReveal = !alreadyPainted
        }

        /// Keep outgoing content visible until `next` is painted (or already is).
        /// Stop height reporting and return a view to the pool. Always runs
        /// teardown so freeze globals / ResizeObserver cannot linger on a
        /// recycled view (Fable #8 — was previously only on `current` dismantle).
        private func recycle(_ webView: PassthroughWebView,
                             removeFromHierarchy: Bool = false) {
            webView.navigationDelegate = nil
            webView.evaluateJavaScript(
                HTMLBodyLayout.teardownJS, completionHandler: nil)
            webView.removeHeightHandlerIfNeeded()
            if removeFromHierarchy {
                webView.removeFromSuperview()
            }
            HTMLWebViewPool.recycle(webView)
        }

        func swap(to next: PassthroughWebView, alreadyPainted: Bool,
                  html: String, preassembled: String? = nil,
                  allowRemoteImages: Bool, fontScale: Double) {
            swapGeneration &+= 1
            guard let container else {
                recycle(next)
                return
            }
            // Abandon any in-flight incoming load.
            if let abandoned = incoming, abandoned !== current {
                recycle(abandoned)
            }
            incoming = next
            next.navigationDelegate = self
            next.installHeightHandler(self)
            next.setValue(false, forKey: "drawsBackground")
            next.frame = container.bounds
            next.autoresizingMask = [.width, .height]
            // Stay invisible until first paint so the outgoing body never blanks.
            // Also covers stolen pre-renders still holding foreign DOM.
            next.alphaValue = 0
            next.hasForeignContent = false
            container.addSubview(next, positioned: .above, relativeTo: current)
            pendingReveal = true
            settledNotified = false

            if alreadyPainted {
                acceptsHeightReports = true
                installLayoutAndMeasure(next)
                revealIncoming(animated: true)
            } else {
                loadDocument(
                    html: html, preassembled: preassembled,
                    allowRemoteImages: allowRemoteImages,
                    fontScale: fontScale, in: next)
            }
        }

        func beginRender(byteCount: Int, variant: String, prerenderHit: Bool) {
            finishRender(reason: "superseded")
            acceptsHeightReports = false
            navigationGate.reset()
            heightStability.reset()
            heightUpdateCount = 0
            settledNotified = false
            renderInterval = PerfMetrics.begin(
                .openHTML,
                meta: "bytes=\(byteCount) variant=\(variant) prerender=\(prerenderHit ? 1 : 0)")

            // ResizeObserver normally produces a confirming height quickly.
            // End diagnostics even for malformed documents that never settle.
            // Views stay hidden until their first height report (pooled views
            // may hold a stale DOM until the blank load commits), so also
            // reveal here: a document that never reports must not stay
            // invisible past the timeout.
            let timeout = DispatchWorkItem { [weak self] in
                self?.revealIncoming(animated: false)
                self?.finishRender(reason: "timeout")
            }
            renderTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        }

        func loadDocument(html: String, preassembled: String? = nil,
                          allowRemoteImages: Bool,
                          fontScale: Double, in webView: WKWebView) {
            let csp = HTMLBodyCSP.metaTag(allowRemoteImages: allowRemoteImages)
            let css = HTMLBodyDarkMode.injectedCSS(fontScale: fontScale)
            // Prefer the off-main preassembled document; fall back to
            // main-thread assembly only when prep is missing (font-scale
            // mismatch, oversized after explicit approve, or legacy paths
            // without a repository prep).
            let document = preassembled ?? HTMLBodyDocument.assemble(
                html: html, cspMeta: csp, styleCSS: css)
            load(
                document: document,
                trustedFallback: {
                    HTMLBodyDocument.trustedWrapper(
                        html: html, cspMeta: csp, styleCSS: css)
                },
                allowRemoteImages: allowRemoteImages,
                in: webView)
        }

        /// Apply/remove the network-level remote-image rule before navigating.
        /// A generation token prevents a late compile callback from mutating a
        /// recycled view or superseding a newer Load-images request.
        ///
        /// The rule list is compiled once at app launch (`prepareAtLaunch`);
        /// the common path installs the cached list synchronously so message
        /// opens never wait on WebKit compilation.
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

            if let ready = HTMLRemoteImageBlocker.preparedRuleList {
                controller.add(ready)
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

        /// Drop height callbacks and recycle live views when the representable
        /// leaves the hierarchy.
        func dismantle() {
            swapGeneration &+= 1
            loadToken = UUID()
            loadedKey = nil
            setHeight = nil
            onSettled = nil
            acceptsHeightReports = false
            navigationGate.reset()
            finishRender(reason: "detached")
            heightStability.reset()
            pendingReveal = false

            if let incoming, incoming !== current {
                recycle(incoming)
            }
            incoming = nil
            if let current {
                recycle(current)
            }
            self.current = nil
            container = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigationGate.accepts(navigation) else { return }
            // Only the active incoming (or sole current) navigation counts.
            guard webView === incoming || (incoming == nil && webView === current)
            else { return }
            // Primary contrast pass runs as WKUserScript at document-end
            // (WebViewPool) for every navigation, including recycled views.
            acceptsHeightReports = true
            installLayoutAndMeasure(webView)
        }

        func installLayoutAndMeasure(_ webView: WKWebView) {
            webView.evaluateJavaScript(HTMLBodyLayout.installLayoutAndMeasureJS) { [weak self] result, _ in
                self?.applyMeasuredHeight(result, from: webView)
            }
        }

        private func applyMeasuredHeight(_ result: Any?, from webView: WKWebView? = nil) {
            guard acceptsHeightReports else { return }
            // During a double-buffered swap the coordinator's contentID is
            // already the incoming document's, so only the incoming view may
            // publish or cache heights — the outgoing view's ResizeObserver
            // would poison the new card's frame and height cache.
            if incoming != nil, webView !== incoming { return }
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

            // Floor + hard ceiling (mirrors JS). Pathological markup or a
            // residual measure↔frame feedback loop must not grow the card
            // without bound (infinite scroll in the reading pane).
            let height = HTMLBodyLayout.clampContentHeight(rawHeight)
            let wasLatched = heightStability.latchedHeight != nil
            let observation = heightStability.observe(height)
            if observation.shouldPublish {
                heightUpdateCount += 1
                let published = observation.height
                let measuredView = webView ?? incoming ?? current
                let measuredWidth = measuredView?.frame.width ?? 0
                if !contentID.isEmpty, let key = loadedKey, measuredWidth > 0 {
                    HTMLBodyHeightCacheStore.store(
                        published, contentID: contentID,
                        fontScale: key.fontScale, width: measuredWidth)
                }
                DispatchQueue.main.async { [weak self] in self?.setHeight?(published) }
            }
            if pendingReveal, webView === incoming || (incoming == nil && webView === current) {
                // First positive height is enough to reveal; stability can follow.
                revealIncoming(animated: current != nil && incoming != nil)
            }
            if observation.isStable {
                let latchedNow = heightStability.latchedHeight != nil
                finishRender(reason: !wasLatched && latchedNow
                             ? "oscillation-latched" : "stable")
                notifySettledIfNeeded()
            }
        }

        private func revealIncoming(animated: Bool) {
            guard pendingReveal else { return }
            guard let container else { return }
            let next = incoming ?? current
            guard let next else { return }
            pendingReveal = false

            let previous = (next === incoming) ? current : nil
            if next.superview == nil {
                next.frame = container.bounds
                next.autoresizingMask = [.width, .height]
                container.addSubview(next, positioned: .above, relativeTo: previous)
            }

            let gen = swapGeneration
            let finishSwap = { [weak self] in
                guard let self, self.swapGeneration == gen else { return }
                if let previous, previous !== next {
                    self.recycle(previous, removeFromHierarchy: true)
                }
                next.alphaValue = 1
                self.current = next
                if self.incoming === next {
                    self.incoming = nil
                }
            }

            if animated, previous != nil {
                next.alphaValue = 0
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = HTMLBodyView.swapFadeDuration
                    ctx.allowsImplicitAnimation = true
                    next.animator().alphaValue = 1
                }, completionHandler: finishSwap)
            } else {
                next.alphaValue = 1
                finishSwap()
            }
        }

        private func notifySettledIfNeeded() {
            guard !settledNotified else { return }
            settledNotified = true
            let callback = onSettled
            DispatchQueue.main.async { callback?() }
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
            guard webView === incoming || (incoming == nil && webView === current) else { return }
            acceptsHeightReports = false
            // Don't leave a blank new view on top of good content.
            if let incoming, incoming === webView, current != nil {
                recycle(incoming, removeFromHierarchy: true)
                self.incoming = nil
                pendingReveal = false
            }
            finishRender(reason: "navigationError")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard navigationGate.accepts(navigation) else { return }
            guard webView === incoming || (incoming == nil && webView === current) else { return }
            acceptsHeightReports = false
            if let incoming, incoming === webView, current != nil {
                recycle(incoming, removeFromHierarchy: true)
                self.incoming = nil
                pendingReveal = false
            }
            finishRender(reason: "provisionalError")
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == HTMLBodyLayout.heightHandlerName else { return }
            let webView = message.webView
            applyMeasuredHeight(message.body, from: webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url

            // A user clicking a link is handed to the OS (real browser / mail
            // client); we never navigate the message pane itself. A crafted
            // file:// or app-scheme link stays inert. Schemeless hrefs that
            // WebKit resolved against about:blank (baseURL is nil) are
            // recovered to https:// when they look like a real host — see
            // ExternalLinkRecovery.
            if navigationAction.navigationType == .linkActivated {
                if let external = ExternalLinkRecovery.recoveredExternalURL(from: url) {
                    NSWorkspace.shared.open(external)
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
