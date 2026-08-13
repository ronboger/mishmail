import SwiftUI
import UniformTypeIdentifiers

/// Global frame of the reading-pane column — used to pin inline compose.
private struct ReadingPaneFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 1 { value = next }
    }
}

/// Global frame of the compose overlay host (window content).
private struct ComposeHostFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 1 { value = next }
    }
}

struct ContentView: View {
    @Environment(MailStore.self) var store
    /// `@Environment` has no projected value, so sheets and controls that need
    /// two-way access to the store go through this instead of `$store`.
    private var bound: Bindable<MailStore> { Bindable(store) }
    /// List highlight — separate ObservableObject so ↓ / j does not publish
    /// through MailStore (and re-render detail / sidebar). ContentView must
    /// observe it: the open-policy onChange and toolbar state depend on it.
    @EnvironmentObject var listFocus: ListFocusState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keyMonitor: Any?
    @State private var layoutMode: MailLayoutMode = .list
    // Persisted so the layout survives relaunch, like the sidebar state.
    @AppStorage("readingPaneHidden") private var readingPaneHidden = false
    // Superhuman-style (default): opening a conversation fills the window.
    // Settings → Appearance can switch back to the reading-pane layout.
    @AppStorage(ThreadOpenStyle.storageKey) private var threadOpenStyleRaw =
        ThreadOpenStyle.fullWindow.rawValue
    // Sidebar starts collapsed; ← hides it, → brings it back (persisted).
    @AppStorage("sidebarHidden") private var sidebarHidden = true
    /// Measured frames for PreferenceKey-aligned inline compose.
    @State private var readingPaneFrame: CGRect = .zero
    @State private var composeHostFrame: CGRect = .zero
    @State private var detailSelectionTask: Task<Void, Never>?
    /// Last browse keyDown's auto-repeat flag — single presses open at 0 ms;
    /// held-key repeats coalesce via `DetailOpenPolicy.keyRepeatSettleNanoseconds`.
    @State private var browseKeyIsRepeat = false

    private var fullWindowThreads: Bool {
        ThreadOpenStyle(rawValue: threadOpenStyleRaw) != .readingPane
    }

    /// What "the reading pane is hidden" means for compose placement and
    /// inline-compose promotion. In full-window style the pane is the focus
    /// view itself: visible while a conversation is open, hidden on the list.
    private var effectivePaneHidden: Bool {
        fullWindowThreads ? !store.threadFocusMode : readingPaneHidden
    }

    /// Sidebar collapse driven by ←/→ (and the native toolbar toggle).
    /// `hidden` is the split view's "sidebar collapsed" value for the
    /// current column count (.detailOnly for 2, .doubleColumn for 3).
    private func splitVisibility(whenHidden hidden: NavigationSplitViewVisibility)
        -> Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarHidden ? hidden : .all },
            set: { sidebarHidden = ($0 != .all) }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            // Compact mode swaps list ↔ detail on whether a conversation is
            // actually OPEN — the quiet auto-highlight of the top row is a
            // selection without an open, and must keep showing the list.
            let mode = MailLayout.mode(
                width: proxy.size.width,
                readingPaneHidden: readingPaneHidden,
                hasSelection: store.openedThreadId != nil,
                threadFocus: store.threadFocusMode,
                fullWindowThreads: fullWindowThreads)
            Group {
                if splitComposeActive {
                    splitComposeLayout(hostWidth: proxy.size.width)
                } else {
                    mailboxLayout(mode)
                }
            }
            .onAppear { layoutMode = mode }
            .onChange(of: mode) { layoutMode = mode }
            .background(
                GeometryReader { host in
                    Color.clear.preference(
                        key: ComposeHostFrameKey.self,
                        value: host.frame(in: .global))
                }
            )
        }
        .onPreferenceChange(ReadingPaneFrameKey.self) { frame in
            readingPaneFrame = frame
            // Pathological short panes: float compose instead of a 0-height dock.
            store.demoteInlineComposeIfPaneTooShort(paneHeight: frame.height)
        }
        // One app-level Reduce Motion gate covers legacy and new transitions.
        // Triage/navigation already use no animation even when motion is on.
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .onPreferenceChange(ComposeHostFrameKey.self) { composeHostFrame = $0 }
        // Search lives in the sidebar (Notion Mail-style), not the toolbar.
        // Typing only feeds the dropdown preview; the list follows
        // committedSearch. Clearing the field also clears an active search.
        .onChange(of: store.searchText) {
            if store.searchText.isEmpty, !store.committedSearch.isEmpty {
                store.committedSearch = ""
                store.reloadThreads()
            }
        }
        // A clicked (not keyboard-browsed) selection reopens the reading pane.
        // Clicking a pure draft skips the pane entirely and hops straight
        // into compose at the bottom (Notion Mail-style).
        // Observe listFocus (not MailStore) — selection changes publish only
        // through ListFocusState, so this is the trigger that consumes the
        // one-shot selection intent.
        .onChange(of: listFocus.id) {
            let intent = store.consumeSelectionIntent()
            // Leaving a thread (or clearing selection) promotes inline compose
            // to the floating card so the draft stays editable.
            store.promoteInlineComposeIfNeeded(
                selectedThreadId: store.selectedThreadId,
                readingPaneHidden: effectivePaneHidden)
            // Focus mode requires a conversation; drop it when selection clears.
            if store.selectedThreadId == nil {
                store.threadFocusMode = false
                detailSelectionTask?.cancel()
            }
            guard let selectedId = store.selectedThreadId else { return }
            // Auto-highlight of the top row (Superhuman default): selection
            // only — never opens the conversation.
            if intent == .quiet { return }
            if intent == .browse {
                // Hidden-pane browsing is highlight-only. Any visible preview,
                // including the first keyboard selection in compact mode,
                // coalesces repeats and opens the final row.
                if !effectivePaneHidden {
                    if DetailOpenPolicy.opensImmediately(
                        openedThreadId: store.openedThreadId,
                        listedIds: store.threads.lazy.map(\.id)) {
                        // Auto-advance after trash/archive: the opened row is
                        // gone, so debouncing would blank and rebuild the pane.
                        detailSelectionTask?.cancel()
                        store.openDetail(selectedId)
                    } else {
                        scheduleDetailSelection(selectedId)
                    }
                }
            } else {
                openClickedThread(selectedId, intent: intent)
            }
        }
        // A click on the row that is already selected (e.g. the pre-highlighted
        // top row) produces no selection change — open it via this token.
        .onChange(of: store.openSelectedToken) {
            guard let selectedId = store.selectedThreadId else { return }
            openClickedThread(selectedId)
        }
        .onChange(of: readingPaneHidden) {
            // Full-window style ignores the reading-pane flag entirely; the
            // focus-mode onChange below owns compose placement there.
            guard !fullWindowThreads else { return }
            store.readingPaneHiddenForCompose = readingPaneHidden
            store.promoteInlineComposeIfNeeded(
                selectedThreadId: store.selectedThreadId,
                readingPaneHidden: readingPaneHidden)
            if readingPaneHidden { store.threadFocusMode = false }
            else if let selected = store.selectedThreadId {
                detailSelectionTask?.cancel()
                store.openDetail(selected)
            }
        }
        .onChange(of: store.threadFocusMode) {
            guard fullWindowThreads else { return }
            store.readingPaneHiddenForCompose = !store.threadFocusMode
            // Going back to the list with an inline reply open keeps the
            // draft as a floating card instead of tearing it down.
            store.promoteInlineComposeIfNeeded(
                selectedThreadId: store.selectedThreadId,
                readingPaneHidden: !store.threadFocusMode)
            if store.threadFocusMode, let selected = store.selectedThreadId {
                detailSelectionTask?.cancel()
                store.openDetail(selected)
            }
        }
        .onChange(of: store.selectedView) {
            store.clearSelection()
            store.clearCheckedThreads()
            store.resetChips()
            // Sidebar click (or any selectedView write) should land on the
            // real mailbox, not keep a committed `/` search overlay. goTo
            // clears search first; this covers the List selection binding.
            if !store.searchText.isEmpty || !store.committedSearch.isEmpty {
                store.searchText = ""
                store.committedSearch = ""
            }
            store.reloadThreads()
        }
        .onChange(of: store.chips) { store.reloadThreadsDebounced() }
        .onAppear {
            store.readingPaneHiddenForCompose = effectivePaneHidden
            store.openDetail(store.selectedThreadId)
            installKeyMonitor()
            // Don't let the sidebar search field start with keyboard focus —
            // it would swallow Esc/j/k until clicked away.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            detailSelectionTask?.cancel()
            detailSelectionTask = nil
        }
        // Refocusing the app lands with the top row selected (Superhuman-
        // style) when nothing else is — ↩ opens it without touching arrows.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            store.autoSelectTopThread()
        }
        .toolbar {
            ToolbarItemGroup {
                // Full-window style has no reading pane to toggle.
                if !fullWindowThreads {
                    Button {
                        readingPaneHidden.toggle()
                    } label: {
                        Label(readingPaneHidden ? "Show Reading Pane" : "Hide Reading Pane",
                              systemImage: "sidebar.trailing")
                    }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .help(readingPaneHidden ? "Show the reading pane (⌥⌘0)"
                                            : "Hide the reading pane (⌥⌘0)")
                }
                Button {
                    guard store.selectedThreadId != nil else { return }
                    store.threadFocusMode.toggle()
                    if store.threadFocusMode, !fullWindowThreads {
                        readingPaneHidden = false
                        store.readingPaneHiddenForCompose = false
                    }
                } label: {
                    Label(store.threadFocusMode ? "Exit Focus" : "Focus Conversation",
                          systemImage: store.threadFocusMode
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right")
                }
                .disabled(store.selectedThreadId == nil)
                .help(store.threadFocusMode
                      ? "Exit full-app conversation (esc or ⌘↩)"
                      : "Open conversation full-app (⌘↩)")
            }
        }
        // Single ComposeView host for both floating and inline so presentation
        // flips keep editor state. Floating = bottom-trailing card; inline =
        // bottom of the reading-pane column (leading inset skips sidebar/list).
        .overlay(alignment: .bottomTrailing) {
            Group {
                if let request = store.composeRequest {
                    composeChrome(request)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8),
                       value: store.composeRequest?.id)
            .animation(.spring(response: 0.28, dampingFraction: 0.85),
                       value: store.composeMinimized)
            .animation(.spring(response: 0.3, dampingFraction: 0.85),
                       value: store.composeRequest?.presentation)
        }
        .animation(.easeOut(duration: 0.2), value: store.threadFocusMode)
        .animation(.easeOut(duration: 0.1), value: splitComposeActive)
        // Undo + notice toasts: bottom-leading. Notice is non-interactive so it
        // never covers clickable controls (draft card Continue/Discard sit
        // bottom-center/trailing); undo stays hit-testable for the Undo button.
        // Stacked in one overlay so both can appear without overlapping.
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 10) {
                if let notice = store.notice {
                    Text(notice)
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 22).padding(.vertical, 13)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
                if let undo = store.undoAction {
                    HStack(spacing: 14) {
                        Text(undo.label)
                            .font(.system(size: 14, weight: .medium))
                        Button {
                            undo.undo()
                        } label: {
                            HStack(spacing: 6) {
                                Text("Undo")
                                // Rebindable single-key (default `z`); ⌘Z is also
                                // wired in the key monitor for the standard chord.
                                Text(store.keyBindings.key(for: .undo))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .opacity(0.75)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help("Undo (\(store.keyBindings.key(for: .undo)) or ⌘Z)")
                    }
                    .padding(.horizontal, 22).padding(.vertical, 13)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.leading, 20).padding(.bottom, 20)
        }
        // Presence only — not `undoAction?.id` — so rapid keyboard archive/
        // trash updates the label in place instead of re-sliding every time.
        .animation(PMMotion.feedback, value: UndoToast.isPresented(store.undoAction))
        .animation(PMMotion.feedback, value: store.notice)
        .sheet(item: bound.editingView) { view in
            ViewEditor(view: view)
        }
        .alert(
            "Delete this draft?",
            isPresented: Binding(
                get: { store.confirmingDraftDelete != nil },
                set: { if !$0 { store.confirmingDraftDelete = nil } }
            ),
            presenting: store.confirmingDraftDelete
        ) { draft in
            Button("Delete", role: .destructive) { store.deleteDraft(draft) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can't be undone.")
        }
        .sheet(isPresented: bound.showShortcutsHelp) {
            ShortcutsHelpView(bindings: store.keyBindings)
        }
        .sheet(isPresented: bound.showLabelOrganizer) {
            LabelOrganizer()
        }
        // Snooze is an overlay (not a .sheet): modal sheet presentation on
        // macOS costs ~200–300 ms of window chrome + animation, so the
        // presets felt laggy after `b`. LabelPicker / CommandPalette already
        // use this pattern for the same reason.
        .overlay {
            if store.showCommandPalette {
                CommandPalette()
            }
            if store.showLabelPicker {
                LabelPicker(picker: store.labelPicker)
            }
            if let thread = store.snoozingThread {
                SnoozeSheet(
                    current: thread.snoozeUntil,
                    snooze: { store.snooze(thread, until: $0) },
                    cancel: { store.dismissSnoozePicker() }
                )
                // Reset query/highlight if the target thread changes while open.
                .id(thread.id)
            }
        }
        // Wide command-K-style search panel, floated at the window level so it
        // spills over the message list (not confined to the sidebar column).
        .overlay(alignment: .topLeading) {
            if store.searchActive {
                SearchResultsPanel()
                    .frame(width: 600, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.top, 76)
                    // Snappy fade in place — no slide-in; this app is fast.
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.06), value: store.searchActive)
        // Non-modal error banner (a background sync hiccup shouldn't interrupt
        // you). Sits above the undo/notice toast; stays until dismissed.
        .overlay(alignment: .bottom) {
            if let error = store.lastError {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .frame(maxWidth: 360, alignment: .leading)
                    if store.lastErrorRecovery == .retrySync {
                        Button("Sync") {
                            store.lastError = nil
                            Task { await store.syncAll() }
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Button("Reauthorize") {
                            UserDefaults.standard.set(SettingsView.Pane.accounts.rawValue,
                                                      forKey: "settingsPane")
                            store.lastError = nil
                            openSettings()
                        }
                        .buttonStyle(.borderless)
                    }
                    Button {
                        store.lastError = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .pmHitTarget(extra: 8)
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PMRadius.md + 2))
                .overlay(RoundedRectangle(cornerRadius: PMRadius.md + 2).strokeBorder(.orange.opacity(0.4)))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                .padding(.bottom, 76)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.lastError)
        // First-run: guide the Google setup instead of dead-ending on an empty
        // inbox. Disappears the moment an account connects or demo starts.
        .overlay {
            if store.accounts.isEmpty {
                OnboardingView()
            }
        }
    }

    @ViewBuilder
    private func mailboxLayout(_ mode: MailLayoutMode) -> some View {
        switch mode {
        case .list:
            NavigationSplitView(columnVisibility: splitVisibility(whenHidden: .detailOnly)) {
                Sidebar()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
            } detail: {
                listColumn
            }
        case .compactDetail:
            NavigationSplitView(columnVisibility: splitVisibility(whenHidden: .detailOnly)) {
                Sidebar()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
            } detail: {
                detailPane(compact: true)
            }
        case .threePane:
            NavigationSplitView(columnVisibility: splitVisibility(whenHidden: .doubleColumn)) {
                Sidebar()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
            } content: {
                listColumn
                    .navigationSplitViewColumnWidth(min: 420, ideal: 560)
            } detail: {
                detailPane(compact: false)
            }
        case .threadFocus:
            // Full-app conversation: no sidebar / list chrome.
            detailPane(compact: false)
        }
    }

    /// Side-by-side compose is active: the layout swaps to the split canvas
    /// and the overlay card fills the right column. Minimizing pauses split
    /// (mailbox comes back); expanding restores it.
    private var splitComposeActive: Bool {
        store.composeRequest?.presentation == .split && !store.composeMinimized
    }

    /// Left column of split compose: the draft's source conversation,
    /// full-height. The right column is empty space the overlay-hosted
    /// ComposeView pins itself to (same view identity as floating/inline,
    /// so entering/leaving split keeps the typed body).
    ///
    /// `NavigationStack` hosts the detail toolbar (exit split, archive/star,
    /// reply, ⋯ More) — without it the column is a bare HStack child and
    /// principal/editor toolbar items never mount.
    @ViewBuilder
    private func splitComposeLayout(hostWidth: CGFloat) -> some View {
        let composeWidth = ComposePlacement.splitComposeWidth(hostWidth: hostWidth)
        HStack(spacing: 0) {
            NavigationStack {
                Group {
                    if let id = store.composeRequest?.boundThreadId,
                       let thread = store.thread(withId: id) {
                        ThreadDetailView(
                            thread: thread,
                            compactMode: false,
                            focusMode: true,
                            splitMode: true,
                            onBack: { store.exitSplitCompose() },
                            onReply: { msg in
                                store.openCompose(.init(replyTo: msg))
                            })
                    } else {
                        Text("Conversation unavailable")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.notionContent)
            Color.clear
                .frame(width: composeWidth)
                // Reserve width only — clicks land on the trailing compose
                // overlay card, not this spacer.
                .allowsHitTesting(false)
        }
    }

    /// Detail column is mounted and idle — floating compose can claim it as
    /// a primary writing surface (pane fill). Pure rule lives in
    /// `ComposePlacement.readingPaneIsEmpty` (three-pane only).
    private var readingPaneIsEmpty: Bool {
        ComposePlacement.readingPaneIsEmpty(
            layoutMode: layoutMode,
            openedThreadId: store.openedThreadId)
    }

    /// Floating card vs inline vs pane-fill vs split. One ComposeView identity
    /// so pop-out / promote keep the typed body.
    @ViewBuilder
    private func composeChrome(_ request: MailStore.ComposeRequest) -> some View {
        let minimized = store.composeMinimized
        let presentation = ComposePlacement.resolvedPresentation(
            request.presentation,
            paneHeight: readingPaneFrame.height,
            readingPaneEmpty: readingPaneIsEmpty,
            paneWidth: readingPaneFrame.width)
        // Minimized always docks like floating regardless of presentation.
        let chromePresentation: ComposePresentation = minimized ? .floating : presentation
        let inline = presentation == .inline && !minimized
        let pane = presentation == .pane && !minimized
        let pinToPane = inline || pane
        let split = presentation == .split && !minimized
        let chrome = ComposePlacement.cardChrome(
            presentation: chromePresentation,
            minimized: minimized,
            host: composeHostFrame,
            pane: readingPaneFrame,
            layoutMode: layoutMode)
        let splitPad = ComposePlacement.splitPadding
        let inlineHeight = ComposePlacement.effectiveInlineCardHeight(
            paneHeight: readingPaneFrame.height)
        let paneHeight = ComposePlacement.effectivePaneCardHeight(
            paneHeight: readingPaneFrame.height)
        let cardHeight: CGFloat = minimized ? 40
            : split ? max(composeHostFrame.height - splitPad * 2, 400)
            : pane ? paneHeight
            : (inline ? inlineHeight
               : ComposePlacement.effectiveFloatingCardHeight(
                    hostHeight: composeHostFrame.height))
        // Pin-to-pane uses a full-host-width HStack so trailing-anchored
        // placement agrees with chrome.leading (leading + width + trailing
        // == host). Leading gutter spans sidebar + list under pane-fill —
        // force hit-through so mailbox clicks still land (defensive even if
        // plain Spacer often ignores hits).
        HStack(spacing: 0) {
            if pinToPane {
                Spacer()
                    .frame(width: chrome.leading)
                    .allowsHitTesting(false)
            }
            ComposeView(request: request)
                .id(request.id)
                // topLeading: an over-wide child must not center-clip under
                // clipShape (footer fixedSize / long tokens on narrow cards).
                .frame(width: chrome.width, height: cardHeight, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: minimized ? PMRadius.md : PMRadius.lg))
                .pmCardElevation(cornerRadius: minimized ? PMRadius.md : PMRadius.lg,
                                 intense: true)
            if pinToPane {
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
            }
        }
        .padding(pane
                 ? EdgeInsets(top: 0, leading: 0,
                              bottom: ComposePlacement.paneBottomPadding,
                              trailing: chrome.trailingPadding)
                 : inline
                 ? EdgeInsets(top: 0, leading: 0,
                              bottom: ComposePlacement.inlineBottomPadding,
                              trailing: chrome.trailingPadding)
                 : split
                 ? EdgeInsets(top: splitPad, leading: 0,
                              bottom: splitPad, trailing: chrome.trailingPadding)
                 : EdgeInsets(top: 0, leading: 0,
                              bottom: ComposePlacement.floatingBottomPadding,
                              trailing: chrome.trailingPadding))
        // Pane fill is derived (not stored on the request); animate size when
        // the empty-pane condition flips (e.g. open/close a conversation).
        .animation(.spring(response: 0.3, dampingFraction: 0.85),
                   value: presentation)
    }

    /// True when expanded inline compose is open for the selected thread —
    /// detail pane reserves bottom safe area so the scroll doesn't hide under it.
    /// Pane fill sits in an empty column and must not reserve thread scroll space.
    private var reservesInlineComposeSpace: Bool {
        guard let req = store.composeRequest,
              !store.composeMinimized,
              let selected = store.selectedThreadId else { return false }
        return req.boundThreadId == selected
            && ComposePlacement.resolvedPresentation(
                req.presentation,
                paneHeight: readingPaneFrame.height,
                readingPaneEmpty: readingPaneIsEmpty,
                paneWidth: readingPaneFrame.width
            ) == .inline
    }

    private var inlineComposeReserveHeight: CGFloat {
        guard reservesInlineComposeSpace else { return 0 }
        return ComposePlacement.inlineReservedHeight(
            paneHeight: readingPaneFrame.height)
    }

    @ViewBuilder
    private var listColumn: some View {
        if store.selectedView == .scheduled {
            ScheduledListView()
        } else {
            ThreadListView()
        }
    }

    @ViewBuilder
    private func detailPane(compact: Bool) -> some View {
        // Equatable host: list-focus key-repeat re-renders ContentView (it
        // observes listFocus for open policy / toolbar) but must not rebuild
        // ThreadDetailView until openedThreadId actually changes.
        DetailPaneHost(
            openedThreadId: store.openedThreadId,
            thread: store.openedThreadId.flatMap { id in
                store.threads.first(where: { $0.id == id })
            },
            compact: compact,
            focusMode: store.threadFocusMode,
            paneHidden: effectivePaneHidden,
            inlineReserve: inlineComposeReserveHeight,
            // Read here because DetailPaneHost is deliberately store-free.
            // Non-mutating, so evaluating it in `body` has no side effects.
            initialPayload: store.openedThreadId.flatMap {
                store.warmThreadDetail(threadId: $0)
            },
            onBack: {
                if store.threadFocusMode {
                    store.threadFocusMode = false
                } else {
                    store.clearSelection()
                }
            },
            onReply: { msg in
                store.openCompose(.init(replyTo: msg),
                                  readingPaneHidden: effectivePaneHidden)
            }
        )
        .equatable()
    }
}

/// Isolates reading-pane identity from list-focus churn. Compared only on the
/// fields that should remount or reconfigure the conversation UI.
private struct DetailPaneHost: View, Equatable {
    let openedThreadId: String?
    let thread: MailThread?
    let compact: Bool
    let focusMode: Bool
    let paneHidden: Bool
    let inlineReserve: CGFloat
    /// Seeds a remounted `ThreadDetailView` so its first frame already shows
    /// the conversation. Excluded from `==` (below) and safe to go stale: it
    /// is only consumed when `.id(thread.id)` builds a new pane, which cannot
    /// happen without `thread` — which *is* compared — changing first.
    let initialPayload: ThreadDetailPayload?
    let onBack: () -> Void
    let onReply: (Message) -> Void

    // Closures are deliberately excluded, so a skipped body keeps the OLD
    // captures. Safe only while every environment value a closure captures is
    // mirrored by a compared field (onReply's `effectivePaneHidden` ↔
    // `paneHidden`; onBack reads store live). If you capture a new value in a
    // closure, add its mirror here or it will go stale.
    static func == (lhs: DetailPaneHost, rhs: DetailPaneHost) -> Bool {
        lhs.openedThreadId == rhs.openedThreadId
            && lhs.thread == rhs.thread
            && lhs.compact == rhs.compact
            && lhs.focusMode == rhs.focusMode
            && lhs.paneHidden == rhs.paneHidden
            && lhs.inlineReserve == rhs.inlineReserve
    }

    var body: some View {
        Group {
            if let thread {
                ThreadDetailView(
                    thread: thread,
                    compactMode: compact,
                    focusMode: focusMode,
                    initialPayload: initialPayload,
                    onBack: onBack,
                    onReply: onReply)
                    .id(thread.id)
            } else {
                Text("Select a conversation")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
            }
        }
        .background(Color.notionContent)
        // Keep the last messages above the overlay card.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: inlineReserve)
                .accessibilityHidden(true)
        }
        .animation(nil, value: inlineReserve)
        // Publish the reading column's global frame for inline compose pin.
        // MUST sit outside the safeAreaInset: the reserve height is computed
        // from this measurement, so measuring inside the inset feeds the
        // reserve back into its own input — at window heights below ~1050pt
        // the two maps have no fixed point and layout livelocks (396↔592
        // oscillation, 99% CPU, unbounded memory; shipped in 72d6524).
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ReadingPaneFrameKey.self,
                    value: geo.frame(in: .global))
            }
        )
    }
}

// MARK: - ContentView keyboard helpers (extension keeps main struct smaller)

private extension ContentView {

    /// Gmail-style single-key shortcuts plus Cmd-K. Ignores events when a
    /// text field, the search bar, or a sheet has focus.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
            guard let store else { return event }
            // Settings is capturing a key for rebinding — don't run shortcuts.
            if store.keyBindings.capturing { return event }
            // The snooze overlay runs its own monitor (↑/↓/Return/Esc while
            // typing a date) — everything must pass through untouched.
            if store.snoozingThread != nil { return event }
            // ⇧⌘↩ toggles side-by-side compose (conversation | draft). Runs
            // before the compose-typing passthrough so it works mid-sentence.
            if event.modifierFlags.intersection([.command, .shift, .option, .control])
                == [.command, .shift],
               event.keyCode == 36, store.composeRequest != nil {
                store.toggleSplitCompose()
                return nil
            }
            // Compose Esc ladder (before NSText passthrough): expanded compose
            // owns Esc while open, but priority is explicit — never local-
            // monitor install order (FIFO; an early `return nil` starves later
            // monitors). Pure policy in ComposeEsc.intent.
            if event.keyCode == 53 {
                let isSettings = event.window?.identifier?.rawValue
                    .contains("Settings") == true
                // Mid-finish (Send awaiting persist) is not "expanded" for Esc:
                // save-and-close already ran; don't re-queue it.
                let composeExpanded = ComposeKeyOwnership.claimsTyping(
                    hasRequest: store.composeRequest != nil,
                    minimized: store.composeMinimized,
                    finishing: store.composeFinishing)
                let isSplit = store.composeRequest?.presentation == .split
                    && !store.composeFinishing
                switch ComposeEsc.intent(
                    isSettingsWindow: isSettings,
                    slashPickerVisible: store.slashPickerVisible,
                    commandPaletteOpen: store.showCommandPalette,
                    searchActive: store.searchActive,
                    composeExpanded: composeExpanded,
                    isSplit: isSplit) {
                case .passThrough:
                    // Settings: when compose is nil/minimized the mailbox Esc
                    // ladder below owns blur-then-close; with expanded compose
                    // that gate is skipped and AppKit gets the event (pre-existing).
                    break
                case .dismissSlashPicker:
                    store.dismissSlashPicker()
                    return nil
                case .closeCommandPalette:
                    store.showCommandPalette = false
                    return nil
                case .dismissSearchFocus:
                    // Keep the draft; drop search focus/panel (three-pane +
                    // floating compose + `/` must not save-and-close).
                    event.window?.makeFirstResponder(nil)
                    store.dismissSearchPanel()
                    return nil
                case .exitSplit:
                    store.exitSplitCompose()
                    return nil
                case .saveAndCloseCompose:
                    store.requestComposeEsc()
                    return nil
                case .fallThrough:
                    break
                }
            }
            // Expanded compose + typing: every chord belongs to the text system
            // / compose handlers (⌘K insert-link, ⌃F/⌃K caret motion, …), not
            // app-level shortcuts. Minimized compose resigns focus so inbox
            // keys work again (Notion Mail-style). Mid-finish (Send awaiting
            // persist) also yields so `g i` is not typed into the body. Esc
            // for compose is handled above so it is not trapped here.
            if ComposeKeyOwnership.claimsTyping(
                    hasRequest: store.composeRequest != nil,
                    minimized: store.composeMinimized,
                    finishing: store.composeFinishing),
               event.window?.firstResponder is NSText {
                return event
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            if mods == .command, event.charactersIgnoringModifiers == "k" {
                store.showCommandPalette.toggle()
                return nil
            }
            // ⌘↩: Send when expanded compose owns the chord (button shortcut).
            // Otherwise toggle thread focus mode (conversation fills the app).
            // Plain ⌘ only — ⌘⇧↩ is side-by-side compose (handled above) and
            // must never fall through to focus when no compose is open.
            if mods == .command, event.keyCode == 36,
               !event.modifierFlags.contains(.shift) {
                let composeClaimsReturn = ComposeKeyOwnership.claimsTyping(
                    hasRequest: store.composeRequest != nil,
                    minimized: store.composeMinimized,
                    finishing: store.composeFinishing)
                if !composeClaimsReturn, store.selectedThreadId != nil {
                    store.threadFocusMode.toggle()
                    if store.threadFocusMode, !fullWindowThreads {
                        readingPaneHidden = false
                        store.readingPaneHiddenForCompose = false
                    }
                    return nil
                }
            }
            // ⌘1 = All accounts, ⌘2… = individual accounts, in popover order
            // (Notion Mail-style inbox switching).
            if mods == .command, let chars = event.charactersIgnoringModifiers,
               chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
                if digit == 1 {
                    store.setActiveAccount(nil)
                    return nil
                }
                let index = digit - 2
                if index < store.accounts.count {
                    store.setActiveAccount(store.accounts[index].id)
                    return nil
                }
                return event
            }
            if mods == .control, event.charactersIgnoringModifiers == "f" {
                store.showFilterMenu.toggle()
                return nil
            }
            // ⌘Z undoes the pending toast action (archive/trash/send…). Bare
            // `z` is the rebindable single-key below; this chord is the macOS
            // standard and must not rely on a SwiftUI button shortcut (those
            // often miss when the toast has just appeared). Match the bare-key
            // overlay guards (palette / label picker / view editor) so ⌘Z and
            // `z` agree. Never steal text undo while expanded compose owns typing.
            // After Send, a lagging AppKit re-steal can leave an editable NSText
            // first responder with no compose claiming typing — allow ⌘Z to
            // cancel pending send in that window (same class as post-Send `e`).
            if mods == .command,
               !event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers?.lowercased() == "z",
               store.undoAction != nil,
               !store.showCommandPalette,
               !store.showLabelPicker,
               !store.showShortcutsHelp,
               store.editingView == nil,
               ComposeKeyOwnership.allowsMailboxKeys(
                   hasRequest: store.composeRequest != nil,
                   minimized: store.composeMinimized,
                   finishing: store.composeFinishing),
               !(TextFocus.isEditing(event.window?.firstResponder)
                 && ComposeKeyOwnership.textFocusBlocksMailboxKeys(
                     finishing: store.composeFinishing)
                 && !ComposeKeyOwnership.undoChordBypassesTextFocus(
                     pendingSend: store.pendingSend != nil,
                     composeClaimsTyping: ComposeKeyOwnership.claimsTyping(
                         hasRequest: store.composeRequest != nil,
                         minimized: store.composeMinimized,
                         finishing: store.composeFinishing))) {
                store.perform(.undo)
                return nil
            }
            // ⌘A selects every thread currently loaded in the list (Gmail-
            // style select-all), mirroring the checkbox multi-select. Any
            // editable text field (search, compose, address chips,
            // Settings…) keeps the OS's native Select All instead — this
            // never fires while one is focused.
            if mods == .command,
               !event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers?.lowercased() == "a",
               event.window == NSApp.mainWindow,
               !store.showCommandPalette,
               !store.showLabelPicker,
               !store.showShortcutsHelp,
               store.editingView == nil,
               ComposeKeyOwnership.allowsMailboxKeys(
                   hasRequest: store.composeRequest != nil,
                   minimized: store.composeMinimized,
                   finishing: store.composeFinishing),
               !TextFocus.isEditing(event.window?.firstResponder) {
                store.checkAllVisibleThreads()
                return nil
            }
            if store.showCommandPalette, event.keyCode == 53 {  // esc
                store.showCommandPalette = false
                return nil
            }
            if store.showShortcutsHelp, event.keyCode == 53 {  // esc
                store.showShortcutsHelp = false
                return nil
            }
            // While the help sheet is up, ? still closes it, but no other bare
            // key may fall through to mail actions on the background selection.
            if store.showShortcutsHelp {
                if event.charactersIgnoringModifiers == "?" {
                    store.showShortcutsHelp = false
                    return nil
                }
                return event
            }
            if store.showLabelPicker {
                let picker = store.labelPicker
                switch event.keyCode {
                case 53:  // esc
                    store.showLabelPicker = false
                    return nil
                case 125:  // down — picker clamps to the filtered list
                    picker.highlight += 1
                    picker.navigated = true
                    return nil
                case 126:  // up
                    picker.highlight = max(picker.highlight - 1, 0)
                    picker.navigated = true
                    return nil
                case 36, 76:  // return / keypad enter: toggle (or create)
                    // Handled here, not by the text field's onSubmit — before
                    // the field wins focus, Return would otherwise be eaten
                    // by the default branch below (it's a control character,
                    // so it neither deletes nor appends).
                    if let thread = store.selectedThread {
                        let labels = store.labelPickerLabels(for: thread)
                        let createName = store.labelPickerCreateName(for: thread)
                        let rowCount = labels.count + (createName != nil ? 1 : 0)
                        let idx = min(picker.highlight, max(rowCount - 1, 0))
                        if let label = labels[safe: idx] {
                            store.toggleLabel(thread, labelId: label.gmailLabelId)
                        } else if let createName {
                            store.createLabelAndApply(name: createName, thread: thread)
                        }
                    }
                    return nil
                case 49 where picker.navigated:  // space after arrows: toggle
                    if let thread = store.selectedThread {
                        let labels = store.labelPickerLabels(for: thread)
                        let createName = store.labelPickerCreateName(for: thread)
                        let rowCount = labels.count + (createName != nil ? 1 : 0)
                        let idx = min(picker.highlight, max(rowCount - 1, 0))
                        if let label = labels[safe: idx] {
                            store.toggleLabel(thread, labelId: label.gmailLabelId)
                        } else if let createName {
                            store.createLabelAndApply(name: createName, thread: thread)
                        }
                    }
                    return nil
                default:
                    // If the picker's text field hasn't grabbed focus yet (it
                    // can lose the race right after opening), typed characters
                    // would fall through to the thread list's type-select.
                    // Route them into the filter query instead.
                    if mods.isEmpty, !(event.window?.firstResponder is NSTextView) {
                        if event.keyCode == 51 {  // delete
                            if !picker.query.isEmpty { picker.query.removeLast() }
                        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                                  !chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                            picker.query += chars
                        }
                        return nil
                    }
                }
            }
            // Search dropdown open: ↑/↓/Enter drive the panel directly, so
            // `/` → arrows → Enter works without ever leaving the keyboard.
            // Intercepted here so the text field never sees them. Main window
            // only — Settings keeps its own arrows/Enter even while the
            // sidebar field technically still holds main-window focus.
            if store.searchActive, mods.isEmpty, event.window == NSApp.mainWindow {
                switch event.keyCode {
                case 125:  // down — panel clamps to its rows
                    store.searchHighlight += 1
                    return nil
                case 126:  // up
                    store.searchHighlight = max(store.searchHighlight - 1, 0)
                    return nil
                case 36:   // return — run the highlighted row
                    store.searchActivateToken += 1
                    return nil
                default:
                    break
                }
            }
            // Esc: first press while typing (e.g. in search) drops focus back
            // to the list; otherwise it closes the reading pane (Notion
            // Mail-style) but KEEPS the selection, so you stay where you are.
            // Expanded compose / view editor keep their own Esc behavior;
            // minimized / mid-finish compose does not block Esc.
            if event.keyCode == 53,
               ComposeKeyOwnership.allowsMailboxKeys(
                   hasRequest: store.composeRequest != nil,
                   minimized: store.composeMinimized,
                   finishing: store.composeFinishing),
               store.editingView == nil {
                // The global monitor also fires for the Settings window. There,
                // Esc should close Settings and return to the mailbox — not
                // toggle the main window's reading pane. Drop text-field focus
                // first so an in-progress edit commits before the window closes.
                if let window = event.window,
                   window.identifier?.rawValue.contains("Settings") == true {
                    if window.firstResponder is NSTextView
                        || window.firstResponder is NSTextField {
                        window.makeFirstResponder(nil)
                        return nil
                    }
                    window.close()
                    return nil
                }
                // Editable only: selectable conversation text holding focus
                // must not turn the first Esc into a blur, or leaving a
                // full-window conversation would cost two presses.
                if TextFocus.isEditing(event.window?.firstResponder) {
                    event.window?.makeFirstResponder(nil)
                    // Drop the `/` panel immediately on Esc (don't wait for
                    // the deferred blur dismiss used by mouse clicks).
                    if store.searchActive { store.dismissSearchPanel() }
                    return nil
                }
                // Panel still up after the field already blurred (click-away
                // grace window) — next Esc closes it.
                if store.searchActive {
                    store.dismissSearchPanel()
                    return nil
                }
                // Clear multi-select checks first (Gmail-style Esc ladder).
                if !store.checkedThreadIds.isEmpty {
                    store.clearCheckedThreads()
                    return nil
                }
                // Exit full-app conversation before collapsing the pane.
                if store.threadFocusMode {
                    store.threadFocusMode = false
                    return nil
                }
                // Next Esc drops an active search back to the plain inbox
                // (so from the search field, Esc-Esc gets you home).
                if !store.committedSearch.isEmpty || !store.searchText.isEmpty {
                    store.clearSearch()
                    return nil
                }
                if layoutMode == .compactDetail {
                    store.clearSelection()
                    return nil
                }
                if !fullWindowThreads, !readingPaneHidden {
                    readingPaneHidden = true
                    return nil
                }
            }
            let finishingCompose = store.composeFinishing
            let textEditing = TextFocus.isEditing(event.window?.firstResponder)
            guard mods.isEmpty,
                  !store.showCommandPalette,
                  !store.showLabelPicker,
                  ComposeKeyOwnership.allowsMailboxKeys(
                      hasRequest: store.composeRequest != nil,
                      minimized: store.composeMinimized,
                      finishing: finishingCompose),
                  store.editingView == nil,
                  // Only *editable* text stands the shortcuts down. Selectable
                  // read-only text (the whole conversation) must not — see
                  // TextFocus. Mid-finish bypasses this (see
                  // textFocusBlocksMailboxKeys).
                  !(textEditing
                    && ComposeKeyOwnership.textFocusBlocksMailboxKeys(
                        finishing: finishingCompose))
            else { return event }
            // After the guards: mid-finish with a lagging body focus — resign
            // so the key is not also typed into a finishing draft.
            if finishingCompose, textEditing {
                event.window?.makeFirstResponder(nil)
            }
            // Gmail's `/`: jump focus to the sidebar search field. A
            // collapsed sidebar has no field to focus — reveal it first and
            // focus once the column is installed.
            if event.charactersIgnoringModifiers == "/" {
                if sidebarHidden {
                    withAnimation { sidebarHidden = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        store.focusSearch()
                    }
                } else {
                    store.focusSearch()
                }
                return nil
            }
            // Arrow keys: ↑/↓ browse the list without opening the pane
            // (Enter or a click opens the selected thread); ←/→ hide/show
            // the sidebar.
            switch event.keyCode {
            case 123:  // left — collapse the sidebar
                withAnimation { sidebarHidden = true }
                return nil
            case 124:  // right — reveal the sidebar
                withAnimation { sidebarHidden = false }
                return nil
            case 125:  // down
                browseKeyIsRepeat = event.isARepeat
                store.moveSelection(1, intent: .browse)
                return nil
            case 126:  // up
                browseKeyIsRepeat = event.isARepeat
                store.moveSelection(-1, intent: .browse)
                return nil
            case 36:   // return
                if let thread = store.selectedThread {
                    if store.isDraftOnly(thread) {
                        store.editDraft(inThread: thread)
                        store.clearSelection()
                    } else {
                        detailSelectionTask?.cancel()
                        store.openDetail(thread.id)
                        if fullWindowThreads {
                            store.threadFocusMode = true
                        } else {
                            readingPaneHidden = false
                        }
                    }
                }
                return nil
            default:
                break
            }
            guard let chars = event.charactersIgnoringModifiers else { return event }
            // Gmail Shift+I / Shift+U mark read / unread. Fixed chords (not in
            // KeyBindings): charactersIgnoringModifiers keeps Shift on letters
            // ("I"/"U"), so they must be handled before single-key lookup.
            // Shift+I is state-aware: already-read selection → mark unread.
            // Drop auto-repeat: a held Shift+I would otherwise oscillate
            // read↔unread (state is re-read after each mutation).
            let shiftOnly = event.modifierFlags
                .intersection([.command, .option, .control, .shift]) == [.shift]
            if let chord = GmailMarkReadKeys.chord(key: chars, shiftOnly: shiftOnly) {
                // Don't leave an armed `g` prefix: Shift+I after `g` must not
                // keep the next key as a go-to chord target for 1.5s.
                store.clearPendingGoKey()
                if !event.isARepeat {
                    store.applyGmailMarkReadChord(chord)
                }
                return nil
            }
            // j/k (and other rebindable browse keys) also auto-repeat; pass
            // through so held navigation coalesces like ↑/↓.
            browseKeyIsRepeat = event.isARepeat
            if store.handleKey(chars) { return nil }
            // Unhandled printable keys must not fall through: SwiftUI List
            // type-selects to the first row starting with that letter, which
            // fights Gmail-style single-key bindings on random taps.
            if !chars.isEmpty,
               !chars.unicodeScalars.contains(where: {
                   CharacterSet.controlCharacters.contains($0)
               }) {
                return nil
            }
            return event
        }
    }

    /// Open from a mouse click — immediately, no debounce. Also serves
    /// re-clicks on the already-selected row (openSelectedToken), where the
    /// List selection binding never fires. Non-navigation intents
    /// (auto-advance, restore-focus) swap the mounted detail but never
    /// redirect drafts to compose or reveal a pane the user hid.
    private func openClickedThread(_ selectedId: String,
                                   intent: ThreadSelectionIntent = .click) {
        detailSelectionTask?.cancel()
        store.openDetail(selectedId)
        if intent.redirectsDraftToCompose,
           let thread = store.selectedThread,
           store.isDraftOnly(thread) {
            store.editDraft(inThread: thread)
            store.clearSelection()
            return
        }
        guard intent.revealsReadingPane else { return }
        if fullWindowThreads {
            store.threadFocusMode = true
        } else {
            readingPaneHidden = false
        }
    }

    /// Open the detail pane for a browse selection. Single keypresses open with
    /// no delay; auto-repeating keys coalesce through a short settle. A newer
    /// selection cancels in-flight work so only the latest id opens.
    private func scheduleDetailSelection(_ id: String) {
        detailSelectionTask?.cancel()
        let settle = DetailOpenPolicy.settleNanoseconds(isKeyRepeat: browseKeyIsRepeat)
        // Consume the repeat flag: every browse keypress re-arms it before
        // moveSelection, but a mouse click or programmatic selection after a
        // held-key burst must not inherit the burst's settle delay.
        browseKeyIsRepeat = false
        detailSelectionTask = Task { @MainActor in
            if settle > 0 {
                do {
                    try await Task.sleep(nanoseconds: settle)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard store.selectedThreadId == id else { return }
            store.openDetail(id)
        }
    }
}

struct Sidebar: View {
    @Environment(MailStore.self) var store
    /// `@Environment` has no projected value, so controls that need two-way
    /// access to the store go through this instead of `$store`.
    private var bound: Bindable<MailStore> { Bindable(store) }
    @ObservedObject private var updates = UpdateChecker.shared
    // Driven by `/` (Gmail-style) via store.searchFocusToken.
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Notion Mail-style header: account (avatar, name, address) with
            // compose right next to it, search on its own row below.
            HStack(spacing: 6) {
                AccountSwitcher()
                Button {
                    store.openCompose(.init(replyTo: nil))
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)
                .help("Compose (⌘N or \(store.keyBindings.key(for: .compose)))")
                .accessibilityLabel("Compose")
                .accessibilityIdentifier("composeButton")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            SearchField(prompt: "Search", text: bound.searchText, focused: $searchFocused,
                        emphasized: searchFocused, onSubmit: {
                    // Fallback path — with the dropdown open, Enter is handled
                    // by the key monitor and routed to the panel instead.
                    store.commitSearch(store.searchText)
                    store.dismissSearchPanel()
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    if store.selectedThreadId == nil { store.moveSelection(1) }
                })
                .help("Search — from: to: subject: label: has:attachment is:unread is:starred after: before:")
                .padding(.horizontal, 10).padding(.bottom, 8)
                // Gmail's `/`: focus search.
                .onChange(of: store.searchFocusToken) { searchFocused = true }
                // Drive the window-level results panel from the field's focus.
                // Blur is deferred (see noteSearchFocused) so a click on a
                // result row can land before the panel is torn down.
                .onChange(of: searchFocused) { store.noteSearchFocused(searchFocused) }
            List(selection: bound.selectedView) {
                Section("Views") {
                    sidebarItem(.inbox, badge: store.unreadCounts["inbox"])
                    sidebarItem(.promotions, badge: store.unreadCounts["promotions"])
                    sidebarItem(.social, badge: store.unreadCounts["social"])
                    sidebarItem(.starred, badge: store.unreadCounts["starred"])
                    sidebarItem(.snoozed, badge: store.unreadCounts["snoozed"])
                    sidebarItem(.labels)
                    ForEach(store.savedViews) { view in
                        sidebarItem(.saved(view.id ?? -1, view.name))
                            .contextMenu {
                                Button("Edit View…") { store.editingView = view }
                                Button("Delete View", role: .destructive) { store.deleteView(view) }
                            }
                    }
                    Button {
                        store.editingView = SavedView.empty()
                    } label: {
                        Label("Add view", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Section("Mail") {
                    sidebarItem(.allMail)
                    sidebarItem(.sent)
                    // Count is total drafts (not unread) — Notion Mail-style.
                    sidebarItem(.drafts, badge: store.unreadCounts["drafts"])
                    // Only surfaces once something is scheduled (Gmail-style).
                    if !store.scheduledSends.isEmpty || store.selectedView == .scheduled {
                        sidebarItem(.scheduled, badge: store.scheduledSends.count)
                    }
                    sidebarItem(.reminders, badge: store.unreadCounts["reminders"])
                    sidebarItem(.trash)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            // Settings pinned at the bottom (also Cmd-, from anywhere).
            Divider()
            if store.demoMode {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.notionAccent)
                    Text("Demo inbox")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Button("Exit") { store.exitDemoMode() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("exitDemoInbox")
                }
                .padding(.horizontal, 12).padding(.top, 8)
                .help("Fictional mail only — Gmail sync and sending are disabled")
            }
            if let release = updates.available {
                Button {
                    updates.openUpdate()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                        // Says "restart" up front: from here one click on a
                        // sidebar row installs and relaunches the app.
                        Text("Update to \(release.version) and restart")
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.top, 8)
                .help("Install MishMail \(release.version) and relaunch")
            }
            SettingsLink {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                    Text("Settings")
                        .font(.system(size: 12.5))
                    Spacer()
                    Text("⌘,")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .help("Settings (⌘,)")
        }
        .background(Color.notionSidebar)
    }


    /// Notion Mail-style row: each view keeps its own icon color.
    private func sidebarItem(_ view: MailboxView, badge: Int? = nil) -> some View {
        // List(selection:) only fires onChange when the value *changes*, so
        // re-clicking the already-selected row (e.g. Inbox while a committed
        // `/` search is active) would otherwise be a no-op — same shape as the
        // original gi bug. Only install the reselect gesture for hit-testing
        // when this row is already selected (GestureMask.subviews otherwise):
        // a permanent TapGesture on every row steals List selection on macOS
        // (same class as ThreadListView's selected-only open overlay). Keep
        // one view identity (no if/else branch) so selection flips don't
        // rebuild the row. `.tag` stays outermost so List(selection:) sees it.
        let reselect = ListReselectPolicy.mountsHandler(
            row: view, selected: store.selectedView)
        return Label {
            Text(view.title)
        } icon: {
            Image(systemName: view.icon)
                .foregroundStyle(view.iconColor)
        }
        .badge((badge ?? 0) > 0 ? badge! : 0)
        .accessibilityIdentifier(sidebarAccessibilityID(for: view))
        .simultaneousGesture(
            TapGesture().onEnded { store.goTo(view) },
            including: reselect ? .gesture : .subviews)
        .tag(view)
    }

    /// Stable id for UI tests / a11y (e.g. `sidebar.inbox`, `sidebar.sent`).
    private func sidebarAccessibilityID(for view: MailboxView) -> String {
        switch view {
        case .account(let email): return "sidebar.account.\(email)"
        case .scheduled: return "sidebar.scheduled"
        case .saved(let id, _): return "sidebar.saved.\(id)"
        case .label(let account, let labelId, _):
            return "sidebar.label.\(account).\(labelId)"
        default:
            if let key = view.prefsKey { return "sidebar.\(key)" }
            return "sidebar.\(view.title)"
        }
    }
}


/// Measures the panel's natural content height so the floating panel can hug
/// its rows (instead of ScrollView greedily claiming its full max height and
/// leaving dead space below the last row).
private struct SearchPanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Wide command-K-style search results panel. Floats at the window level (see
/// ContentView) so it can be much wider than the sidebar, spilling over the
/// message list like Notion Mail. Shows recent searches when the query is
/// empty; otherwise a "View all results" row plus Contacts and Threads.
/// ↑/↓/Enter come in from the global key monitor via searchHighlight /
/// searchActivateToken, so the flow is fully keyboard-driven after `/`.
struct SearchResultsPanel: View {
    @Environment(MailStore.self) var store
    // Live thread matches; refreshed as the query changes.
    @State private var threadPreview: [MailThread] = []
    // Contact matches for the current query — @State so we filter once per
    // keystroke, not on every SwiftUI body/layout pass (was a major / jank source).
    @State private var contactPreview: [MailStore.Contact] = []
    // Natural content height, so the panel caps+scrolls at 460 but otherwise
    // shrinks to fit. Defaults to the cap so the first frame isn't collapsed.
    @State private var contentHeight: CGFloat = 460
    // Debounced, off-main FTS lookup for the live preview.
    @State private var previewTask: Task<Void, Never>?

    /// Everything the highlight can land on, in display order.
    private enum Row {
        case viewAll
        case contact(MailStore.Contact)
        case thread(MailThread)
        case recent(String)
    }

    private var trimmedSearch: String {
        store.searchText.trimmingCharacters(in: .whitespaces)
    }

    private var visibleRecentSearches: [String] {
        guard !trimmedSearch.isEmpty else { return store.recentSearches }
        return store.recentSearches.filter {
            $0.range(of: trimmedSearch, options: .caseInsensitive) != nil
                && $0.caseInsensitiveCompare(trimmedSearch) != .orderedSame
        }
    }

    /// Contacts shown in the panel: matches while typing, top senders when the
    /// query is empty (so `/` opens a full panel immediately, Notion-style).
    private var shownContacts: [MailStore.Contact] {
        trimmedSearch.isEmpty ? Array(store.contacts.prefix(3)) : contactPreview
    }

    private var rows: [Row] {
        let base = trimmedSearch.isEmpty
            ? visibleRecentSearches.map { Row.recent($0) }
            : [Row.viewAll]
        return base
            + shownContacts.map { .contact($0) }
            + threadPreview.map { .thread($0) }
    }

    /// Index where the Contacts section starts (recents or view-all precede it).
    private var contactsStart: Int {
        trimmedSearch.isEmpty ? visibleRecentSearches.count : 1
    }

    /// The store's raw highlight, clamped to what's actually on screen.
    private var highlight: Int { min(store.searchHighlight, max(rows.count - 1, 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if trimmedSearch.isEmpty {
                            recentsSection
                        } else {
                            viewAllResultsRow(index: 0).id(0)
                        }
                        if !shownContacts.isEmpty {
                            sectionHeader("Contacts")
                            ForEach(Array(shownContacts.enumerated()), id: \.element.id) { i, contact in
                                contactRow(contact, index: contactsStart + i).id(contactsStart + i)
                            }
                        }
                        if !threadPreview.isEmpty {
                            sectionHeader("Threads")
                            ForEach(Array(threadPreview.enumerated()), id: \.element.id) { i, thread in
                                threadRow(thread, index: contactsStart + shownContacts.count + i)
                                    .id(contactsStart + shownContacts.count + i)
                            }
                        }
                        if !trimmedSearch.isEmpty, shownContacts.isEmpty, threadPreview.isEmpty {
                            Text("No contacts or threads match")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                        }
                    }
                    .padding(.vertical, 5)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: SearchPanelContentHeightKey.self,
                                               value: geo.size.height)
                    })
                }
                // Hug the content, but cap (and scroll) at 460.
                .frame(height: min(contentHeight, 460))
                .onPreferenceChange(SearchPanelContentHeightKey.self) { contentHeight = $0 }
                // Keyboard highlight: clamp over-scrolled ↓ presses back to the
                // last row (like LabelPicker) and keep the row visible.
                .onChange(of: store.searchHighlight) {
                    if store.searchHighlight >= rows.count {
                        store.searchHighlight = max(rows.count - 1, 0)
                    }
                    proxy.scrollTo(highlight)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PMRadius.md + 2))
        .pmCardElevation(cornerRadius: PMRadius.md + 2, intense: true)
        .onAppear {
            store.searchHighlight = 0
            refreshThreadPreview()
        }
        .onDisappear { previewTask?.cancel() }
        .onChange(of: store.searchText) {
            store.searchHighlight = 0
            refreshThreadPreview()
        }
        // Contact mining can finish after the panel opened with a typed query;
        // re-filter so matches aren't stuck empty until the next keystroke.
        .onChange(of: store.contacts) {
            guard !trimmedSearch.isEmpty else { return }
            contactPreview = store.contactSuggestions(for: trimmedSearch)
        }
        // The empty-query "latest threads" must track the list (it can reload
        // right after ✕ clears a committed search, in either observer order).
        .onChange(of: store.threads) { if trimmedSearch.isEmpty { refreshThreadPreview() } }
        // Enter from the key monitor: run whatever is highlighted.
        .onChange(of: store.searchActivateToken) { activate(rows[safe: highlight]) }
    }

    private func activate(_ row: Row?) {
        switch row {
        case .viewAll:
            runFullSearch(store.searchText)
        case .contact(let contact):
            runFullSearch("from:\(contact.email)")
        case .thread(let thread):
            openThread(thread)
        case .recent(let query):
            runFullSearch(query)
        case nil:
            // Nothing to act on (e.g. empty recents) — just close the panel.
            store.dismissSearchPanel()
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func rowBackground(_ index: Int) -> some View {
        (index == highlight ? Color.notionAccent.opacity(0.18) : Color.clear)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold)).kerning(0.4)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 3)
    }

    private func viewAllResultsRow(index: Int) -> some View {
        Button { runFullSearch(store.searchText) } label: {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).frame(width: 20)
                Text("View all results")
                Text("\u{201C}\(trimmedSearch)\u{201D}")
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "return").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .font(.system(size: 13.5))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground(index))
        .onHover { if $0 { store.searchHighlight = index } }
    }

    private func contactRow(_ contact: MailStore.Contact, index: Int) -> some View {
        Button {
            // Notion Mail-style: jump to everything from this person.
            runFullSearch("from:\(contact.email)")
        } label: {
            HStack(spacing: 9) {
                avatar(for: contact.name.isEmpty ? contact.email : contact.name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.name.isEmpty ? contact.email : contact.name)
                        .font(.system(size: 13)).lineLimit(1)
                    if !contact.name.isEmpty {
                        Text(contact.email)
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground(index))
        .onHover { if $0 { store.searchHighlight = index } }
    }

    private func threadRow(_ thread: MailThread, index: Int) -> some View {
        Button { openThread(thread) } label: {
            HStack(spacing: 9) {
                Image(systemName: "envelope")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                        .font(.system(size: 13, weight: thread.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    Text(thread.participants.isEmpty ? thread.snippet : thread.participants)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground(index))
        .onHover { if $0 { store.searchHighlight = index } }
    }

    private func avatar(for label: String) -> some View {
        let initial = label.first.map { String($0).uppercased() } ?? "?"
        return Circle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 24, height: 24)
            .overlay(Text(initial).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary))
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if visibleRecentSearches.isEmpty {
                // Nothing yet — the Contacts/Threads sections below still fill
                // the panel, so no placeholder needed beyond a search hint.
                Text("Search — from: to: subject: label: is:unread …")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                HStack {
                    Text("RECENT SEARCHES")
                        .font(.system(size: 10, weight: .semibold)).kerning(0.4)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { store.clearRecentSearches() }
                        .buttonStyle(.plain).font(.system(size: 11))
                        .foregroundStyle(.secondary).help("Clear search history")
                }
                .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 3)
                ForEach(Array(visibleRecentSearches.enumerated()), id: \.element) { i, query in
                    Button { runFullSearch(query) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 20)
                            Text(query).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 4)
                            Button { store.removeRecentSearch(query) } label: {
                                Image(systemName: "xmark").font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain).help("Remove from history")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(rowBackground(i))
                    .onHover { if $0 { store.searchHighlight = i } }
                    .id(i)
                }
                .padding(.bottom, 5)
            }
        }
    }

    private func openThread(_ thread: MailThread) {
        // Commit the query so the list shows matching results, then select
        // this thread (pinned into `threads` immediately so the reading pane
        // can resolve it while the async reload finishes).
        if !trimmedSearch.isEmpty { store.commitSearch(trimmedSearch) }
        store.openThread(thread)
        store.dismissSearchPanel()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Commit the search to the thread list and hand focus back to it.
    private func runFullSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        store.commitSearch(q)
        store.dismissSearchPanel()
        NSApp.keyWindow?.makeFirstResponder(nil)
        if store.selectedThreadId == nil { store.moveSelection(1) }
    }

    private func refreshThreadPreview() {
        previewTask?.cancel()
        let q = trimmedSearch
        // Empty query: latest threads from the current list, so `/` opens a
        // full panel right away — instant, straight from memory.
        if q.isEmpty {
            contactPreview = []
            threadPreview = Array(store.threads.prefix(4))
            return
        }
        // Contacts: in-memory, update immediately once per keystroke (not in
        // `body`). Threads: debounce, then FTS off the main thread. Keep the
        // previous thread rows until the new ones arrive (no flicker).
        contactPreview = store.contactSuggestions(for: q)
        // Short queries skip FTS (too broad); clear stale multi-char results.
        if q.count < ThreadTypeahead.minimumQueryLength {
            threadPreview = []
            return
        }
        previewTask = Task {
            // 80ms feels snappier than 120ms once the FTS path is a single
            // limited JOIN; still coalesces fast typists.
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            let matches = await store.threadSuggestions(for: q)
            guard !Task.isCancelled else { return }
            threadPreview = matches
        }
    }
}

/// Notion Mail-style account scope switcher: unified, or one account only.
/// Accounts carry user-defined labels ("Personal", "Fund", …).
/// A Button + popover, NOT a Menu: macOS flattens custom views in Menu
/// labels, which drops the avatar and name entirely.
struct AccountSwitcher: View {
    @Environment(MailStore.self) var store
    /// `@Environment` has no projected value, so controls that need two-way
    /// access to the store go through this instead of `$store`.
    private var bound: Bindable<MailStore> { Bindable(store) }
    @State private var showMenu = false
    /// Id of the account row currently being dragged, for the fade feedback
    /// and to resolve source/destination indices on drop.
    @State private var draggingAccountId: String?

    var body: some View {
        Button {
            showMenu = true
        } label: {
            HStack(spacing: 8) {
                if let account = activeAccount {
                    avatar(for: displayTitle(account), key: account.id, size: 28)
                } else {
                    allInboxesIcon(size: 28)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let account = activeAccount, let label = labelText(account) {
                            labelPill(label, account: account)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                accountRow(nil, shortcut: 1)
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                    accountRow(account, shortcut: index + 2)
                        .opacity(draggingAccountId == account.id ? 0.4 : 1)
                        .animation(.easeInOut(duration: 0.08), value: draggingAccountId)
                        .onDrag {
                            draggingAccountId = account.id
                            return NSItemProvider(object: account.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: AccountDropDelegate(
                            target: account, draggingId: $draggingAccountId, store: store))
                }
                // Discoverability: grips alone can read as decoration; a
                // one-line caption matches LabelOrganizer and only appears
                // when reorder is possible (2+ accounts).
                if canReorderAccounts {
                    Text("Drag to reorder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                }
                Divider().padding(.vertical, 4)
                FilterMenuRow(icon: "plus", title: "Add Google Account…") {
                    showMenu = false
                    store.addAccount()
                }
                FilterMenuRow(icon: "pencil", title: "Edit Account Labels…") {
                    showMenu = false
                    store.editingAccountLabels = true
                }
            }
            .padding(8)
            .frame(width: 280)
            // Catch-all: a drop that lands on the divider, "Add Google
            // Account…" row, or empty padding (not an account row) still
            // needs to clear the fade — the per-row AccountDropDelegate
            // only fires when the drop lands on another account row.
            .onDrop(of: [.text], isTargeted: nil) { _ in
                draggingAccountId = nil
                return true
            }
        }
        // A drag that ends outside the popover (or the popover closing
        // mid-drag) never reaches any onDrop — clear the fade so the source
        // row isn't stuck dimmed after reopening.
        .onChange(of: showMenu) { if !showMenu { draggingAccountId = nil } }
        .sheet(isPresented: bound.editingAccountLabels) {
            AccountLabelsEditor()
        }
    }

    /// True when the switcher can reorder — needs at least two real accounts.
    /// "All accounts" stays pinned and never shows a grip.
    private var canReorderAccounts: Bool { store.accounts.count > 1 }

    /// One row of the account popover: optional drag grip, avatar, name +
    /// address, checkmark. `shortcut` is the ⌘-digit that switches to this
    /// scope from anywhere.
    private func accountRow(_ account: Account?, shortcut: Int? = nil) -> some View {
        let selected = store.activeAccountId == account?.id
        return Button {
            store.setActiveAccount(account?.id)
            showMenu = false
        } label: {
            HStack(spacing: 8) {
                // Leading grip on reorderable account rows; matching spacer
                // on "All accounts" so avatars stay column-aligned.
                if canReorderAccounts {
                    if account != nil {
                        // Visual + pointer-tooltip only — hide from AX so the
                        // row button's name stays "Name, address…" instead of
                        // leading with "Drag to reorder". Hint lives on the
                        // Button below; caption text covers static discovery.
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                            .help("Drag to reorder")
                            .accessibilityHidden(true)
                    } else {
                        Color.clear.frame(width: 12)
                    }
                }
                if let account {
                    avatar(for: displayTitle(account), key: account.id, size: 24)
                } else {
                    allInboxesIcon(size: 24)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.map(displayTitle) ?? "All accounts")
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(account?.id ?? "\(store.accounts.count) inboxes")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let account, let label = labelText(account) {
                    labelPill(label, account: account)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.notionAccent)
                }
                if let shortcut, shortcut <= 9 {
                    Text("⌘\(shortcut)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(account != nil && canReorderAccounts ? "Drag to reorder" : "")
        .hoverTint()
    }

    /// Stacked-trays icon for the unified "All accounts" scope.
    private func allInboxesIcon(size: CGFloat) -> some View {
        Image(systemName: "tray.2.fill")
            .font(.system(size: size * 0.54)).foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }

    /// Colored circle with the first initial, Notion Mail-style.
    private func avatar(for name: String, key: String, size: CGFloat) -> some View {
        Circle()
            .fill(Color.stable(for: key))
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private var activeAccount: Account? {
        store.activeAccountId.flatMap { id in store.accounts.first { $0.id == id } }
    }

    /// Full name first, like Notion Mail's account header: the outgoing
    /// sender name if set, then the local label, then the address.
    private func displayTitle(_ account: Account) -> String {
        if !account.senderName.isEmpty { return account.senderName }
        return account.displayName
    }

    /// The local label, when it adds information beyond the title/address.
    /// Rendered as a tinted pill next to the name, never as part of it.
    private func labelText(_ account: Account) -> String? {
        guard !account.senderName.isEmpty else { return nil }
        let label = account.displayName
        guard !label.isEmpty, label != account.id, label != account.senderName else { return nil }
        return label
    }

    /// Small capsule tinted with the account's avatar color ("Fund", "Personal").
    private func labelPill(_ label: String, account: Account) -> some View {
        let tint = Color.stable(for: account.id)
        return Text(label)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private var title: String {
        activeAccount.map(displayTitle) ?? "All accounts"
    }

    private var subtitle: String {
        store.activeAccountId ?? "\(store.accounts.count) inboxes"
    }
}

/// Live-reorders the account switcher as a dragged row crosses a neighbor —
/// the standard SwiftUI reorderable-list pattern (List's `.onMove` isn't
/// available here since the popover is a plain VStack, not a List).
private struct AccountDropDelegate: DropDelegate {
    let target: Account
    @Binding var draggingId: String?
    let store: MailStore

    func dropEntered(info: DropInfo) {
        guard let draggingId, draggingId != target.id,
              let from = store.accounts.firstIndex(where: { $0.id == draggingId }),
              let to = store.accounts.firstIndex(where: { $0.id == target.id }) else { return }
        store.reorderAccounts(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }
}

/// Rename accounts ("Personal", "Fund", …); labels are local only.
struct AccountLabelsEditor: View {
    @Environment(MailStore.self) var store
    @Environment(\.dismiss) private var dismiss
    @State private var labels: [String: String] = [:]
    @State private var senderNames: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Accounts")
                .font(.headline)
                .padding(.bottom, 10)
            Form {
                ForEach(store.accounts) { account in
                    Section(account.id) {
                        TextField("Label (only you see this)", text: .init(
                            get: { labels[account.id] ?? account.displayName },
                            set: { labels[account.id] = $0 }
                        ), prompt: Text("e.g. Personal"))
                        TextField("Send as (recipients see this)", text: .init(
                            get: { senderNames[account.id] ?? account.senderName },
                            set: { senderNames[account.id] = $0 }
                        ), prompt: Text("e.g. Jane Doe"))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    for (id, label) in labels { store.renameAccount(id, label: label) }
                    for (id, name) in senderNames { store.setSenderName(id, name: name) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(width: 420)
    }
}
