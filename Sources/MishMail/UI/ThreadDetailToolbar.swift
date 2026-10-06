import SwiftUI

/// What the reading pane's toolbar needs from the mounted conversation.
///
/// The toolbar lives *outside* `.id(thread.id)` (see `ThreadDetailToolbar`),
/// so it cannot read `ThreadDetailView`'s `@State` directly. The mounted pane
/// publishes its messages here and installs the actions that touch its own
/// state (alerts, Markdown export).
@Observable
final class ThreadToolbarModel {
    struct Actions {
        var copyMarkdown: () -> Void
        var saveMarkdown: () -> Void
        var unsubscribe: (Message) -> Void
        var confirmBlock: (String, MailThread) -> Void
    }

    private(set) var threadId: String?
    private(set) var messages: [Message] = []
    /// Read only from button actions, never while rendering.
    @ObservationIgnored private(set) var actions: Actions?
    @ObservationIgnored private var actionsThreadId: String?

    func publish(threadId: String, messages: [Message]) {
        if self.threadId != threadId { self.threadId = threadId }
        if self.messages != messages { self.messages = messages }
    }

    func install(_ actions: Actions, threadId: String) {
        self.actions = actions
        actionsThreadId = threadId
    }

    /// The outgoing pane's `onDisappear` can run after the incoming pane's
    /// `onAppear`, so only the current owner may clear.
    func uninstall(threadId: String) {
        guard actionsThreadId == threadId else { return }
        actions = nil
        actionsThreadId = nil
    }
}

/// Reading-pane title and toolbar, applied by the pane's host *outside*
/// `.id(thread.id)`.
///
/// `ThreadDetailView` is remounted for every conversation. When the toolbar
/// was declared inside it, each open tore down and re-created every
/// `NSToolbarItem` — measured at over half of the main-thread work of opening
/// a thread. Declared here the items keep their identity and only their
/// content updates.
struct ThreadDetailToolbar: ViewModifier {
    @Environment(MailStore.self) private var store
    @AppStorage("readingPaneHidden") private var readingPaneHidden = false
    let thread: MailThread
    let compactMode: Bool
    var focusMode: Bool = false
    var splitMode: Bool = false
    let model: ThreadToolbarModel
    /// Covers the frames before the remounted pane publishes: the host
    /// already holds the warm payload the pane seeds itself from.
    var initialMessages: [Message]? = nil
    let onBack: () -> Void
    let onReply: (Message) -> Void

    /// This conversation's messages, or nil until the remounted pane (or the
    /// host's warm payload) supplies them.
    private var loadedMessages: [Message]? {
        if model.threadId == thread.id { return model.messages }
        return initialMessages
    }

    private var messages: [Message] { loadedMessages ?? [] }

    /// Decides only *which* buttons exist. During the frames before a cold
    /// conversation loads, the previous conversation's shape stands in, so
    /// Reply / Reply all / Forward are not removed and re-inserted on every
    /// open. Those buttons stay disabled until the real messages arrive, so
    /// a stand-in message is never acted on.
    private var layoutMessages: [Message] { loadedMessages ?? model.messages }

    func body(content: Content) -> some View {
        content
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
                    if let layoutLast = ForwardComposer.newestSentMessage(in: layoutMessages) {
                        let loaded = loadedMessages != nil
                        let last = ForwardComposer.newestSentMessage(in: messages) ?? layoutLast
                        Button { onReply(last) } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left")
                        }
                        .help("Reply (\(store.keyBindings.key(for: .reply)))")
                        .disabled(!loaded)
                        Button { store.handleSelectedThreadWithMish() } label: {
                            Label("Handle with Mish", systemImage: "wand.and.sparkles")
                        }
                        .help("Handle with Mish · the agent works this conversation and stops before anything is sent")
                        if ReplyComposer.hasAdditionalReplyAllRecipients(
                            last, ownAddresses: store.ownEmailAddresses) {
                            Button {
                                store.openCompose(.init(replyTo: last, replyAll: true))
                            } label: {
                                Label("Reply all", systemImage: "arrowshape.turn.up.left.2")
                            }
                            .help("Reply all (\(store.keyBindings.key(for: .replyAll)))")
                            .disabled(!loaded)
                        }
                        Button {
                            store.openCompose(.init(replyTo: last, forward: true))
                        } label: {
                            Label("Forward", systemImage: "arrowshape.turn.up.right")
                        }
                        .help("Forward newest message (\(store.keyBindings.key(for: .forward))) · starts a new conversation")
                        .disabled(!loaded)
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
                            model.actions?.copyMarkdown()
                        } label: {
                            Label("Copy as Markdown", systemImage: "doc.on.clipboard")
                        }
                        Button {
                            model.actions?.saveMarkdown()
                        } label: {
                            Label("Save as Markdown…", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            store.copyThreadLink(thread)
                        } label: {
                            Label("Copy Gmail link", systemImage: "link")
                        }
                        .help("Copy Gmail link (⌘L)")
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
                                    model.actions?.confirmBlock(blockEmail, thread)
                                } label: {
                                    Label("Block sender",
                                          systemImage: "person.crop.circle.badge.xmark")
                                }
                            }
                        }
                        if let msg = ListUnsubscribe.preferredMessage(in: messages) {
                            Button {
                                model.actions?.unsubscribe(msg)
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
    }
}
