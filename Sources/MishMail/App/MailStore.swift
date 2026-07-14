import Foundation
import SwiftUI
import AppKit
import GRDB

enum MailboxView: Hashable {
    case inbox          // unified inbox, minus Promotions/Social
    case promotions
    case social
    case starred
    case snoozed
    case labels         // all labeled mail, one section per label (Notion-style)
    case reminders
    case drafts
    case scheduled      // locally scheduled sends (not Gmail threads)
    case sent
    case allMail
    case trash
    case account(String)          // one account's inbox
    case label(account: String, labelId: String, name: String)
    case saved(Int64, String)     // custom view id + name

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .promotions: return "Promotions"
        case .social: return "Social"
        case .starred: return "Starred"
        case .snoozed: return "Snoozed"
        case .labels: return "Labels"
        case .reminders: return "Reminders"
        case .drafts: return "Drafts"
        case .scheduled: return "Scheduled"
        case .sent: return "Sent"
        case .allMail: return "All Mail"
        case .trash: return "Trash"
        case .account(let a): return a
        case .label(_, _, let name): return name
        case .saved(_, let name): return name
        }
    }

    /// Stable key for persisting per-view preferences (category picks).
    /// nil = the view doesn't persist them (saved views carry their own
    /// filters; scheduled isn't a mail list).
    var prefsKey: String? {
        switch self {
        case .inbox, .account: return "inbox"
        case .promotions: return "promotions"
        case .social: return "social"
        case .starred: return "starred"
        case .snoozed: return "snoozed"
        case .labels: return "labels"
        case .reminders: return "reminders"
        case .drafts: return "drafts"
        case .sent: return "sent"
        case .allMail: return "allMail"
        case .trash: return "trash"
        // Keyed per account: Gmail label IDs (Label_1, Label_2…) are only
        // unique within an account, so two accounts' labels must not share
        // a preference slot.
        case .label(let account, let labelId, _): return "label.\(account).\(labelId)"
        case .scheduled, .saved: return nil
        }
    }
}

/// Notion Mail-style category filter: a set of Gmail categories that the
/// inbox either must not contain (default) or must contain.
struct CategoryFilter: Equatable, Codable {
    var exclude = true                 // which set the Categories popover edits
    var show: Set<String> = []         // must contain any of these
    var hide: Set<String> = []         // must contain none of these

    static let names = [
        "CATEGORY_PROMOTIONS": "Promotions",
        "CATEGORY_SOCIAL": "Social",
        "CATEGORY_UPDATES": "Updates",
        "CATEGORY_FORUMS": "Forums",
    ]

    var isActive: Bool { !show.isEmpty || !hide.isEmpty }

    /// The set the Categories popover is currently editing.
    var categories: Set<String> {
        get { exclude ? hide : show }
        set { if exclude { hide = newValue } else { show = newValue } }
    }

    var title: String {
        guard isActive else { return "All" }
        var parts: [String] = []
        if !show.isEmpty {
            parts.append(show.map { Self.names[$0] ?? $0 }.sorted().joined(separator: ", "))
        }
        if !hide.isEmpty {
            parts.append("Not " + hide.map { Self.names[$0] ?? $0 }.sorted().joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }
}

/// Relative received-date window for the filter bar.
enum DateWindow: Int, CaseIterable, Codable {
    case today = 1, week = 7, month = 30

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        }
    }
}

/// Transient filter chips layered on top of the current view (the bar above
/// the thread list). Reset when the view changes.
struct FilterChips: Equatable, Codable {
    var category = CategoryFilter()
    var unreadOnly = false
    var showArchived = false
    var labelId: String?
    var labelName: String?
    var labelExclude = false      // "does not contain" mode for the label
    var senderContains = ""
    var senderExclude = false     // "does not contain" mode for the sender
    /// Matches against message From headers (email address or "@domain"),
    /// unlike senderContains which matches display names. Optional so views
    /// saved before this field existed still decode. Powers "Split from Inbox".
    var fromEmailContains: String? = nil
    var hasAttachmentOnly = false
    var noAttachmentOnly = false
    var readOnly = false          // isUnread == false
    var showSent = false          // widen inbox to include SENT threads
    var toContains = ""
    var ccContains = ""
    var bccContains = ""
    var subjectContains = ""
    var dateWindow: DateWindow?   // received within the last N days
    var calendarOnly = false      // only threads with a calendar invite (.ics)
    var hideCalendar = false      // hide threads with a calendar invite

    /// Built-in factory default chips for a view (inbox hides
    /// Promotions/Social). Pure — never reads persisted state, so
    /// "changed vs default" comparisons and Clear all mean the factory
    /// default, and Clear all is always a way back to it.
    static func defaults(for view: MailboxView) -> FilterChips {
        var chips = FilterChips()
        switch view {
        case .inbox, .account:
            chips.category = CategoryFilter(
                exclude: true,
                hide: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"])
        default:
            break
        }
        return chips
    }

    /// What a view opens with: the factory defaults, plus the category pick
    /// the user made earlier (persisted per view) so it survives view
    /// switches and relaunch.
    static func initial(for view: MailboxView) -> FilterChips {
        var chips = defaults(for: view)
        if let saved = savedCategory(for: view) { chips.category = saved }
        return chips
    }

    static func savedCategory(for view: MailboxView) -> CategoryFilter? {
        guard let key = view.prefsKey,
              let data = UserDefaults.standard.data(forKey: "categoryFilter.\(key)")
        else { return nil }
        return try? JSONDecoder().decode(CategoryFilter.self, from: data)
    }

    static func saveCategory(_ category: CategoryFilter, for view: MailboxView) {
        guard let key = view.prefsKey,
              let data = try? JSONEncoder().encode(category) else { return }
        // Persisting the factory default is the same as having no pick;
        // drop the key so future built-in default changes reach the user.
        if category == defaults(for: view).category {
            UserDefaults.standard.removeObject(forKey: "categoryFilter.\(key)")
        } else {
            UserDefaults.standard.set(data, forKey: "categoryFilter.\(key)")
        }
    }
}

/// Per-keystroke label picker state, split out of MailStore so typing and
/// arrow keys only re-render the picker — the rest of the window observes
/// MailStore and must not churn on every character.
@MainActor
final class LabelPickerState: ObservableObject {
    // The filter text lives here (not @State in the view) so the window key
    // monitor can route typed characters in while the text field is still
    // winning the focus race — otherwise a fast second keystroke falls
    // through to the thread list's type-select.
    @Published var query = "" {
        didSet { if query != oldValue { navigated = false } }
    }
    // Arrow-key highlight. Driven by the window-level key monitor (the
    // picker's text field eats arrow events before SwiftUI's onKeyPress sees
    // them); the view clamps it to the filtered list.
    @Published var highlight = 0
    // True once arrows moved the highlight; space then toggles the
    // highlighted label instead of typing into the filter. Typing resets it.
    var navigated = false
}

@MainActor
final class MailStore: ObservableObject {
    @Published var accounts: [Account] = []
    /// From identities (primary + Gmail send-as) across all linked accounts.
    /// Used by compose's From picker; never confuse `email` with API mailbox.
    @Published private(set) var sendIdentities: [SendIdentity] = []
    @Published var labelsByAccount: [String: [LabelRow]] = [:]
    @Published var threads: [MailThread] = []
    @Published var savedViews: [SavedView] = []
    @Published var selectedView: MailboxView = .inbox {
        didSet {
            readStateKeepIds.removeAll()
            resetListWindow()
        }
    }
    @Published var selectedThreadId: String? {
        didSet {
            if selectedThreadId != oldValue {
                prefetchNeighborThreads()
            }
        }
    }
    /// Multi-select checkboxes (Gmail `x` / Notion-style toggle). Bulk
    /// archive/trash/star/read act on this set when non-empty; the focused
    /// `selectedThreadId` still drives the reading pane.
    @Published var checkedThreadIds: Set<String> = []
    /// Anchor for shift-click range select on checkboxes.
    private var lastCheckedThreadId: String?
    /// Cancels in-flight neighbor header/body warm when selection moves.
    private var neighborPrefetchTask: Task<Void, Never>?
    /// In-flight contacts rebuild (full-table `message` scan); must be
    /// cancelled and awaited before the DatabasePool is closed on quit.
    private var contactsRebuildTask: Task<Void, Never>?
    /// Once true, no new background database work is started. Set by
    /// `prepareForTermination()` on app quit.
    private(set) var isShuttingDown = false
    /// Single-flight quit work so a second Cmd-Q / re-entrant
    /// `applicationShouldTerminate` awaits the same shutdown instead of
    /// replying `true` while the first close is still in flight.
    private let terminationSlot = DatabaseLifecycle.FlightSlot()
    /// Gmail-style "?" cheat sheet.
    @Published var showShortcutsHelp = false
    /// User-rebindable single-key shortcuts (Settings → Keyboard shortcuts).
    let keyBindings = KeyBindings()
    /// Live text in the search field. Drives ONLY the dropdown preview —
    /// the inbox list keeps showing `committedSearch` until you commit.
    @Published var searchText: String = ""
    /// The query the thread list is actually filtered by. Set when a search
    /// is committed (Enter / View all results / picking a suggestion).
    @Published var committedSearch: String = ""
    /// Bumped by `/` (Gmail-style) to move keyboard focus into the sidebar
    /// search field. The sidebar watches this and drives its `@FocusState`.
    @Published var searchFocusToken = 0
    /// True while the search field is focused, so ContentView can float the
    /// wide command-K-style results panel over the message list.
    @Published var searchActive = false
    /// ↑/↓ highlight in the search dropdown (the panel clamps to its rows,
    /// same pattern as the label picker's highlight).
    @Published var searchHighlight = 0
    /// Bumped by Enter while the dropdown is open; the panel runs the
    /// highlighted row.
    @Published var searchActivateToken = 0

    /// Commit a query: filter the thread list by it and remember it.
    func commitSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchText = q
        committedSearch = q
        recordSearch(q)
        clearCheckedThreads()
        resetListWindow()
        reloadThreads()
    }

    /// Drop an active search and return to the plain view (Esc, or the ✕ on
    /// the results banner).
    func clearSearch() {
        guard !searchText.isEmpty || !committedSearch.isEmpty else { return }
        searchText = ""
        committedSearch = ""
        clearCheckedThreads()
        resetListWindow()
        reloadThreads()
    }

    /// Switch mailbox (g-then-i, command palette "Go to…", etc.) and leave any
    /// active `/` search. Without clearing search, the list stays on the FTS
    /// path and ignores `selectedView` — so `gi` after a search looked like a
    /// no-op when already on Inbox, and left a filtered overlay otherwise.
    /// View changes rely on ContentView's `selectedView` onChange to reload;
    /// same-view go-to reloads here after clearing search.
    func goTo(_ view: MailboxView) {
        let plan = GoToMailbox.plan(
            destinationIsCurrent: selectedView == view,
            searchText: searchText,
            committedSearch: committedSearch)
        // Clear inline — do not call clearSearch(). That helper reloads, and a
        // cross-view goTo already reloads once via ContentView's selectedView
        // onChange; calling clearSearch would double-reload.
        if plan.clearSearch {
            searchText = ""
            committedSearch = ""
        }
        if plan.changeView {
            selectedView = view
        } else if plan.reloadImmediately {
            reloadThreads()
        }
    }
    /// Recent search queries, newest first, shown under the search field while
    /// it has focus. Persisted so history survives relaunch.
    @Published var recentSearches: [String] =
        UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []

    /// Remember a submitted/picked query: dedupe (case-insensitive), move to
    /// front, cap the list so the dropdown stays scannable.
    func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentSearches = Array(list.prefix(8))
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    func removeRecentSearch(_ query: String) {
        recentSearches.removeAll { $0 == query }
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: "recentSearches")
    }
    @Published var chips = FilterChips.initial(for: .inbox) {
        // Category picks persist per view so they're back after relaunch.
        // Only user edits persist — programmatic resets (view switches) go
        // through resetChips() so built-in defaults never get frozen into
        // UserDefaults as if the user had chosen them.
        didSet {
            if !suppressChipPersistence, chips.category != oldValue.category {
                FilterChips.saveCategory(chips.category, for: selectedView)
            }
        }
    }
    private var suppressChipPersistence = false

    /// Reset the filter bar for the current view: factory defaults plus the
    /// user's persisted category pick. Doesn't count as a user edit.
    func resetChips() {
        suppressChipPersistence = true
        chips = FilterChips.initial(for: selectedView)
        suppressChipPersistence = false
    }
    @Published var activeAccountId: String?   // nil = all accounts (unified)
    @Published var syncStatus: String = ""
    @Published private var presentedError: PresentedError?
    /// Existing callers can continue assigning plain messages; they safely
    /// default to retry. Errors that require another action set a structured
    /// presentation instead of relying on wording inspection in the UI.
    var lastError: String? {
        get { presentedError?.message }
        set { presentedError = newValue.map(ErrorRecovery.retry) }
    }
    var lastErrorRecovery: ErrorRecoveryAction {
        presentedError?.recovery ?? .retrySync
    }
    @Published private(set) var demoMode = DemoSeed.isActive
    /// Account ids whose saved sign-in Google has rejected (expired/revoked
    /// refresh token); the Accounts settings pane offers a "Reauthorize"
    /// button for these.
    @Published var accountsNeedingReauth: Set<String> = []
    @Published var composeRequest: ComposeRequest?
    /// Compose card is collapsed to a title strip (Notion Mail-style). Draft
    /// state stays mounted; inbox shortcuts work again while minimized.
    @Published var composeMinimized = false
    /// Reading pane fills the window (sidebar + list hidden). Toggled with ⌘↩
    /// when a conversation is selected and Send is not claiming the chord.
    @Published var threadFocusMode = false
    /// ContentView mirrors its AppStorage pane flag here so keyboard reply
    /// can choose inline vs floating without reading UserDefaults itself.
    var readingPaneHiddenForCompose = false
    @Published var undoAction: UndoAction?
    @Published var editingView: SavedView?
    @Published var editingAccountLabels = false
    @Published var showLabelPicker = false
    @Published var showLabelOrganizer = false
    @Published var snoozingThread: MailThread?   // custom snooze date sheet
    /// Draft message pending the "Delete this draft?" alert (per-message so
    /// multi-draft threads discard the card that was clicked, not always the newest).
    @Published var confirmingDraftDelete: Message?
    // Per-keystroke picker state lives in its own object (constant reference,
    // so mutations don't fire MailStore.objectWillChange) — otherwise every
    // typed character re-renders the whole window, not just the picker.
    let labelPicker = LabelPickerState()

    /// Open the label picker with fresh state — every entry point (shortcut,
    /// command palette, toolbar/"Add category") must go through here so a
    /// stale query/highlight from the last use never leaks in.
    func openLabelPicker() {
        labelPicker.query = ""
        labelPicker.highlight = 0
        labelPicker.navigated = false
        showLabelPicker = true
    }
    @Published var showCommandPalette = false
    @Published var showFilterMenu = false   // "+ Filter" popover (Ctrl-F)
    @Published var unreadCounts: [String: Int] = [:]   // sidebar badges
    @Published var notice: String?                      // transient confirmation toast
    private var noticeTimer: Timer?

    func showNotice(_ text: String) {
        notice = text
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.notice = nil }
        }
    }

    // MARK: - On-device AI triage

    @Published var aiCategories: [String: String] = [:]   // threadId → category
    @Published var classifying = false
    private var aiCategoriesLoaded = false

    /// Loads the persisted category map once; after that the in-memory map is
    /// authoritative (classifyInbox updates it as it writes rows), so thread
    /// reloads don't re-read the table every time.
    func loadAICategories() {
        guard !aiCategoriesLoaded else { return }
        aiCategoriesLoaded = true
        let rows = (try? db.read { try ThreadAICategory.fetchAll($0) }) ?? []
        aiCategories = Dictionary(rows.map { ($0.threadId, $0.category) }) { _, last in last }
    }

    /// Classifies the currently loaded threads into local AI buckets. Manual
    /// and sequential (a small local model), skipping already-classified
    /// threads. Results persist in their own table so sync never wipes them.
    func classifyInbox() {
        guard !classifying else { return }
        let targets = threads.filter { aiCategories[$0.id] == nil }
        guard !targets.isEmpty else {
            showNotice("All caught up — nothing new to sort.")
            return
        }
        classify(targets, quiet: false)
    }

    /// Auto-triage: after each sync, quietly classify new inbox mail with the
    /// local model. Quiet on purpose — Ollama may simply not be running — and
    /// backs off ten minutes after a failure so a down server isn't retried
    /// on every 60-second sync tick.
    static let autoClassifyKey = "autoClassifyEnabled"
    private var autoClassifyPausedUntil: Date?

    func autoClassifyNewMail() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.autoClassifyKey) == nil
                || defaults.bool(forKey: Self.autoClassifyKey) else { return }
        if let pause = autoClassifyPausedUntil, pause > Date() { return }
        loadAICategories()
        let candidates = (try? db.read { db in
            try MailThread
                .filter(Column("inInbox") == true && Column("inTrash") == false)
                .order(Column("lastDate").desc).limit(100).fetchAll(db)
        }) ?? []
        classify(candidates.filter { aiCategories[$0.id] == nil }, quiet: true)
    }

    private func classify(_ targets: [MailThread], quiet: Bool) {
        guard !classifying, !targets.isEmpty else { return }
        classifying = true
        Task {
            var done = 0
            for thread in targets {
                let from = thread.participants.isEmpty ? thread.fromDisplay : thread.participants
                let prompt = Ollama.classify(subject: thread.subject, from: from,
                                             snippet: thread.snippet, categories: Classifier.categories)
                do {
                    let raw = try await Ollama.generate(prompt: prompt)
                    let category = Classifier.normalize(raw)
                    try? await db.write { database in
                        try ThreadAICategory(threadId: thread.id, category: category).save(database)
                    }
                    await MainActor.run {
                        aiCategories[thread.id] = category
                        done += 1
                        syncStatus = "Sorting with AI… \(done)/\(targets.count)"
                    }
                } catch {
                    await MainActor.run {
                        classifying = false
                        syncStatus = ""
                        if quiet {
                            autoClassifyPausedUntil = Date().addingTimeInterval(600)
                        } else {
                            showNotice(error.localizedDescription)
                        }
                    }
                    return
                }
            }
            await MainActor.run {
                classifying = false
                syncStatus = ""
                if !quiet {
                    showNotice("Sorted \(done) thread\(done == 1 ? "" : "s") with AI.")
                }
            }
        }
    }

    // MARK: - VIP senders

    /// Lowercased VIP addresses, and which loaded threads they sent. Kept in
    /// memory so the priority partition never queries per row.
    @Published private(set) var vipEmails: Set<String> = []
    @Published private(set) var vipThreadIds: Set<String> = []
    @Published private(set) var vipGroups: [String: String] = [:]
    @Published private(set) var vipGroupEnabled: [String: Bool] = [:]

    /// VIPs that actually count: members of a toggled-off group are paused.
    var activeVIPEmails: Set<String> {
        vipEmails.filter { vipGroupEnabled[vipGroups[$0] ?? ""] ?? true }
    }

    func loadVIPs() {
        let rows = (try? db.read { try VIPSender.fetchAll($0) }) ?? []
        vipEmails = Set(rows.map { $0.email.lowercased() })
        if demoMode { vipEmails.formUnion(DemoSeed.vipSenders) }
        var groups: [String: String] = [:]
        for row in rows {
            if let groupName = row.groupName, !groupName.isEmpty {
                groups[row.email.lowercased()] = groupName
            }
        }
        vipGroups = groups
        let groupRows = (try? db.read { try VIPGroupRow.fetchAll($0) }) ?? []
        vipGroupEnabled = Dictionary(uniqueKeysWithValues: groupRows.map { ($0.name, $0.enabled) })
    }

    /// Group definitions persist in their own table so a group survives losing
    /// its last member; tag values still count for rows created before v14.
    private func ensureVIPGroup(_ name: String?, in db: GRDB.Database) throws {
        guard let name, !name.isEmpty else { return }
        if try VIPGroupRow.fetchOne(db, key: name) == nil {
            try VIPGroupRow(name: name).insert(db)
        }
    }

    func addVIP(_ email: String, group: String? = nil) {
        guard !demoMode else {
            showNotice("VIP changes are disabled in the demo inbox")
            return
        }
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard e.contains("@") else { return }
        try? db.write { db in
            try ensureVIPGroup(group, in: db)
            try VIPSender(email: e, groupName: group).save(db)
        }
        loadVIPs()
        reloadThreads()
        showNotice("\(e) added to VIPs")
    }

    /// Batch add (VIP manager paste box): one write, one reload, one notice.
    /// Returns how many were actually new.
    @discardableResult
    func addVIPs(_ emails: [String], group: String? = nil) -> Int {
        guard !demoMode else {
            showNotice("VIP changes are disabled in the demo inbox")
            return 0
        }
        let fresh = Set(emails.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") && !vipEmails.contains($0) })
        guard !fresh.isEmpty else { return 0 }
        try? db.write { db in
            try ensureVIPGroup(group, in: db)
            for e in fresh { try VIPSender(email: e, groupName: group).save(db) }
        }
        loadVIPs()
        reloadThreads()
        showNotice(fresh.count == 1 ? "\(fresh.first!) added to VIPs"
                                    : "\(fresh.count) senders added to VIPs")
        return fresh.count
    }

    func removeVIP(_ email: String) {
        guard !demoMode else {
            showNotice("VIP changes are disabled in the demo inbox")
            return
        }
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        try? db.write { _ = try VIPSender.deleteOne($0, key: e) }
        loadVIPs()
        reloadThreads()
    }

    func setVIPGroup(_ email: String, group: String?) {
        guard !demoMode else {
            showNotice("VIP changes are disabled in the demo inbox")
            return
        }
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        let g = (group ?? "").isEmpty ? nil : group
        try? db.write { db in
            try ensureVIPGroup(g, in: db)
            if var sender = try VIPSender.fetchOne(db, key: e) {
                sender.groupName = g
                try sender.update(db)
            }
        }
        loadVIPs()
        reloadThreads()
    }

    /// Pause/resume VIP status for a whole group.
    func setVIPGroupEnabled(_ name: String, _ enabled: Bool) {
        guard !demoMode else {
            showNotice("VIP changes are disabled in the demo inbox")
            return
        }
        try? db.write { try VIPGroupRow(name: name, enabled: enabled).save($0) }
        loadVIPs()
        reloadThreads()
    }

    var allVIPGroupNames: [String] {
        Set(vipGroups.values).union(vipGroupEnabled.keys).sorted()
    }

    /// Newest sender address on a thread (for the Add/Remove VIP menu).
    func senderEmail(of thread: MailThread) -> String? {
        let header = (try? db.read { db in
            try String.fetchOne(db, sql: """
                SELECT fromHeader FROM message WHERE threadId = ?
                ORDER BY date DESC LIMIT 1
                """, arguments: [thread.id])
        }) ?? nil
        guard let header else { return nil }
        let email = MessageParser.emailAddress(header).lowercased()
        return email.contains("@") ? email : nil
    }

    /// Recomputes which of the loaded threads came from a VIP. Any message From
    /// in the thread can pin it (not only the newest). Prefer the off-main path
    /// in `reloadThreads` — this MainActor entry point is for VIP list mutations
    /// that already hold the thread list in memory.
    func refreshVIPThreadIds() {
        let active = activeVIPEmails
        guard !active.isEmpty, !threads.isEmpty else {
            if !vipThreadIds.isEmpty { vipThreadIds = [] }
            return
        }
        let snapshot = threads
        vipThreadIds = (try? db.read { db in
            try Self.computeVIPThreadIds(threads: snapshot, activeVIP: active, db: db)
        }) ?? []
    }

    /// VIP hits for a thread list. A thread pins if *any* message's From is VIP
    /// (replying must not drop Priority). Denorm `fromEmail` is a positive
    /// short-circuit only; non-hits still scan messages. Safe off MainActor.
    nonisolated static func computeVIPThreadIds(threads: [MailThread],
                                                activeVIP: Set<String>,
                                                db: Database) throws -> Set<String> {
        guard !activeVIP.isEmpty, !threads.isEmpty else { return [] }
        var hits = Set<String>()
        var needScan: [String] = []
        for t in threads {
            // Newest From is VIP → hit without a message join.
            if !t.fromEmail.isEmpty, activeVIP.contains(t.fromEmail) {
                hits.insert(t.id)
            } else {
                // Still scan: an older message may be from a VIP.
                needScan.append(t.id)
            }
        }
        guard !needScan.isEmpty else { return hits }
        let placeholders = needScan.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT threadId, fromHeader FROM message
            WHERE threadId IN (\(placeholders))
            """, arguments: StatementArguments(needScan))
        for row in rows {
            let header: String = row["fromHeader"]
            if activeVIP.contains(MessageParser.emailAddress(header).lowercased()) {
                hits.insert(row["threadId"])
            }
        }
        return hits
    }

    // MARK: - Gmail filters (read-only cache)

    /// Per-account Gmail filters, loaded lazily for Settings and for the
    /// "matching filters" disclosure under each message card. Nil entry means
    /// not yet attempted; empty array means loaded and the account has none.
    @Published private(set) var filtersByAccount: [String: [GFilter]] = [:]
    /// Human-readable load failure per account (scope missing, network, …).
    /// Cleared on success. On transient failure we keep any previous cache so
    /// matching-filter sections don't vanish because of a blip.
    @Published private(set) var filtersLoadError: [String: String] = [:]
    /// Accounts currently mid-fetch — UI can show a spinner. Backed by a
    /// refcount so overlapping force+lazy loads don't drop the spinner early.
    @Published private(set) var filtersLoading: Set<String> = []
    private var filterLoadRefCounts: [String: Int] = [:]
    /// In-flight filter fetches; concurrent callers await the same task.
    /// Token lets a finishing load clear its slot without clobbering a newer one.
    private var filterLoadTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Fetch filters for one account. Non-force short-circuits only on a
    /// successful cache hit (errors are retried). Concurrent loads coalesce;
    /// a `force` caller that joins an in-flight load then starts a fresh
    /// fetch so Settings still gets a refresh.
    func ensureFiltersLoaded(for accountId: String, force: Bool = false) async {
        guard !demoMode else {
            filtersByAccount[accountId] = []
            filtersLoadError[accountId] = nil
            return
        }
        if !force, filtersByAccount[accountId] != nil { return }

        if let inflight = filterLoadTasks[accountId] {
            await inflight.task.value
            if !force { return }
            // Force after waiting: only join if a *different* load started
            // while we slept. The finished load's continuation may not have
            // cleared its slot yet (same-token stale entry) — fall through
            // and refresh in that case, or the Settings force is dropped.
            if let again = filterLoadTasks[accountId], again.token != inflight.token {
                await again.task.value
                return
            }
            // else fall through and refresh
        }

        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchFilters(accountId: accountId)
        }
        filterLoadTasks[accountId] = (token, task)
        beginFilterLoad(accountId)
        await task.value
        if filterLoadTasks[accountId]?.token == token {
            filterLoadTasks[accountId] = nil
        }
        endFilterLoad(accountId)
    }

    private func beginFilterLoad(_ accountId: String) {
        filterLoadRefCounts[accountId, default: 0] += 1
        filtersLoading.insert(accountId)
    }

    private func endFilterLoad(_ accountId: String) {
        let n = (filterLoadRefCounts[accountId] ?? 1) - 1
        if n <= 0 {
            filterLoadRefCounts[accountId] = nil
            filtersLoading.remove(accountId)
        } else {
            filterLoadRefCounts[accountId] = n
        }
    }

    private func fetchFilters(accountId: String) async {
        let previous = filtersByAccount[accountId]
        let client = client(for: accountId)
        do {
            let filters = try await client.listFilters()
            filtersByAccount[accountId] = filters
            filtersLoadError[accountId] = nil
        } catch GmailError.http(403, _) {
            filtersLoadError[accountId] =
                "MishMail doesn't have permission to read this account's filters yet. Remove and re-add the account (Accounts pane) to grant it."
            // Keep any previous good cache; only leave the slot empty when we
            // never had one (so UI can show the scope error).
            if previous == nil { filtersByAccount[accountId] = nil }
        } catch {
            filtersLoadError[accountId] = error.localizedDescription
            if previous == nil { filtersByAccount[accountId] = nil }
        }
    }

    /// Best-effort filters whose criteria match this message. Empty when the
    /// account's filters aren't loaded yet or none match.
    func matchingFilters(for message: Message) -> [GFilter] {
        guard let filters = filtersByAccount[message.accountId] else { return [] }
        return GmailFilterMatch.matching(filters, message: .init(message))
    }

    /// Open the thread in gmail.com (useful for filter edits / full Gmail UI).
    func openInGmail(_ thread: MailThread) {
        guard !demoMode else {
            showNotice("Opening Gmail is disabled in the demo inbox")
            return
        }
        guard let url = GmailWebLinks.threadURL(
            accountEmail: thread.accountId, gmailThreadId: thread.gmailThreadId)
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Block the thread's newest-from address (denorm `fromEmail`). No-op for
    /// empty / own addresses. Used by the reading-pane ⋯ menu.
    func blockThreadSender(_ thread: MailThread) {
        let email = thread.fromEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@") else { return }
        guard !accounts.contains(where: { $0.id.lowercased() == email }) else { return }
        blockSender(email)
    }

    // MARK: - Blocked senders

    /// Lowercased blocked addresses. Their threads move to Spam immediately
    /// on block and again after every sync (new arrivals).
    @Published private(set) var blockedEmails: Set<String> = []

    func loadBlocked() {
        let rows = (try? db.read { try BlockedSender.fetchAll($0) }) ?? []
        blockedEmails = Set(rows.map { $0.email.lowercased() })
    }

    func isBlocked(_ email: String) -> Bool {
        blockedEmails.contains(email.trimmingCharacters(in: .whitespaces).lowercased())
    }

    func blockSender(_ email: String) {
        guard !demoMode else {
            showNotice("Blocking is disabled in the demo inbox")
            return
        }
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard e.contains("@") else { return }
        try? db.write { try BlockedSender(email: e).save($0) }
        loadBlocked()
        applyBlocklist()
        showNotice("Blocked \(e) — their mail goes to Spam")
    }

    func unblockSender(_ email: String) {
        guard !demoMode else {
            showNotice("Blocking is disabled in the demo inbox")
            return
        }
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        try? db.write { _ = try BlockedSender.deleteOne($0, key: e) }
        loadBlocked()
        showNotice("Unblocked \(e)")
    }

    /// Moves every inbox thread from a blocked sender to Spam. Quiet (no
    /// per-thread undo toast — blocking is the undoable act, via Unblock).
    /// Runs on block and after each sync so new arrivals never linger.
    /// Matches denorm `fromEmail` / `allFromEmails` in SQL (no full inbox load).
    func applyBlocklist() {
        guard !blockedEmails.isEmpty else { return }
        let blocked = Array(blockedEmails)
        let hits = PerfMetrics.measure(.syncBlocklist, meta: "blocked=\(blocked.count)") {
            (try? db.read { db -> [MailThread] in
                // Exact token match — no LIKE (underscore is common in emails
                // and is a single-char wildcard under LIKE).
                var parts: [String] = []
                var args: [String] = []
                for e in blocked {
                    parts.append("""
                        (fromEmail = ?
                         OR instr(' ' || allFromEmails || ' ', ' ' || ? || ' ') > 0)
                        """)
                    args.append(contentsOf: [e, e])
                }
                return try MailThread.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM thread
                        WHERE inInbox = 1 AND inTrash = 0
                          AND (\(parts.joined(separator: " OR ")))
                        """,
                    arguments: StatementArguments(args))
            }) ?? []
        }
        for thread in hits {
            mutateThread(thread) { t in
                t.inInbox = false
                // Keep labelIds / denorm coherent with the SPAM move.
                var labels = Set(t.labels)
                labels.remove("INBOX")
                labels.insert("SPAM")
                t.labelIds = labels.sorted().joined(separator: " ")
                t.syncFlagsFromLabelIds()
            } remote: { client, id in
                try await client.modifyThread(id: id, add: ["SPAM"], remove: ["INBOX"])
            }
        }
    }

    /// User-facing label for an account ("Personal", "Fund", …).
    func renameAccount(_ id: String, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        try? db.write { db in
            if var account = try Account.fetchOne(db, key: id) {
                account.displayName = trimmed.isEmpty ? id : trimmed
                try account.update(db)
            }
        }
        reloadAccounts()
    }

    /// Name recipients see on outgoing mail ("Ron Boger <ron@…>").
    func setSenderName(_ id: String, name: String) {
        try? db.write { db in
            if var account = try Account.fetchOne(db, key: id) {
                account.senderName = name.trimmingCharacters(in: .whitespaces)
                try account.update(db)
            }
        }
        reloadAccounts()
    }

    struct ComposeRequest: Identifiable {
        let id = UUID()
        let replyTo: Message?
        var replyAll = false
        var forward = false
        /// Gmail "Forward all": package every message in the source thread into
        /// the body (still a **new** conversation — no threadId / In-Reply-To).
        var forwardAll = false
        var editDraft: Message? = nil   // an existing Gmail draft being edited
        var restore: PendingSend? = nil // undone send: reopen with this content
        var prefillTo: String? = nil    // new mail straight to this address
        /// Floating card vs reading-pane dock. Placement helpers set this;
        /// pop-out / hide-pane can promote inline → floating without remount.
        var presentation: ComposePresentation = .floating

        /// Thread this compose is bound to (reply parent or draft), if any.
        var boundThreadId: String? { replyTo?.threadId ?? editDraft?.threadId }
    }

    /// Open compose with placement decided from the current selection / pane.
    /// Callers that already fixed `presentation` (pop-out) should assign
    /// `composeRequest` directly instead.
    func openCompose(_ request: ComposeRequest,
                     readingPaneHidden: Bool? = nil) {
        var req = request
        let paneHidden = readingPaneHidden ?? readingPaneHiddenForCompose
        req.presentation = ComposePlacement.preferred(
            replyTo: req.replyTo,
            editDraft: req.editDraft,
            forward: req.forward,
            selectedThreadId: selectedThreadId,
            readingPaneHidden: paneHidden)
        composeMinimized = false
        composeRequest = req
    }

    /// Promote an inline compose to the floating card (same request id).
    func popOutCompose() {
        guard var req = composeRequest else { return }
        req.presentation = .floating
        composeRequest = req
        composeMinimized = false
    }

    /// If compose was inline for a thread we left or hid, keep the work as a
    /// floating card instead of tearing it down.
    func promoteInlineComposeIfNeeded(selectedThreadId: String?,
                                      readingPaneHidden: Bool) {
        guard var req = composeRequest, req.presentation == .inline else { return }
        let stillHere = !readingPaneHidden
            && req.boundThreadId != nil
            && req.boundThreadId == selectedThreadId
        guard !stillHere else { return }
        req.presentation = .floating
        composeRequest = req
    }

    struct UndoAction: Identifiable {
        let id = UUID()
        let label: String
        let undo: () -> Void
    }

    var selectedThread: MailThread? {
        threads.first { $0.id == selectedThreadId }
    }

    func setActiveAccount(_ id: String?) {
        activeAccountId = id
        selectedThreadId = nil
        clearCheckedThreads()
        readStateKeepIds.removeAll()
        reloadThreads()
    }

    func clearCheckedThreads() {
        checkedThreadIds.removeAll()
        lastCheckedThreadId = nil
    }

    /// Toggle multi-select on one thread. With `extendRange` (shift-click),
    /// checks every row between the last toggle and this id in display order.
    func toggleChecked(_ id: String, extendRange: Bool = false) {
        let order = selectionOrder
        if extendRange, let anchor = lastCheckedThreadId,
           let range = SelectionAdvance.rangeIds(in: order, from: anchor, to: id) {
            let allOn = range.allSatisfy { checkedThreadIds.contains($0) }
            if allOn {
                for rid in range { checkedThreadIds.remove(rid) }
            } else {
                for rid in range { checkedThreadIds.insert(rid) }
            }
            lastCheckedThreadId = id
            return
        }
        if checkedThreadIds.contains(id) {
            checkedThreadIds.remove(id)
        } else {
            checkedThreadIds.insert(id)
        }
        lastCheckedThreadId = id
    }

    /// Gmail `x`: toggle check on the focused conversation.
    func toggleCheckSelected() {
        guard let id = selectedThreadId else { return }
        toggleChecked(id)
    }

    private let db = AppDatabase.shared.dbPool
    private var syncTimer: Timer?
    private var undoTimer: Timer?
    private var engines: [String: SyncEngine] = [:]
    private var clients: [String: GmailClient] = [:]
    private var knownUnreadInboxIds: Set<String> = []
    private var notifiedThreadIds: Set<String> = []
    // Threads whose read state changed while an unread/read filter was active.
    // They stay listed (so opening an unread thread doesn't yank it out from
    // under the reading pane) until the filter is dropped or the view changes.
    private var readStateKeepIds: Set<String> = []

    private var readStateFilterActive: Bool {
        if chips.unreadOnly || chips.readOnly { return true }
        if case .saved(let id, _) = selectedView,
           savedViews.first(where: { $0.id == id })?.unreadOnly == true { return true }
        // Cmd-K / search operators share the same stickiness so opening an
        // is:unread result and auto-marking it read doesn't yank the row.
        let search = committedSearch.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty, SearchQuery.parse(search).unread != nil { return true }
        return false
    }

    init() {
        let demoSeeded = DemoSeed.seedIfRequested(AppDatabase.shared.dbPool)
        reloadAccounts()
        // An environment flag must never turn a real Debug account into a
        // fake/offline account when seeding was correctly refused.
        demoMode = demoSeeded && !accounts.isEmpty
            && accounts.allSatisfy { $0.id == DemoSeed.account }
        // Primaries immediately; send-as aliases fill in after the API call.
        sendIdentities = fallbackIdentities()
        reloadSavedViews()
        loadVIPs()
        loadBlocked()
        reloadThreads()
        reloadScheduledSends()
        // Load send-as identities before firing due scheduled sends so From
        // headers get alias display names, not bare emails.
        Task {
            await self.refreshSendIdentities()
            await self.fireDueScheduledSends()
        }
        knownUnreadInboxIds = currentUnreadInboxIds()
        notifiedThreadIds = knownUnreadInboxIds
        Notifier.requestPermission()
        startPolling()
        rebuildMetadataIfNeeded()
        rebuildContacts()
        reloadSnippets()
        seedDefaultSnippetsIfNeeded()
    }

    func enterDemoMode() {
        guard accounts.isEmpty else {
            showNotice("Remove real accounts before starting the demo inbox.")
            return
        }
        guard DemoSeed.activate(db) else {
            showNotice("The demo inbox couldn't be started.")
            return
        }
        demoMode = true
        lastError = nil
        accountsNeedingReauth.removeAll()
        selectedView = .inbox
        selectedThreadId = nil
        reloadAccounts()
        reloadSavedViews()
        loadVIPs()
        loadBlocked()
        reloadThreads()
        reloadScheduledSends()
        sendIdentities = fallbackIdentities()
        showNotice("Fictional mail — nothing syncs or sends")
    }

    @discardableResult
    func exitDemoMode() -> Bool {
        guard demoMode else { return true }
        guard DemoSeed.deactivate(db) else {
            showNotice("The demo inbox couldn't be closed. Try again.")
            return false
        }
        demoMode = false
        lastError = nil
        accountsNeedingReauth.removeAll()
        selectedView = .inbox
        selectedThreadId = nil
        composeRequest = nil
        reloadAccounts()
        reloadSavedViews()
        loadVIPs()
        loadBlocked()
        reloadThreads()
        reloadScheduledSends()
        sendIdentities = []
        filtersByAccount[DemoSeed.account] = nil
        filtersLoadError[DemoSeed.account] = nil
        return true
    }

    /// One-time seed of the starter snippets, so `/` in compose has something
    /// to show on a fresh install. Runs once (tracked in UserDefaults) and
    /// skips names that already exist, so it never fights an import or a delete.
    private func seedDefaultSnippetsIfNeeded() {
        let key = "didSeedDefaultSnippets"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let planned = SnippetImport.plan(SnippetDefaults.items,
                                         existingNames: allSnippets.map(\.name))
        try? db.write { db in
            for item in planned {
                var s = Snippet(id: nil, name: item.name, body: item.body,
                                movesToBcc: item.movesToBcc ?? false)
                s.accountIds = item.accountIds ?? []
                try s.insert(db)
            }
        }
        UserDefaults.standard.set(true, forKey: key)
        if !planned.isEmpty {
            reloadSnippets()
            objectWillChange.send()
        }
    }

    // MARK: - Contacts (derived from synced mail; no extra Google scopes)

    /// UI-facing contact type (stable path for AddressField / search).
    typealias Contact = ContactMiner.Contact

    @Published private(set) var contacts: [Contact] = []
    /// Full weight map kept in memory so incremental passes merge correctly
    /// (the published list is only the top 2000).
    private var contactWeights: ContactMiner.WeightMap = [:]
    /// Own addresses the current weight map was built under — account add/remove
    /// forces a full rebuild so own-mail exclusion stays correct.
    private var contactsOwnAddresses: Set<String> = []
    private var contactsRebuildGeneration = 0
    private static let contactsHighWaterKey = "contacts.highWaterRowId"

    /// Every address we consider "me" for reply recipient filtering: linked
    /// account primaries plus send-as aliases (so replying to own mail as an
    /// alias doesn't put that alias in To).
    var ownEmailAddresses: Set<String> {
        var set = Set(accounts.map { $0.id.lowercased() })
        for id in sendIdentities { set.insert(id.email.lowercased()) }
        return set
    }

    /// From identities offered for a compose mode. Pass the mailbox that
    /// owns the thread/draft for reply/forward/edit; nil for brand-new mail.
    func fromIdentities(forMailbox mailboxAccountId: String?) -> [SendIdentity] {
        let all = sendIdentities.isEmpty ? fallbackIdentities() : sendIdentities
        return SendIdentityResolver.available(all: all, forMailbox: mailboxAccountId)
    }

    /// Synthetic primaries when send-as hasn't been fetched yet (offline /
    /// first paint / scope missing).
    private func fallbackIdentities() -> [SendIdentity] {
        accounts.map {
            SendIdentity(email: $0.id, displayName: $0.senderName,
                         accountId: $0.id, isPrimary: true, isDefault: true)
        }
    }

    /// Refresh send-as identities for one account (or all). Failures leave
    /// that account as primary-only so compose still works.
    func refreshSendIdentities(accountId: String? = nil) async {
        guard !demoMode else {
            sendIdentities = fallbackIdentities()
            return
        }
        let targets = accountId.map { [$0] } ?? accounts.map(\.id)
        guard !targets.isEmpty else {
            sendIdentities = []
            return
        }
        var byAccount = sendIdentities.reduce(into: [String: [SendIdentity]]()) { dict, id in
            dict[id.accountId, default: []].append(id)
        }
        // Keep non-targeted accounts; replace targeted ones.
        for id in targets {
            let senderName = accounts.first { $0.id == id }?.senderName ?? ""
            let rows: [GSendAs]
            do {
                rows = try await client(for: id).listSendAs()
            } catch {
                // Pre-scope tokens get 403; network blips too. Primary-only.
                rows = []
            }
            byAccount[id] = SendIdentityResolver.identities(
                accountId: id, senderName: senderName, sendAs: rows)
        }
        // Drop removed accounts.
        let live = Set(accounts.map(\.id))
        sendIdentities = byAccount
            .filter { live.contains($0.key) }
            .values
            .flatMap { $0 }
            .sorted { a, b in
                if a.accountId != b.accountId { return a.accountId < b.accountId }
                if a.isPrimary != b.isPrimary { return a.isPrimary }
                return a.email.lowercased() < b.email.lowercased()
            }
    }

    /// Re-mine contacts from message headers. Incremental by default (messages
    /// with rowid above the high-water mark); full when forced, on first run,
    /// when the in-memory map is empty, or when the account set changes.
    func rebuildContacts(forceFull: Bool = false) {
        guard !isShuttingDown else { return }
        let ownAddresses = ownEmailAddresses
        let accountsChanged = ownAddresses != contactsOwnAddresses
        let full = forceFull || accountsChanged
            || contactWeights.isEmpty
            || UserDefaults.standard.integer(forKey: Self.contactsHighWaterKey) == 0
        if full {
            contactWeights = [:]
            UserDefaults.standard.set(0, forKey: Self.contactsHighWaterKey)
        }
        let afterRowId = full
            ? Int64(0)
            : Int64(UserDefaults.standard.integer(forKey: Self.contactsHighWaterKey))
        contactsRebuildGeneration += 1
        let generation = contactsRebuildGeneration
        let pool = db
        // Tracked Task (not fire-and-forget): termination must cancel + await
        // this full-table scan before closing the DatabasePool / process exit.
        contactsRebuildTask?.cancel()
        contactsRebuildTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let rows: [ContactMiner.MessageHeaders] = (try? await pool.read { db in
                let sql: String
                let args: StatementArguments
                if afterRowId > 0 {
                    sql = """
                        SELECT rowid, fromHeader, toHeader, ccHeader, labelIds FROM message
                        WHERE rowid > ? ORDER BY rowid
                        """
                    args = [afterRowId]
                } else {
                    sql = """
                        SELECT rowid, fromHeader, toHeader, ccHeader, labelIds FROM message
                        ORDER BY rowid
                        """
                    args = []
                }
                return try Row.fetchAll(db, sql: sql, arguments: args).map { row in
                    ContactMiner.MessageHeaders(
                        rowid: row["rowid"],
                        fromHeader: row["fromHeader"],
                        toHeader: row["toHeader"],
                        ccHeader: row["ccHeader"],
                        labelIds: row["labelIds"])
                }
            }) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isShuttingDown,
                      generation == self.contactsRebuildGeneration else { return }
                // Accounts changed mid-flight — restart with the current set
                // (we may have already cleared weights for a full pass).
                let currentOwn = Set(self.accounts.map { $0.id.lowercased() })
                if ownAddresses != currentOwn {
                    self.rebuildContacts(forceFull: true)
                    return
                }
                // Full passes already wiped the map; re-clear in case a stale
                // incremental applied nothing after we reset (generation guards
                // the common race; this keeps full-pass semantics explicit).
                if full { self.contactWeights = [:] }
                let maxSeen = ContactMiner.merge(messages: rows,
                                                 into: &self.contactWeights,
                                                 excluding: ownAddresses)
                if maxSeen > 0 {
                    UserDefaults.standard.set(Int(maxSeen), forKey: Self.contactsHighWaterKey)
                }
                self.contactsOwnAddresses = ownAddresses
                self.contacts = ContactMiner.ranked(from: self.contactWeights)
            }
        }
    }

    /// Stop timers, cancel and await active database Tasks, flush a pending
    /// undo-send, then close the shared DatabasePool. Called from
    /// `applicationShouldTerminate` so process teardown cannot race SQLCipher
    /// while a GRDB reader is still in `sqlcipher_page_hmac`.
    ///
    /// Re-entrant: a second call (double Cmd-Q, logout re-sending quit) awaits
    /// the same in-flight task instead of returning immediately and letting
    /// the delegate `reply(true)` while the pool is still open.
    func prepareForTermination() async {
        // Gate new DB work before the first suspension point so a MainActor
        // hop cannot start rebuildContacts between here and executeTermination.
        isShuttingDown = true
        await DatabaseLifecycle.singleFlight(slot: terminationSlot) { [self] in
            await self.executeTermination()
        }
    }

    private func executeTermination() async {
        syncTimer?.invalidate()
        syncTimer = nil
        undoTimer?.invalidate()
        undoTimer = nil
        noticeTimer?.invalidate()
        noticeTimer = nil
        pendingSendTimer?.invalidate()
        pendingSendTimer = nil
        scheduledSendTimer?.invalidate()
        scheduledSendTimer = nil

        // Snapshot then clear so a late completion cannot re-schedule work.
        let tasks = [
            contactsRebuildTask,
            threadReloadTask,
            loadMoreTask,
            chipReloadTask,
            neighborPrefetchTask,
        ].compactMap { $0 }
        contactsRebuildTask = nil
        threadReloadTask = nil
        loadMoreTask = nil
        chipReloadTask = nil
        neighborPrefetchTask = nil

        // Flush while the pool is still open (may write / send).
        if pendingSend != nil {
            await flushPendingSend()
        }

        await DatabaseLifecycle.shutDown(
            tasks: tasks,
            interrupt: { AppDatabase.shared.interrupt() },
            close: { AppDatabase.shared.close() }
        )
    }

    /// Top matches for an address-field token.
    func contactSuggestions(for query: String) -> [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1 else { return [] }
        // Main-thread filter of the in-memory contacts list — if `search.contacts`
        // shows up in perf logs while typing `/`, this is the jank source (not FTS).
        // Call only from onChange / explicit refresh, never from a SwiftUI
        // computed `body` path (that re-runs on every layout pass).
        return PerfMetrics.measure(.searchContacts, meta: "qLen=\(q.count)") {
            ContactMiner.suggestions(from: contacts, matching: q, limit: 6)
        }
    }

    /// A few matching threads for the live search dropdown — FTS over cached
    /// mail, newest first. Async so the per-keystroke lookup runs on a pool
    /// reader instead of blocking the main thread while SQLCipher decrypts.
    /// SQL lives in `ThreadTypeahead` (shared with unit tests).
    func threadSuggestions(for query: String, limit: Int = 5) async -> [MailThread] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= ThreadTypeahead.minimumQueryLength else { return [] }
        return await PerfMetrics.measureAsync(.searchPreview, meta: "qLen=\(q.count)") {
            (try? await db.read { db in
                try ThreadTypeahead.fetch(db: db, query: q, limit: limit)
            }) ?? []
        }
    }

    /// Pin from `openThread`: only the reload generation that was in flight
    /// (or last completed) when the user picked the hit may re-attach it.
    /// A boolean "next reload" flag is wrong — if that reload is cancelled
    /// (new query / view switch), a later unrelated reload would pin a
    /// non-matching thread into its list.
    private var preserveOpenThreadId: String?
    private var preserveOpenThreadGeneration: Int?

    /// Open a specific thread picked from the `/` search panel.
    ///
    /// The reading pane only renders when the id is present in `threads`
    /// (see ContentView.detailPane). Typeahead hits are often outside the
    /// current mailbox page, and `commitSearch` reloads asynchronously — so
    /// we pin the thread into the list immediately rather than flipping to
    /// All Mail (which used to race ContentView's `selectedView` onChange
    /// and clear `selectedThreadId` right after we set it).
    func openThread(_ thread: MailThread) {
        threads = OpenFromSearch.ensuringVisible(opening: thread, in: threads)
        selectedThreadId = thread.id
        // Bind pin to the current reload epoch (commitSearch already bumped
        // this when the panel path commits a query first).
        preserveOpenThreadId = thread.id
        preserveOpenThreadGeneration = threadReloadGeneration
    }

    /// Keep the search results panel mounted briefly after the field blurs.
    /// A click on a result resigns the search field first; if we drop
    /// `searchActive` synchronously the panel is torn down before the row
    /// Button receives the click. Token so a re-focus cancels a pending dismiss.
    private var searchDismissGeneration = 0

    func noteSearchFocused(_ focused: Bool) {
        if focused {
            searchDismissGeneration &+= 1
            searchActive = true
            return
        }
        let generation = searchDismissGeneration
        Task { @MainActor in
            // Yield so the current mouse-up / Button action can run while
            // the panel is still in the hierarchy.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard generation == searchDismissGeneration else { return }
            searchActive = false
        }
    }

    /// Drop the panel immediately (Esc, outside click, completed action).
    func dismissSearchPanel() {
        searchDismissGeneration &+= 1
        searchActive = false
    }

    func client(for accountId: String) -> GmailClient {
        if let c = clients[accountId] { return c }
        let c = GmailClient(accountEmail: accountId)
        clients[accountId] = c
        return c
    }

    /// One-time recompute of derived thread columns after the v2 migration.
    private func rebuildMetadataIfNeeded() {
        let key = "meta.rebuilt.v2"
        guard !UserDefaults.standard.bool(forKey: key), !accounts.isEmpty else { return }
        Task {
            for account in accounts {
                let engine = engines[account.id] ?? SyncEngine(accountId: account.id)
                engines[account.id] = engine
                try? await engine.rebuildAllThreadMetadata()
            }
            UserDefaults.standard.set(true, forKey: key)
            reloadThreads()
        }
    }

    // MARK: - Loading

    /// UserDefaults key for the account switcher's drag-reordered id list.
    /// Local-only (like label order): reauth/reinsert paths never touch this,
    /// so a token refresh or bundle-id migration can't scramble it.
    private static let accountOrderDefaultsKey = "accountOrder"

    func reloadAccounts() {
        let raw = (try? db.read { try Account.order(Column("id")).fetchAll($0) }) ?? []
        let persisted = UserDefaults.standard.stringArray(forKey: Self.accountOrderDefaultsKey) ?? []
        let order = AccountOrder.reconciled(persisted: persisted, live: raw.map(\.id))
        if order != persisted {
            // Reconciliation dropped a removed account or appended a newly
            // added one — persist the settled order so it's stable even if
            // the user never drags again.
            UserDefaults.standard.set(order, forKey: Self.accountOrderDefaultsKey)
        }
        let byId = Dictionary(uniqueKeysWithValues: raw.map { ($0.id, $0) })
        accounts = order.compactMap { byId[$0] }
        // User order first (organizer drag), alphabetical among the unordered.
        let rows = (try? db.read {
            try LabelRow.filter(Column("type") == "user")
                .order(Column("sortOrder"), Column("name")).fetchAll($0)
        }) ?? []
        labelsByAccount = Dictionary(grouping: rows, by: \.accountId)
    }

    func reloadSavedViews() {
        savedViews = (try? db.read { try SavedView.order(Column("name")).fetchAll($0) }) ?? []
    }

    /// Chip toggles arrive in bursts (typing a sender, flipping several
    /// filters); coalesce them into one reload instead of a full 300-thread
    /// query per change. View switches keep calling reloadThreads() directly.
    private var chipReloadTask: Task<Void, Never>?
    /// In-flight list reload; a newer generation discards older results so
    /// chip debounce + view switch races don't clobber fresher state.
    private var threadReloadTask: Task<Void, Never>?
    private var threadReloadGeneration = 0

    func reloadThreadsDebounced() {
        guard !isShuttingDown else { return }
        chipReloadTask?.cancel()
        chipReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            // Chip toggles change the list identity — drop load-more depth.
            self?.resetListWindow()
            self?.reloadThreads()
        }
    }

    /// Async thread-list reload. Captures filter inputs on the main actor,
    /// reads off the critical path (threads + VIP hits + sidebar counts), then
    /// applies only if this generation is still current. Does not clear
    /// `threads` while loading (no flicker).
    ///
    /// Reuses `listWindowLimit` so load-older pages survive sync/star reloads
    /// (view/search changes call `resetListWindow()` first).
    func reloadThreads() {
        guard !isShuttingDown else { return }
        // Message rows may have changed (sync, draft discard, send). Bump
        // before the async list read: the DB write is already committed by
        // the time anyone calls reloadThreads, so the open reading pane can
        // re-query its thread immediately.
        threadContentVersion &+= 1
        chipReloadTask?.cancel()   // a direct reload supersedes a pending debounced one
        loadMoreTask?.cancel()
        loadMoreTask = nil
        threadReloadGeneration += 1
        let generation = threadReloadGeneration
        // Capture everything the query needs up front so the pool read never
        // touches MainActor state mid-flight.
        let view = selectedView
        let search = committedSearch.trimmingCharacters(in: .whitespaces)
        let chips = chips
        let activeAccount = activeAccountId
        if !readStateFilterActive { readStateKeepIds.removeAll() }
        let keepIds = Array(readStateKeepIds)
        let allLabels = labelsByAccount.values.flatMap { $0 }
        let savedViewsSnapshot = savedViews
        let activeVIP = activeVIPEmails
        // Search is single-window; mailbox views keep expanded load-more depth.
        // Probe limit = window + 1 so hasMore is exact (no phantom Load older).
        let windowLimit = search.isEmpty
            ? max(ThreadListPaging.pageSize, listWindowLimit)
            : ThreadListPaging.searchWindowLimit
        let fetchLimit = ThreadListPaging.probeLimit(pageSize: windowLimit)
        let badgeAccount: String? = {
            switch Self.badgeScope {
            case .all: return nil
            case .focused: return activeAccount
            case .account(let id): return id
            }
        }()
        let pool = db

        threadReloadTask?.cancel()
        threadReloadTask = Task { [weak self] in
            struct ReloadPayload {
                var threads: [MailThread]
                var vipHits: Set<String>
                var counts: [String: Int]
                var badge: Int
                var hasMore: Bool
            }
            let reloadKind = search.isEmpty ? "view" : "search"
            let totalInterval = PerfMetrics.begin(.reloadTotal, meta: reloadKind)
            let payload: ReloadPayload? = try? await pool.read { db -> ReloadPayload in
                let result: [MailThread] = try PerfMetrics.measure(
                    .reloadList, meta: "\(reloadKind) limit=\(windowLimit)"
                ) {
                    if !search.isEmpty {
                        let parsed = SearchQuery.parse(search)
                        var q = MailThread.all()
                        if !parsed.text.isEmpty {
                            let ids = try Row.fetchAll(db, sql: """
                                SELECT DISTINCT message.threadId FROM message
                                JOIN message_fts ON message_fts.rowid = message.rowid
                                WHERE message_fts MATCH ?
                                """, arguments: [FTS5Pattern(matchingAllPrefixesIn: parsed.text)])
                                .map { $0["threadId"] as String }
                            q = q.filter(ids.contains(Column("id")))
                        }
                        if let from = parsed.from {
                            // fromDisplay/participants hold display names, so an email
                            // query ("from:x@y.com") must also check the raw header.
                            // Prefer denorm fromEmail when present; still check headers
                            // for threads not yet backfilled.
                            let pattern = "%\(from)%"
                            q = q.filter(sql: """
                                (fromDisplay LIKE ? OR participants LIKE ?
                                 OR fromEmail LIKE ?
                                 OR EXISTS (SELECT 1 FROM message
                                            WHERE message.threadId = thread.id
                                              AND message.fromHeader LIKE ?))
                                """, arguments: [pattern, pattern, pattern, pattern])
                        }
                        if let to = parsed.to {
                            // Recipient headers live on messages, so match via EXISTS.
                            q = q.filter(sql: """
                                EXISTS (SELECT 1 FROM message
                                        WHERE message.threadId = thread.id
                                          AND (message.toHeader LIKE ? OR message.ccHeader LIKE ?
                                               OR message.bccHeader LIKE ?))
                                """, arguments: ["%\(to)%", "%\(to)%", "%\(to)%"])
                        }
                        if let subject = parsed.subject {
                            q = q.filter(sql: "subject LIKE ?", arguments: ["%\(subject)%"])
                        }
                        if let unread = parsed.unread {
                            // keepIds: threads just marked read/unread stay in the
                            // list under is:unread / is:read (same as filter chips).
                            q = q.filter(Column("isUnread") == unread
                                         || keepIds.contains(Column("id")))
                        }
                        if parsed.starred {
                            q = q.filter(Column("isStarred") == true)
                        }
                        if let after = parsed.after {
                            q = q.filter(Column("lastDate") >= after)
                        }
                        if let before = parsed.before {
                            q = q.filter(Column("lastDate") < before)
                        }
                        for name in parsed.labels {
                            // A label name resolves to Gmail label ids (it can exist on
                            // several accounts); unknown names fall back to the raw
                            // token uppercased, which covers system labels (STARRED…).
                            var ids = allLabels
                                .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                                .map(\.gmailLabelId)
                            if ids.isEmpty { ids = [name.uppercased()] }
                            q = MailStore.filterThreads(q, matchingLabelIds: ids)
                        }
                        if parsed.hasAttachment { q = q.filter(Column("hasAttachment") == true) }
                        // Gmail search excludes trash/spam unless in:trash / in:spam /
                        // in:anywhere. Without this, optimistic trash removes the row
                        // and the async reload immediately brings it back.
                        switch parsed.location {
                        case .standard:
                            q = q.filter(Column("inTrash") == false && Column("inSpam") == false)
                        case .trash:
                            q = q.filter(Column("inTrash") == true)
                        case .spam:
                            q = q.filter(Column("inSpam") == true)
                        case .anywhere:
                            break
                        }
                        if let activeAccount { q = q.filter(Column("accountId") == activeAccount) }
                        // Search always ranks by newest message (lastDate).
                        return try q.order(Column("lastDate").desc, Column("id").desc)
                            .limit(fetchLimit).fetchAll(db)
                    } else {
                        var q = MailStore.baseQuery(for: view, savedViews: savedViewsSnapshot, keepIds: keepIds)
                        if chips.showArchived || chips.showSent {
                            // Widen from inbox-only before layering the other chips.
                            q = MailStore.widen(q, for: view, archived: chips.showArchived, sent: chips.showSent)
                        }
                        q = MailStore.applyChips(q, chips, keepIds: keepIds)
                        if let activeAccount { q = q.filter(Column("accountId") == activeAccount) }
                        let inbound = MailStore.usesInboundSort(for: view)
                        let key = ThreadListPaging.sortDateSQL(inboundSort: inbound)
                        return try q.order(sql: "\(key) DESC, id DESC")
                            .limit(fetchLimit).fetchAll(db)
                    }
                }
                let (page, hasMore) = ThreadListPaging.splitPage(result, pageSize: windowLimit)
                let vipHits = try PerfMetrics.measure(.reloadVIP, meta: "n=\(page.count)") {
                    try MailStore.computeVIPThreadIds(
                        threads: page, activeVIP: activeVIP, db: db)
                }
                let (counts, badge) = try PerfMetrics.measure(.reloadCounts) {
                    try MailStore.fetchSidebarCounts(
                        db: db, activeAccount: activeAccount, badgeAccount: badgeAccount)
                }
                return ReloadPayload(threads: page, vipHits: vipHits,
                                     counts: counts, badge: badge, hasMore: hasMore)
            }
            if let payload {
                totalInterval.end(extraMeta: "n=\(payload.threads.count)")
            } else {
                totalInterval.end(extraMeta: "cancelled_or_error")
            }
            guard let payload, !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, generation == self.threadReloadGeneration else { return }
                // Generation-scoped pin: only the reload openThread paired with
                // may re-attach the hit. Superseded reloads clear without pin.
                let list: [MailThread]
                switch OpenFromSearch.pinDecision(
                    pendingThreadId: self.preserveOpenThreadId,
                    pendingGeneration: self.preserveOpenThreadGeneration,
                    completedGeneration: generation,
                    currentSelectedId: self.selectedThreadId
                ) {
                case .apply(let threadId):
                    self.preserveOpenThreadId = nil
                    self.preserveOpenThreadGeneration = nil
                    list = OpenFromSearch.mergingPinned(
                        selectedId: threadId,
                        previous: self.threads,
                        reloaded: payload.threads)
                case .clear:
                    self.preserveOpenThreadId = nil
                    self.preserveOpenThreadGeneration = nil
                    list = payload.threads
                case .ignore:
                    list = payload.threads
                }
                self.threads = list
                // Drop multi-select checks for rows that left the list.
                if !self.checkedThreadIds.isEmpty {
                    let visible = Set(list.map(\.id))
                    self.checkedThreadIds = self.checkedThreadIds.intersection(visible)
                    if let last = self.lastCheckedThreadId, !visible.contains(last) {
                        self.lastCheckedThreadId = nil
                    }
                }
                // Keep expanded window across sync/star reloads; search never pages.
                if search.isEmpty {
                    self.listWindowLimit = max(self.listWindowLimit, list.count)
                    self.hasMoreThreads = payload.hasMore
                } else {
                    self.hasMoreThreads = false
                }
                let inbound = MailStore.usesInboundSort(for: self.selectedView)
                self.listCursor = ThreadListPaging.nextCursor(
                    after: list, inboundSort: inbound)
                self.vipThreadIds = payload.vipHits
                // Local sidebar counts only: they use the same denorm filters as
                // the visible lists (inbox/promotions/social exclude spam, and
                // category tabs require inInbox). Gmail's CATEGORY_* label
                // totals include spam + archived and would disagree with the list.
                self.unreadCounts = payload.counts
                Notifier.setBadge(payload.badge)
                self.loadAICategories()
            }
        }
    }

    /// Bumped whenever thread/message rows were reloaded from the DB (every
    /// sync and local mutation funnels through `reloadThreads`). The open
    /// reading pane keys off this to refresh its message list in place —
    /// e.g. a discarded draft's card disappears without reopening the thread.
    @Published private(set) var threadContentVersion = 0
    /// Whether the current list window may have older rows past the loaded depth.
    @Published private(set) var hasMoreThreads = false
    @Published private(set) var isLoadingMore = false
    /// Cursor after the last loaded thread (for `loadMoreThreads`).
    private var listCursor: ThreadListCursor?
    private var loadMoreTask: Task<Void, Never>?
    /// Identifies the in-flight load-more so a cancelled task cannot nil a newer one.
    private var loadMoreToken = UUID()
    /// How many rows to re-fetch on reload so load-older survives star/sync.
    private var listWindowLimit = ThreadListPaging.pageSize

    /// Call when the list identity changes (view, search, chips base).
    private func resetListWindow() {
        listWindowLimit = ThreadListPaging.pageSize
        listCursor = nil
        hasMoreThreads = false
        loadMoreTask?.cancel()
        loadMoreTask = nil
        loadMoreToken = UUID()
        // The cancelled task's defer is token-guarded and won't clear this.
        isLoadingMore = false
    }

    /// Append the next page of threads older than the current window.
    /// No-op when `hasMoreThreads` is false, search is active, or a load is in flight.
    func loadMoreThreads() {
        guard !isShuttingDown else { return }
        let search = committedSearch.trimmingCharacters(in: .whitespaces)
        guard search.isEmpty, hasMoreThreads, let cursor = listCursor, loadMoreTask == nil else { return }
        let generation = threadReloadGeneration
        let token = UUID()
        loadMoreToken = token
        let view = selectedView
        let chips = chips
        let activeAccount = activeAccountId
        let keepIds = Array(readStateKeepIds)
        let savedViewsSnapshot = savedViews
        let activeVIP = activeVIPEmails
        let pool = db
        isLoadingMore = true
        loadMoreTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    guard let self, self.loadMoreToken == token else { return }
                    self.loadMoreTask = nil
                    self.isLoadingMore = false
                }
            }
            let split: (page: [MailThread], hasMore: Bool)? = try? await PerfMetrics.measureAsync(
                .pageLoadMore, meta: "probe"
            ) {
                try await pool.read { db -> (page: [MailThread], hasMore: Bool) in
                    var q = MailStore.baseQuery(for: view, savedViews: savedViewsSnapshot, keepIds: keepIds)
                    if chips.showArchived || chips.showSent {
                        q = MailStore.widen(q, for: view, archived: chips.showArchived, sent: chips.showSent)
                    }
                    q = MailStore.applyChips(q, chips, keepIds: keepIds)
                    if let activeAccount { q = q.filter(Column("accountId") == activeAccount) }
                    let inbound = MailStore.usesInboundSort(for: view)
                    let key = ThreadListPaging.sortDateSQL(inboundSort: inbound)
                    q = q.filter(sql: ThreadListPaging.olderThanSQL(inboundSort: inbound),
                                 arguments: [cursor.sortDate, cursor.sortDate, cursor.id])
                    let rows = try q.order(sql: "\(key) DESC, id DESC")
                        .limit(ThreadListPaging.probeLimit()).fetchAll(db)
                    return ThreadListPaging.splitPage(rows)
                }
            }
            guard let split, !split.page.isEmpty else {
                await MainActor.run {
                    guard let self, generation == self.threadReloadGeneration else { return }
                    self.hasMoreThreads = false
                }
                return
            }
            let page = split.page
            let vipHits = (try? await pool.read { db in
                try MailStore.computeVIPThreadIds(threads: page, activeVIP: activeVIP, db: db)
            }) ?? []
            await MainActor.run {
                guard let self,
                      generation == self.threadReloadGeneration,
                      !Task.isCancelled else { return }
                // Dedupe if a concurrent reload already included some rows.
                let existing = Set(self.threads.map(\.id))
                let fresh = page.filter { !existing.contains($0.id) }
                self.threads.append(contentsOf: fresh)
                self.vipThreadIds.formUnion(vipHits)
                self.listWindowLimit = max(self.listWindowLimit, self.threads.count)
                self.hasMoreThreads = split.hasMore
                let inbound = MailStore.usesInboundSort(for: self.selectedView)
                self.listCursor = ThreadListPaging.nextCursor(
                    after: self.threads, inboundSort: inbound)
            }
        }
    }

    /// Inbox-style views sort by last *inbound* so own replies don't reshuffle.
    nonisolated static func usesInboundSort(for view: MailboxView) -> Bool {
        switch view {
        case .inbox, .promotions, .social, .account: return true
        default: return false
        }
    }

    // MARK: - Server-side search

    @Published var serverSearching = false

    /// Local search only covers cached mail (within the sync window). This
    /// pulls matching messages straight from Gmail so a search can reach older
    /// mail, then reloads. Gmail's query syntax matches the app's operators, so
    /// the raw search text is passed through as the query.
    func searchAllGmail() {
        let query = committedSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !serverSearching else { return }
        serverSearching = true
        syncStatus = "Searching all mail…"
        let targets = activeAccountId.map { [$0] } ?? accounts.map(\.id)
        Task {
            for accountId in targets {
                let engine = engines[accountId] ?? SyncEngine(accountId: accountId)
                engines[accountId] = engine
                do {
                    try await engine.searchServer(query: query)
                } catch {
                    await MainActor.run { self.lastError = error.localizedDescription }
                }
            }
            await MainActor.run {
                serverSearching = false
                syncStatus = ""
                reloadThreads()
                rebuildContacts()
            }
        }
    }

    /// Layers the full FilterChips set onto a thread query. Shared by the live
    /// filter bar and by saved views (so "Save as view" is lossless). Does NOT
    /// apply the archived/sent *widening* (that's view-dependent) or account
    /// scoping (applied by the caller).
    /// `keepIds` are threads that must stay visible even if they no longer match
    /// the read-state chip (e.g. a thread you just marked read under an
    /// unread-only filter), so the row doesn't vanish under your cursor.
    // nonisolated: pure query builder — safe to call from DatabasePool.read.
    nonisolated static func applyChips(_ query: QueryInterfaceRequest<MailThread>, _ chips: FilterChips,
                           keepIds: [String] = []) -> QueryInterfaceRequest<MailThread> {
        var q = query
        for cat in chips.category.hide {
            // Prefer denorm flags for the two categories that have them.
            switch cat {
            case "CATEGORY_PROMOTIONS": q = q.filter(Column("inPromotions") == false)
            case "CATEGORY_SOCIAL": q = q.filter(Column("inSocial") == false)
            default: q = q.filter(!Column("labelIds").like("%\(cat)%"))
            }
        }
        if !chips.category.show.isEmpty {
            // Contains any of the selected categories. Denorm for promo/social;
            // labelIds LIKE for Updates/Forums (no denorm columns yet).
            // Spam is never a category tab — keep SPAM out of promo/social chips.
            var parts: [String] = []
            var args: [any DatabaseValueConvertible] = []
            var needsNotSpam = false
            for cat in chips.category.show {
                switch cat {
                case "CATEGORY_PROMOTIONS":
                    parts.append("inPromotions = 1")
                    needsNotSpam = true
                case "CATEGORY_SOCIAL":
                    parts.append("inSocial = 1")
                    needsNotSpam = true
                default:
                    parts.append("labelIds LIKE ?")
                    args.append("%\(cat)%")
                }
            }
            q = q.filter(sql: parts.joined(separator: " OR "),
                         arguments: StatementArguments(args))
            if needsNotSpam { q = q.filter(Column("inSpam") == false) }
        }
        if chips.unreadOnly { q = q.filter(Column("isUnread") == true || keepIds.contains(Column("id"))) }
        if chips.readOnly { q = q.filter(Column("isUnread") == false || keepIds.contains(Column("id"))) }
        if let labelId = chips.labelId {
            if chips.labelExclude {
                if labelId.hasPrefix("Label_") {
                    q = q.filter(sql: """
                        NOT EXISTS (SELECT 1 FROM thread_label
                                    WHERE threadId = thread.id AND labelId = ?)
                        """, arguments: [labelId])
                } else {
                    q = q.filter(!Column("labelIds").like("%\(labelId)%"))
                }
            } else {
                q = filterThreads(q, matchingLabelIds: [labelId])
            }
        }
        if chips.hasAttachmentOnly { q = q.filter(Column("hasAttachment") == true) }
        if chips.noAttachmentOnly { q = q.filter(Column("hasAttachment") == false) }
        if !chips.senderContains.isEmpty {
            let pattern = "%\(chips.senderContains)%"
            let condition = "(fromDisplay LIKE ? OR participants LIKE ?)"
            q = q.filter(sql: chips.senderExclude ? "NOT \(condition)" : condition,
                         arguments: [pattern, pattern])
        }
        if let sender = chips.fromEmailContains, !sender.isEmpty {
            // Prefer denorm fromEmail; fall back to message headers for empty rows.
            q = q.filter(sql: """
                (fromEmail LIKE ?
                 OR (fromEmail = '' AND EXISTS (
                        SELECT 1 FROM message
                        WHERE message.threadId = thread.id AND message.fromHeader LIKE ?)))
                """, arguments: ["%\(sender)%", "%\(sender)%"])
        }
        for (header, value) in [("toHeader", chips.toContains),
                                ("ccHeader", chips.ccContains),
                                ("bccHeader", chips.bccContains)] where !value.isEmpty {
            q = q.filter(sql: """
                EXISTS (SELECT 1 FROM message
                        WHERE message.threadId = thread.id AND message.\(header) LIKE ?)
                """, arguments: ["%\(value)%"])
        }
        if !chips.subjectContains.isEmpty {
            q = q.filter(sql: "subject LIKE ?", arguments: ["%\(chips.subjectContains)%"])
        }
        if let window = chips.dateWindow {
            let cutoff = Calendar.current.startOfDay(
                for: Date().addingTimeInterval(Double(-(window.rawValue - 1)) * 86400))
            q = q.filter(Column("lastDate") >= cutoff)
        }
        if chips.calendarOnly || chips.hideCalendar {
            let invite = """
                EXISTS (SELECT 1 FROM message
                        JOIN attachment ON attachment.messageId = message.id
                        WHERE message.threadId = thread.id
                          AND (attachment.mimeType LIKE 'text/calendar%'
                               OR attachment.filename LIKE '%.ics'))
                """
            if chips.calendarOnly { q = q.filter(sql: invite) }
            if chips.hideCalendar { q = q.filter(sql: "NOT \(invite)") }
        }
        return q
    }

    nonisolated private static func baseQuery(for view: MailboxView, savedViews: [SavedView],
                                  keepIds: [String] = []) -> QueryInterfaceRequest<MailThread> {
        var q = MailThread.all()
        let now = Date()
        func notSnoozed(_ q: QueryInterfaceRequest<MailThread>) -> QueryInterfaceRequest<MailThread> {
            q.filter(Column("snoozeUntil") == nil || Column("snoozeUntil") <= now)
        }
        switch view {
        case .inbox:
            // Category filtering is handled by the Categories chip.
            q = notSnoozed(q.filter(Column("inInbox") == true && Column("inTrash") == false))
        case .promotions:
            // Match gmail.com's Promotions tab: in-inbox category mail, never spam.
            q = q.filter(Column("inTrash") == false
                         && Column("inSpam") == false
                         && Column("inInbox") == true
                         && Column("inPromotions") == true)
        case .social:
            q = q.filter(Column("inTrash") == false
                         && Column("inSpam") == false
                         && Column("inInbox") == true
                         && Column("inSocial") == true)
        case .starred:
            q = q.filter(Column("isStarred") == true && Column("inTrash") == false)
        case .snoozed:
            q = q.filter(Column("snoozeUntil") != nil && Column("snoozeUntil") > now && Column("inTrash") == false)
        case .labels:
            // Any user label via junction (Label_*); system labels never match.
            q = q.filter(sql: """
                inTrash = 0 AND EXISTS (
                    SELECT 1 FROM thread_label WHERE thread_label.threadId = thread.id)
                """)
        case .reminders:
            q = q.filter(Column("reminderAt") != nil)
        case .drafts:
            q = q.filter(Column("inDrafts") == true && Column("inTrash") == false)
        case .scheduled:
            // Scheduled sends aren't threads; ScheduledListView renders them.
            q = q.none()
        case .sent:
            q = q.filter(Column("inSent") == true && Column("inTrash") == false)
        case .allMail:
            q = q.filter(Column("inTrash") == false)
        case .trash:
            q = q.filter(Column("inTrash") == true)
        case .account(let a):
            q = notSnoozed(q.filter(Column("accountId") == a && Column("inInbox") == true && Column("inTrash") == false))
        case .label(let a, let labelId, _):
            q = q.filter(Column("accountId") == a)
            q = filterThreads(q, matchingLabelIds: [labelId])
        case .saved(let id, _):
            guard let v = savedViews.first(where: { $0.id == id }) else { break }
            q = q.filter(Column("inTrash") == false)
            // Lossless path: a "Save as view" snapshot carries the full chip
            // set as JSON. Apply the base (inbox unless archived) + account
            // scope, then layer every chip dimension via the shared helper.
            if let chips = v.chipsJSON.flatMap({ try? JSONDecoder().decode(FilterChips.self, from: $0) }) {
                if !chips.showArchived { q = notSnoozed(q.filter(Column("inInbox") == true)) }
                if let a = v.accountId { q = q.filter(Column("accountId") == a) }
                if v.starredOnly { q = q.filter(Column("isStarred") == true) }
                q = applyChips(q, chips, keepIds: keepIds)
                break
            }
            // Legacy path: views built in the ViewEditor form (structured fields).
            if !v.showArchived { q = notSnoozed(q.filter(Column("inInbox") == true)) }
            if let a = v.accountId { q = q.filter(Column("accountId") == a) }
            if let label = v.labelId { q = filterThreads(q, matchingLabelIds: [label]) }
            if v.unreadOnly { q = q.filter(Column("isUnread") == true || keepIds.contains(Column("id"))) }
            if v.starredOnly { q = q.filter(Column("isStarred") == true) }
            if v.hasAttachmentOnly { q = q.filter(Column("hasAttachment") == true) }
            if !v.senderContains.isEmpty {
                q = q.filter(Column("fromDisplay").like("%\(v.senderContains)%")
                             || Column("participants").like("%\(v.senderContains)%"))
            }
            if v.excludePromotions {
                q = q.filter(Column("inPromotions") == false && Column("inSocial") == false)
            }
            if let cat = v.category {
                switch cat {
                case "CATEGORY_PROMOTIONS":
                    q = q.filter(Column("inPromotions") == true && Column("inSpam") == false)
                case "CATEGORY_SOCIAL":
                    q = q.filter(Column("inSocial") == true && Column("inSpam") == false)
                default: q = q.filter(Column("labelIds").like("%\(cat)%"))
                }
            }
        }
        return q
    }

    /// Match threads that have any of `labelIds`. User labels (`Label_*`) use
    /// the `thread_label` junction; system / category labels keep LIKE / denorm.
    nonisolated static func filterThreads(
        _ q: QueryInterfaceRequest<MailThread>,
        matchingLabelIds ids: [String]
    ) -> QueryInterfaceRequest<MailThread> {
        guard !ids.isEmpty else { return q }
        let user = ids.filter { $0.hasPrefix("Label_") }
        let system = ids.filter { !$0.hasPrefix("Label_") }
        var parts: [String] = []
        var args: [any DatabaseValueConvertible] = []
        if !user.isEmpty {
            let ors = user.map { _ in
                "EXISTS (SELECT 1 FROM thread_label WHERE threadId = thread.id AND labelId = ?)"
            }.joined(separator: " OR ")
            parts.append("(\(ors))")
            args.append(contentsOf: user)
        }
        for s in system {
            switch s {
            case "STARRED": parts.append("isStarred = 1")
            case "INBOX": parts.append("inInbox = 1")
            case "TRASH": parts.append("inTrash = 1")
            case "SENT": parts.append("inSent = 1")
            case "DRAFT": parts.append("inDrafts = 1")
            case "SPAM": parts.append("inSpam = 1")
            case "CATEGORY_PROMOTIONS": parts.append("inPromotions = 1")
            case "CATEGORY_SOCIAL": parts.append("inSocial = 1")
            default:
                parts.append("labelIds LIKE ?")
                args.append("%\(s)%")
            }
        }
        guard !parts.isEmpty else { return q }
        return q.filter(sql: "(\(parts.joined(separator: " OR ")))",
                        arguments: StatementArguments(args))
    }

    nonisolated private static func widen(_ q: QueryInterfaceRequest<MailThread>, for view: MailboxView,
                              archived: Bool, sent: Bool) -> QueryInterfaceRequest<MailThread> {
        // Rebuild without the inbox constraint for views where it applies.
        // "Show archived" widens to everything not trashed; "Show sent" alone
        // widens to inbox-or-sent. (Category chips are layered on afterwards.)
        func widened(_ w: QueryInterfaceRequest<MailThread>) -> QueryInterfaceRequest<MailThread> {
            if archived { return w }
            return w.filter(Column("inInbox") == true || Column("inSent") == true)
        }
        switch view {
        case .inbox:
            return widened(MailThread.filter(Column("inTrash") == false))
        case .account(let a):
            return widened(MailThread.filter(Column("accountId") == a && Column("inTrash") == false))
        default:
            return q
        }
    }

    /// What the dock badge counts. Stored in UserDefaults ("badgeScope"):
    /// every account, the inbox currently focused in the sidebar, or one
    /// specific account ("account:<email>").
    enum BadgeScope: RawRepresentable, Hashable {
        case all
        case focused
        case account(String)

        init?(rawValue: String) {
            switch rawValue {
            case "all": self = .all
            case "focused": self = .focused
            default:
                guard rawValue.hasPrefix("account:") else { return nil }
                self = .account(String(rawValue.dropFirst("account:".count)))
            }
        }

        var rawValue: String {
            switch self {
            case .all: return "all"
            case .focused: return "focused"
            case .account(let id): return "account:\(id)"
            }
        }
    }

    static var badgeScope: BadgeScope {
        get {
            UserDefaults.standard.string(forKey: "badgeScope")
                .flatMap(BadgeScope.init(rawValue:)) ?? .all
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "badgeScope") }
    }

    /// Recompute the sidebar counts and dock badge (e.g. after the badge
    /// scope changes in Settings).
    func refreshBadge() { refreshCountsAndBadge() }

    private func refreshCountsAndBadge() {
        // Local counts (fallback + reminders, which Gmail doesn't know about).
        // Single aggregate SQL — same helper used off-main in reloadThreads.
        let activeAccount = activeAccountId
        // The account the badge counts: nil = every account. "Focused"
        // follows the sidebar (unified view = every account).
        let badgeAccount: String? = {
            switch Self.badgeScope {
            case .all: return nil
            case .focused: return activeAccount
            case .account(let id): return id
            }
        }()
        let (local, badgeTotal): ([String: Int], Int) = (try? db.read { db in
            try Self.fetchSidebarCounts(db: db, activeAccount: activeAccount,
                                        badgeAccount: badgeAccount)
        }) ?? ([:], 0)

        // Local counts only — same denorm filters as the visible lists
        // (spam excluded; promotions/social require inInbox). Gmail CATEGORY_*
        // label totals include spam/archived and would disagree with the list.
        unreadCounts = local
        Notifier.setBadge(badgeTotal)
    }

    /// Sidebar counts + dock badge. Delegates to `SidebarCounts` (shared with
    /// unit tests). Safe off MainActor.
    nonisolated static func fetchSidebarCounts(
        db: Database,
        activeAccount: String?,
        badgeAccount: String?,
        now: Date = Date()
    ) throws -> (counts: [String: Int], badge: Int) {
        try SidebarCounts.fetch(db: db, activeAccount: activeAccount,
                                badgeAccount: badgeAccount, now: now)
    }

    /// Full messages including bodies — used by compose / reply / forward.
    func messages(inThread threadId: String) -> [Message] {
        (try? db.read { db in
            let headers = try Message
                .filter(Column("threadId") == threadId)
                .order(Column("date"))
                .fetchAll(db)
            return try Self.hydrateBodies(headers, db: db)
        }) ?? []
    }

    /// Headers + snippet only (empty body fields). Cheap open path for the
    /// reading pane; hydrate bodies with `messageBody(id:)` on expand.
    func messageHeaders(inThread threadId: String) -> [Message] {
        PerfMetrics.measure(.openHeaders) {
            (try? db.read { db in
                try Message.fetchAll(
                    db,
                    sql: """
                        SELECT id, accountId, gmailId, threadId, fromHeader, toHeader, ccHeader,
                               bccHeader, subject, date, snippet,
                               '' AS bodyText, NULL AS bodyHTML,
                               messageIdHeader, referencesHeader, labelIds, isUnread, hasAttachment
                        FROM message
                        WHERE threadId = ?
                        ORDER BY date
                        """,
                    arguments: [threadId]
                )
            }) ?? []
        }
    }

    /// One message with full body fields (from `message_body` when present).
    func messageBody(id: String) -> Message? {
        PerfMetrics.measure(.openBody, meta: "single") {
            (try? db.read { db -> Message? in
                guard var msg = try Message.filter(Column("id") == id).fetchOne(db) else {
                    return nil
                }
                if let body = try MessageBody.fetchOne(db, key: id) {
                    msg.bodyText = body.bodyText
                    msg.bodyHTML = body.bodyHTML
                }
                return msg
            }) ?? nil
        }
    }

    /// Load bodies for specific message ids, preserving the order of `ids`.
    func messagesWithBodies(ids: [String]) -> [Message] {
        guard !ids.isEmpty else { return [] }
        return PerfMetrics.measure(.openBody, meta: "n=\(ids.count)") {
            (try? db.read { db in
                let fetched = try Message.filter(ids.contains(Column("id"))).fetchAll(db)
                let hydrated = try Self.hydrateBodies(fetched, db: db)
                let byId = Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, $0) })
                return ids.compactMap { byId[$0] }
            }) ?? []
        }
    }

    nonisolated private static func hydrateBodies(_ messages: [Message], db: Database) throws -> [Message] {
        guard !messages.isEmpty else { return [] }
        let ids = messages.map(\.id)
        let bodies = try MessageBody.filter(ids.contains(Column("messageId"))).fetchAll(db)
        let byId = Dictionary(uniqueKeysWithValues: bodies.map { ($0.messageId, $0) })
        return messages.map { msg in
            var m = msg
            if let b = byId[msg.id] {
                m.bodyText = b.bodyText
                m.bodyHTML = b.bodyHTML
            }
            return m
        }
    }

    func attachments(for messageId: String) -> [AttachmentRow] {
        (try? db.read {
            try AttachmentRow.filter(Column("messageId") == messageId).fetchAll($0)
        }) ?? []
    }

    // MARK: - Saved views

    func saveView(_ view: SavedView) {
        var v = view
        // If this is a lossless (chips-backed) view, fold any edits made to the
        // ViewEditor's structured fields back into the JSON so chipsJSON stays
        // authoritative and form edits still take effect.
        if var chips = v.chipsJSON.flatMap({ try? JSONDecoder().decode(FilterChips.self, from: $0) }) {
            chips.labelId = v.labelId
            chips.unreadOnly = v.unreadOnly
            chips.showArchived = v.showArchived
            chips.hasAttachmentOnly = v.hasAttachmentOnly
            chips.senderContains = v.senderContains
            if v.excludePromotions {
                chips.category.hide.formUnion(["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"])
            }
            if let cat = v.category { chips.category.show = [cat] }
            v.chipsJSON = try? JSONEncoder().encode(chips)
        }
        try? db.write { db in
            let toSave = v
            try toSave.save(db)
        }
        reloadSavedViews()
    }

    /// Notion Mail-style "Split from Inbox": a new saved view holding all
    /// mail whose From header matches `sender` (an address, or "@domain"),
    /// then jump straight into it.
    func splitFromInbox(matching sender: String, named name: String) {
        var chips = FilterChips()
        chips.fromEmailContains = sender
        chips.showArchived = true   // the view is their full history, not inbox-only
        var view = SavedView.empty()
        view.name = name
        view.showArchived = true    // saveView folds this back into the chips
        view.chipsJSON = try? JSONEncoder().encode(chips)
        saveView(view)
        if let saved = savedViews.last(where: { $0.name == name }), let id = saved.id {
            selectedView = .saved(id, name)
        }
        showNotice("New view: \(name)")
    }

    func deleteView(_ view: SavedView) {
        guard let id = view.id else { return }
        try? db.write { db in _ = try SavedView.deleteOne(db, key: id) }
        if case .saved(let selectedId, _) = selectedView, selectedId == id {
            selectedView = .inbox
        }
        reloadSavedViews()
    }

    // MARK: - Account lifecycle

    func addAccount(reauthorizing hint: String? = nil) {
        Task {
            do {
                let (refresh, access) = try await OAuthService().signIn(loginHint: hint)
                var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
                req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                struct UserInfo: Decodable { let email: String; let name: String? }
                let (data, _) = try await URLSession.shared.data(for: req)
                let info = try JSONDecoder().decode(UserInfo.self, from: data)

                // A successful connection replaces the fictional mailbox.
                // Exit only after OAuth succeeds, so cancelling sign-in leaves
                // the user's demo session intact.
                guard !demoMode || exitDemoMode() else { return }

                try Keychain.set(refresh, forKey: "refreshToken.\(info.email)")
                try await db.write { db in
                    if var existing = try Account.fetchOne(db, key: info.email) {
                        // Reauthorizing an existing account must only replace
                        // its refresh token. Preserve the history cursor and
                        // last-sync timestamp so a bundle-id migration (or a
                        // revoked token) does not trigger a full mailbox
                        // backfill and burn through Gmail's per-user quota.
                        if existing.displayName == existing.id,
                           let name = info.name, !name.isEmpty {
                            existing.displayName = name
                        }
                        if existing.senderName.isEmpty {
                            existing.senderName = info.name ?? ""
                        }
                        try existing.update(db)
                    } else {
                        let account = Account(
                            id: info.email,
                            displayName: info.name ?? info.email,
                            historyId: nil,
                            lastSyncAt: nil,
                            senderName: info.name ?? ""
                        )
                        try account.insert(db)
                    }
                }
                accountsNeedingReauth.remove(info.email)
                reloadAccounts()
                await refreshSendIdentities(accountId: info.email)
                await sync(accountId: info.email)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeAccount(_ id: String) {
        if demoMode, id == DemoSeed.account {
            _ = exitDemoMode()
            return
        }
        Keychain.delete("refreshToken.\(id)")
        try? db.write { db in _ = try Account.deleteOne(db, key: id) }
        engines[id] = nil
        clients[id] = nil
        accountsNeedingReauth.remove(id)
        reloadAccounts()
        sendIdentities.removeAll { $0.accountId == id }
        reloadThreads()
        // Own-address set changed — drop the weight map and re-mine.
        rebuildContacts(forceFull: true)
    }

    /// True when `error` means the account's saved sign-in was rejected by
    /// Google and only reauthorizing (not a retry) can fix it.
    private static func isReauthRequired(_ error: Error) -> Bool {
        switch error {
        case OAuthError.invalidGrant: return true
        case GmailError.noRefreshToken: return true
        default: return false
        }
    }

    private func requireReauthorization(for accountID: String) {
        accountsNeedingReauth.insert(accountID)
        presentedError = ErrorRecovery.reauthorizationRequired(for: accountID)
    }

    // MARK: - Sync

    func startPolling() {
        // Demo mode has no real account and no token; polling would only spin
        // up failed syncs and error banners over the screenshot fixtures.
        if demoMode { return }
        guard !isShuttingDown else { return }
        fireDueSnoozes()  // catch snoozes that came due while the app was closed
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShuttingDown else { return }
                await self.syncAll()
                self.fireDueReminders()
                self.fireDueSnoozes()
                // Backstop for the one-shot timer (sleep/wake can eat it).
                await self.fireDueScheduledSends()
            }
        }
    }

    /// Sync every account with true parallelism at the SyncEngine layer
    /// (each engine is an independent actor). MainActor work — reload,
    /// blocklist, contacts — runs once at the end.
    func syncAll() async {
        guard !demoMode else {
            syncStatus = ""
            showNotice("Demo inbox is offline")
            return
        }
        guard !isShuttingDown else { return }
        let ids = accounts.map(\.id)
        guard !ids.isEmpty else {
            applyBlocklist()
            notifyNewMail()
            rebuildContacts()
            autoClassifyNewMail()
            return
        }
        for id in ids where engines[id] == nil {
            engines[id] = SyncEngine(accountId: id)
        }
        // Capture engine refs before leaving MainActor for the task group.
        let pairs: [(String, SyncEngine)] = ids.compactMap { id in
            engines[id].map { (id, $0) }
        }
        syncStatus = ids.count == 1
            ? "Syncing \(ids[0])…"
            : "Syncing \(ids.count) accounts…"

        await withTaskGroup(of: (String, Error?).self) { group in
            for (id, engine) in pairs {
                group.addTask {
                    do {
                        try await engine.syncNow { status in
                            Task { @MainActor [weak self] in self?.syncStatus = status }
                        }
                        return (id, nil)
                    } catch {
                        return (id, error)
                    }
                }
            }
            for await (id, error) in group {
                if let error {
                    if Self.isReauthRequired(error) {
                        requireReauthorization(for: id)
                    } else if case GmailError.partialFetch = error {
                        // Soft: historyId not advanced; next sync retries.
                        // Still run post-sync so successful upserts appear.
                        accountsNeedingReauth.remove(id)
                        await backfillSenderNameIfNeeded(accountId: id)
                        await refreshSendIdentities(accountId: id)
                    } else {
                        lastError = "\(id): \(error.localizedDescription)"
                    }
                } else {
                    accountsNeedingReauth.remove(id)
                    await backfillSenderNameIfNeeded(accountId: id)
                    await refreshSendIdentities(accountId: id)
                }
            }
        }
        syncStatus = ""
        reloadAccounts()
        reloadThreads()  // once for all accounts, not once per account
        applyBlocklist()
        notifyNewMail()
        rebuildContacts()
        autoClassifyNewMail()
    }

    func sync(accountId: String) async {
        guard !demoMode else {
            syncStatus = ""
            return
        }
        let engine = engines[accountId] ?? SyncEngine(accountId: accountId)
        engines[accountId] = engine
        syncStatus = "Syncing \(accountId)…"
        do {
            try await engine.syncNow { status in
                Task { @MainActor [weak self] in self?.syncStatus = status }
            }
            syncStatus = ""
            accountsNeedingReauth.remove(accountId)
            await backfillSenderNameIfNeeded(accountId: accountId)
            await refreshSendIdentities(accountId: accountId)
            reloadAccounts()
            reloadThreads()
        } catch {
            syncStatus = ""
            if Self.isReauthRequired(error) {
                requireReauthorization(for: accountId)
            } else if case GmailError.partialFetch = error {
                // Soft: apply what we got; historyId stays put for retry.
                accountsNeedingReauth.remove(accountId)
                await backfillSenderNameIfNeeded(accountId: accountId)
                await refreshSendIdentities(accountId: accountId)
                reloadAccounts()
                reloadThreads()
            } else {
                lastError = "\(accountId): \(error.localizedDescription)"
            }
        }
    }

    /// Accounts added before senderName existed get it from the profile.
    private func backfillSenderNameIfNeeded(accountId: String) async {
        guard var account = accounts.first(where: { $0.id == accountId }),
              account.senderName.isEmpty,
              let name = try? await client(for: accountId).userName(),
              !name.isEmpty else { return }
        account.senderName = name
        let updated = account
        try? await db.write { db in try updated.update(db) }
    }

    /// RFC 2822 From value for a mailbox primary (legacy call sites / new
    /// mail default). Prefer `fromHeader(accountId:fromEmail:)` when a
    /// send-as identity may be selected.
    func fromHeader(for accountId: String) -> String {
        fromHeader(accountId: accountId, fromEmail: accountId)
    }

    /// RFC 2822 From for a chosen identity. Uses the send-as display name
    /// when present; falls back to the account's senderName for primaries.
    func fromHeader(accountId: String, fromEmail: String) -> String {
        let email = fromEmail.isEmpty ? accountId : fromEmail
        if let identity = SendIdentityResolver.identity(
            email: email, inMailbox: accountId, from: sendIdentities) {
            return identity.fromHeader
        }
        // Identity list not loaded yet, or email is the primary: use the
        // account's senderName when we have one (covers send-as scheduled
        // sends that fire before refreshSendIdentities finishes).
        if let account = accounts.first(where: { $0.id == accountId }),
           !account.senderName.isEmpty {
            return "\(account.senderName) <\(email)>"
        }
        return email
    }

    // MARK: - New-mail notifications

    private func currentUnreadInboxIds() -> Set<String> {
        Set((try? db.read { db -> [String] in
            // Prefer denormalized category flags when present (schema v11+).
            try MailThread
                .filter(Column("isUnread") == true)
                .filter(Column("inInbox") == true)
                .filter(Column("inTrash") == false)
                .filter(Column("inSpam") == false)
                .filter(Column("inPromotions") == false)
                .filter(Column("inSocial") == false)
                .fetchAll(db).map(\.id)
        }) ?? [])
    }

    private func notifyNewMail() {
        let current = currentUnreadInboxIds()
        let fresh = current.subtracting(notifiedThreadIds)
        notifiedThreadIds.formUnion(current)
        knownUnreadInboxIds = current
        guard !fresh.isEmpty else { return }
        let newThreads = (try? db.read { db in
            try MailThread.filter(fresh.contains(Column("id"))).order(Column("lastDate").desc).fetchAll(db)
        }) ?? []
        for thread in newThreads.prefix(3) {
            Notifier.notify(title: thread.fromDisplay,
                            body: thread.subject.isEmpty ? thread.snippet : thread.subject,
                            id: "mail.\(thread.id)")
        }
        if newThreads.count > 3 {
            Notifier.notify(title: "MishMail", body: "\(newThreads.count) new messages", id: "mail.batch")
        }
    }

    // MARK: - Reminders

    func setReminder(_ thread: MailThread, after days: Int?) {
        var copy = thread
        let when = days.map { Calendar.current.date(byAdding: .day, value: $0, to: Date())! }
        copy.reminderAt = when
        // Snapshot the thread's current activity so the reminder can cancel
        // itself if a newer message arrives ("remind if no reply").
        copy.reminderSetAt = when == nil ? nil : Date()
        let updated = copy
        try? db.write { db in try updated.save(db) }
        reloadThreads()
    }

    private func fireDueReminders() {
        let due = (try? db.read { db in
            try MailThread.filter(Column("reminderAt") != nil && Column("reminderAt") <= Date()).fetchAll(db)
        }) ?? []
        var changed = false
        for thread in due {
            changed = true
            var copy = thread
            copy.reminderAt = nil
            copy.reminderSetAt = nil
            // "Remind if no reply": only *inbound* activity cancels the nudge.
            // Own follow-ups update lastDate but leave lastInboundDate alone
            // (or nil for pure-outbound threads), so they don't look like a reply.
            let replied = thread.reminderSetAt.flatMap { setAt in
                thread.lastInboundDate.map { $0 > setAt }
            } ?? false
            if !replied {
                Notifier.notify(title: "Follow up: \(thread.fromDisplay)",
                                body: thread.subject.isEmpty ? thread.snippet : thread.subject,
                                id: "reminder.\(thread.id)")
            }
            let updated = copy
            try? db.write { db in try updated.save(db) }
        }
        if changed { reloadThreads() }
    }

    // MARK: - Keyboard shortcuts

    private var pendingGoKey: Date?

    /// Returns true if the key was handled. Gmail-style single keys,
    /// including "g then …" navigation (g-i inbox, g-t sent, g-d drafts…).
    func handleKey(_ chars: String) -> Bool {
        if let started = pendingGoKey, Date().timeIntervalSince(started) < 1.5 {
            pendingGoKey = nil
            switch chars {
            case "i": goTo(.inbox); return true
            case "s": goTo(.starred); return true
            case "t": goTo(.sent); return true
            case "d": goTo(.drafts); return true
            case "a": goTo(.allMail); return true
            case "p": goTo(.promotions); return true
            default: break   // fall through to normal handling
            }
        }
        switch chars {
        case "g": pendingGoKey = Date(); return true
        case "?": showShortcutsHelp.toggle(); return true
        default: break
        }
        guard let command = keyBindings.command(for: chars) else { return false }
        perform(command)
        return true
    }

    /// Runs a rebindable single-key command. Kept separate from handleKey so
    /// the key→command mapping is the only thing the registry owns.
    func perform(_ command: ShortcutCommand) {
        switch command {
        case .archive:
            if !checkedThreadIds.isEmpty { archiveChecked() }
            else { selectedThread.map(archive) }
        case .trash:
            if !checkedThreadIds.isEmpty { trashChecked() }
            else { selectedThread.map(trash) }
        case .toggleStar:
            if !checkedThreadIds.isEmpty { toggleStarChecked() }
            else { selectedThread.map(toggleStar) }
        case .toggleRead:
            if !checkedThreadIds.isEmpty { toggleReadChecked() }
            else if let t = selectedThread { setRead(t, read: t.isUnread) }
        case .snooze: if let t = selectedThread { snoozingThread = t }
        case .markSpam:
            if !checkedThreadIds.isEmpty { markSpamChecked() }
            else if let t = selectedThread {
                if t.inSpam { markNotSpam(t) } else { markSpam(t) }
            }
        case .next: moveSelection(1)
        case .prev: moveSelection(-1)
        case .toggleCheck: toggleCheckSelected()
        case .reply: if let t = selectedThread,
                        let msg = newestSentMessage(inThread: t.id) {
                         openCompose(ComposeRequest(replyTo: msg))
                     }
        case .replyAll: if let t = selectedThread,
                           let msg = newestSentMessage(inThread: t.id) {
                            openCompose(ComposeRequest(replyTo: msg, replyAll: true))
                        }
        case .forward: if let t = selectedThread,
                          let msg = newestSentMessage(inThread: t.id) {
                           // Gmail `f`: forward the newest *sent* message only.
                           // Use the thread ⋮ menu for "Forward all".
                           openCompose(ComposeRequest(
                               replyTo: msg, forward: true))
                       }
        case .label: if selectedThread != nil { openLabelPicker() }
        case .undo: if let undo = undoAction { undo.undo() }
        case .compose: openCompose(ComposeRequest(replyTo: nil))
        }
    }

    /// Gmail's `/`: move keyboard focus into the sidebar search field. Bumps a
    /// token instead of holding focus state directly so a repeated `/` (after
    /// the user clicked away) re-focuses.
    func focusSearch() {
        searchFocusToken &+= 1
    }

    // MARK: - Labels on threads

    /// User labels available for a thread's account.
    func userLabels(forAccount accountId: String) -> [LabelRow] {
        labelsByAccount[accountId] ?? []
    }

    /// The picker's filtered list for a thread — shared by LabelPicker (rows)
    /// and the window key monitor (space-to-toggle), so both always agree on
    /// which label is highlighted. Matching is per whitespace token, using
    /// locale-aware case/diacritic-insensitive comparison.
    func labelPickerLabels(for thread: MailThread) -> [LabelRow] {
        userLabels(forAccount: thread.accountId)
            .filter { LabelSearch.matches($0.name, query: labelPicker.query) }
    }

    /// The "Create <query>" row's label name: the trimmed query, when it
    /// wouldn't duplicate an existing label on the thread's account.
    func labelPickerCreateName(for thread: MailThread) -> String? {
        let name = labelPicker.query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let exists = userLabels(forAccount: thread.accountId)
            .contains { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return exists ? nil : name
    }

    /// Creates the label on the thread's account, then applies it. The new
    /// label lands highlighted in the (re-emptied) picker list so the applied
    /// checkmark is visible.
    func createLabelAndApply(name: String, thread: MailThread) {
        guard !demoMode else {
            showNotice("Creating labels is disabled in the demo inbox")
            return
        }
        let accountId = thread.accountId
        let client = client(for: accountId)
        Task {
            do {
                let l = try await client.createLabel(name: name)
                await MainActor.run {
                    try? self.db.write { db in
                        try LabelRow(id: "\(accountId):\(l.id)", accountId: accountId,
                                     gmailLabelId: l.id, name: l.name, type: l.type ?? "user",
                                     color: l.color?.backgroundColor).save(db)
                    }
                    self.reloadAccounts()
                    self.labelPicker.query = ""
                    if let idx = self.userLabels(forAccount: accountId)
                        .firstIndex(where: { $0.gmailLabelId == l.id }) {
                        self.labelPicker.highlight = idx
                    }
                    self.toggleLabel(thread, labelId: l.id)
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    /// When the query matches a label that only exists on a *different*
    /// account, name it so the miss isn't silent (labels apply per account).
    func labelPickerOtherAccountMatch(excluding accountId: String) -> LabelRow? {
        guard !labelPicker.query.trimmingCharacters(in: .whitespaces).isEmpty,
              accounts.count > 1 else { return nil }
        let localNames = Set(userLabels(forAccount: accountId).map { $0.name.lowercased() })
        return labelsByAccount
            .filter { $0.key != accountId }
            .values.flatMap { $0 }
            .first { label in
                !localNames.contains(label.name.lowercased())
                    && LabelSearch.matches(label.name, query: labelPicker.query)
            }
    }

    func labelName(_ labelId: String, account accountId: String) -> String? {
        labelsByAccount[accountId]?.first { $0.gmailLabelId == labelId }?.name
    }

    /// Display color for a label within an account: the user-assigned (or
    /// Gmail-seeded) color, falling back to the name-stable palette. Scoped by
    /// account so two accounts' same-named labels can carry different colors.
    func labelTint(_ name: String, account accountId: String) -> Color {
        let hex = labelsByAccount[accountId]?.first { $0.name == name }?.color
        return hex.flatMap(Color.hexString) ?? Color.stable(for: name)
    }

    /// Tint for a label filter that isn't scoped to one account (the Labels
    /// chip in unified mode): the color of any account's label with that name,
    /// else the name-stable fallback.
    func labelTint(anyAccount name: String) -> Color {
        let hex = labelsByAccount.values.lazy.flatMap { $0 }.first { $0.name == name }?.color
        return hex.flatMap(Color.hexString) ?? Color.stable(for: name)
    }

    /// Sets (or clears, with nil) a label's display color.
    func setLabelColor(_ label: LabelRow, hex: String?) {
        try? db.write { db in
            var row = label
            row.color = hex
            try row.save(db)
        }
        reloadAccounts()
    }

    /// Persists a drag-reorder of the account switcher. The unified "all
    /// inboxes" entry isn't part of `accounts` (it's a synthetic nil-account
    /// row rendered separately in ContentView), so it's never touched here.
    func reorderAccounts(from source: IndexSet, to destination: Int) {
        let ids = AccountOrder.moved(accounts.map(\.id), from: source, to: destination)
        UserDefaults.standard.set(ids, forKey: Self.accountOrderDefaultsKey)
        let byId = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        accounts = ids.compactMap { byId[$0] }
    }

    /// Persists a drag-reorder of one account's labels from the organizer.
    func reorderLabels(account accountId: String, from source: IndexSet, to destination: Int) {
        var labels = labelsByAccount[accountId] ?? []
        labels.move(fromOffsets: source, toOffset: destination)
        try? db.write { db in
            for (idx, var row) in labels.enumerated() {
                row.sortOrder = idx
                try row.save(db)
            }
        }
        reloadAccounts()
    }

    func toggleLabel(_ thread: MailThread, labelId: String) {
        let has = thread.labels.contains(labelId)
        mutateThread(thread) { t in
            var labels = Set(t.labelIds.split(separator: " ").map(String.init))
            if has { labels.remove(labelId) } else { labels.insert(labelId) }
            t.labelIds = labels.sorted().joined(separator: " ")
            t.syncFlagsFromLabelIds()
        } remote: { client, id in
            try await client.modifyThread(id: id, add: has ? [] : [labelId],
                                          remove: has ? [labelId] : [])
        }
    }

    /// Set right before a keyboard-driven selection change (j/k, arrows) so
    /// the UI can keep the reading pane closed while browsing; a mouse click
    /// (which never sets it) reopens the pane. Cleared after each change.
    var selectionViaKeyboard = false

    /// Thread ids in the order the list actually displays them (priority
    /// section first, then grouped) — kept in sync by ThreadListView so
    /// keyboard navigation matches what's on screen.
    var displayOrder: [String] = []

    func moveSelection(_ delta: Int) {
        let order = displayOrder.isEmpty ? threads.map(\.id) : displayOrder
        guard !order.isEmpty else { return }
        let idx = order.firstIndex { $0 == selectedThreadId } ?? (delta > 0 ? -1 : 0)
        let next = min(max(idx + delta, 0), order.count - 1)
        selectedThreadId = order[next]
    }

    /// Warm headers + last message body for prev/next in `displayOrder`
    /// (Phase 2). Cap concurrency at 1; cancel when selection changes.
    /// Detached so arrow-key selection does not hop the MainActor between
    /// reads; still stored on `neighborPrefetchTask` so termination can
    /// cancel and await it like any other tracked DB task.
    private func prefetchNeighborThreads() {
        guard !isShuttingDown else { return }
        neighborPrefetchTask?.cancel()
        let order = displayOrder.isEmpty ? threads.map(\.id) : displayOrder
        let (prev, next) = NeighborPrefetch.neighbors(selected: selectedThreadId, in: order)
        let ids = [prev, next].compactMap { $0 }
        guard !ids.isEmpty else { return }
        let pool = db
        neighborPrefetchTask = Task.detached {
            for id in ids {
                guard !Task.isCancelled else { return }
                _ = try? await pool.read { db in
                    let headers = try Message.fetchAll(
                        db,
                        sql: """
                            SELECT id, accountId, gmailId, threadId, fromHeader, toHeader, ccHeader,
                                   bccHeader, subject, date, snippet,
                                   '' AS bodyText, NULL AS bodyHTML,
                                   messageIdHeader, referencesHeader, labelIds, isUnread, hasAttachment
                            FROM message
                            WHERE threadId = ?
                            ORDER BY date
                            """,
                        arguments: [id])
                    if let last = headers.last {
                        _ = try MessageBody.fetchOne(db, key: last.id)
                    }
                }
            }
        }
    }

    static func snoozeDate(hour: Int, addDays: Int = 0) -> Date {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: addDays, to: Date())!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
    }

    // MARK: - Actions (optimistic local write, then remote, then resync on failure)

    /// When true, `mutateThread` skips `reloadThreads` so bulk loops can
    /// apply many optimistic updates and reload once at the end.
    private var suppressThreadReload = false

    private func mutateThread(_ thread: MailThread,
                              local: (inout MailThread) -> Void,
                              remote: @escaping (GmailClient, String) async throws -> Void) {
        var copy = thread
        local(&copy)
        let updated = copy
        try? db.write { db in
            try updated.save(db)
            try ThreadLabels.rewrite(db, threadId: updated.id, labelIds: updated.labelIds)
        }
        // Optimistic list update so archive/trash auto-advance still sees the
        // row leave immediately; async reload reconciles with DB filters next.
        applyOptimisticThreadUpdate(updated)
        if !suppressThreadReload {
            reloadThreads()
        }
        // Demo interactions are intentionally local. They should feel real
        // without attempting Gmail calls for the fictional account.
        guard !demoMode else { return }
        let client = client(for: thread.accountId)
        let gmailThreadId = thread.gmailThreadId
        Task {
            do { try await remote(client, gmailThreadId) }
            catch {
                await MainActor.run { self.lastError = error.localizedDescription }
                await self.sync(accountId: thread.accountId)
            }
        }
    }

    /// Apply `local`/`remote` to many threads with a single list reload.
    /// Remote calls still fan out (one Task each) but the thread-list query
    /// runs once after all optimistic writes.
    private func mutateThreads(_ targets: [MailThread],
                               local: (inout MailThread) -> Void,
                               remote: @escaping (GmailClient, String) async throws -> Void) {
        guard !targets.isEmpty else { return }
        suppressThreadReload = true
        for thread in targets {
            mutateThread(thread, local: local, remote: remote)
        }
        suppressThreadReload = false
        reloadThreads()
    }

    /// Re-pin threads under an active unread/read filter so a previously
    /// opened (now-read) conversation reappears in `is:unread`.
    ///
    /// Must run **before** `mutateThread(s)` on undo: `reloadThreads` snapshots
    /// `readStateKeepIds` synchronously at call time, so a pin after the
    /// mutation never reaches the reload query.
    private func pinReadStateKeep(_ ids: [String]) {
        guard readStateFilterActive else { return }
        for id in ids { readStateKeepIds.insert(id) }
    }

    private func restoreSelectionFocus(_ id: String?) {
        guard let id else { return }
        selectionViaKeyboard = true
        selectedThreadId = id
    }

    /// Apply a local mutation to the in-memory list without waiting for the
    /// async DB reload. Drops the row when it no longer belongs in the current
    /// view (archive from inbox, trash, etc.) so selection advance works.
    ///
    /// Leave-list always wins over `readStateKeepIds`: stickiness only keeps
    /// mark-read rows under is:unread, and must not block trash/archive
    /// auto-advance (otherwise the row sticks until async reload, advance
    /// sees it still present, and selection ends up empty).
    private func applyOptimisticThreadUpdate(_ updated: MailThread) {
        guard let idx = threads.firstIndex(where: { $0.id == updated.id }) else { return }
        let plan = ThreadListOptimistic.plan(leavesCurrentList: threadLeavesCurrentList(updated))
        switch plan.effect {
        case .remove:
            threads.remove(at: idx)
            if plan.sideEffects.dropKeepId { readStateKeepIds.remove(updated.id) }
            if plan.sideEffects.dropChecked { checkedThreadIds.remove(updated.id) }
        case .updateInPlace:
            threads[idx] = updated
        }
    }

    /// Best-effort visibility check for the common leave-list mutations.
    /// Async reload is the source of truth for edge-case chip combinations.
    private func threadLeavesCurrentList(_ t: MailThread) -> Bool {
        // A committed `/` search replaces the selected view's filters. Use the
        // same mailbox scope as `reloadThreads` so optimistic trash/spam stay
        // gone (and archive from search keeps the row — search includes archive).
        let search = committedSearch.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            let parsed = SearchQuery.parse(search)
            return !parsed.includesLocation(inTrash: t.inTrash, inSpam: t.inSpam)
        }
        if t.inTrash {
            if case .trash = selectedView { return false }
            return true
        }
        switch selectedView {
        case .inbox, .account:
            if chips.showArchived { return false }
            if let until = t.snoozeUntil, until > Date() { return true }
            if t.inSpam { return true }
            if !t.inInbox {
                if chips.showSent && t.labelIds.contains("SENT") { return false }
                return true
            }
            return false
        case .promotions:
            // Gmail-aligned: inbox promotions only, never spam/trash.
            return t.inSpam || !t.inInbox || !t.inPromotions
        case .social:
            return t.inSpam || !t.inInbox || !t.inSocial
        case .starred:
            return !t.isStarred
        case .snoozed:
            guard let until = t.snoozeUntil else { return true }
            return until <= Date()
        case .trash:
            return !t.inTrash
        case .allMail:
            return false
        default:
            return false
        }
    }

    private func offerUndo(_ label: String, undo: @escaping () -> Void) {
        undoAction = UndoAction(label: label, undo: undo)
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.undoAction = nil }
        }
    }

    /// Gmail-style auto-advance: after archiving/trashing/spamming the
    /// selected thread, land on the neighbor computed before the mutation —
    /// but only if the row actually left the list (e.g. not when a "show
    /// archived" chip keeps it visible).
    private func advanceSelection(after thread: MailThread, wasSelected: Bool, neighbor: String?) {
        guard wasSelected, let neighbor,
              !threads.contains(where: { $0.id == thread.id }),
              threads.contains(where: { $0.id == neighbor }) else { return }
        selectionViaKeyboard = true
        selectedThreadId = neighbor
    }

    /// Display order used for neighbor / multi-select range (list layout when
    /// known, otherwise current `threads` order).
    private var selectionOrder: [String] {
        displayOrder.isEmpty ? threads.map(\.id) : displayOrder
    }

    /// Threads currently multi-selected, in list order.
    private var checkedThreadsInOrder: [MailThread] {
        let byId = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let checked = checkedThreadIds
        return selectionOrder.compactMap { id in
            guard checked.contains(id) else { return nil }
            return byId[id]
        }
    }

    /// After bulk remove: land on the first survivor past `focus` using the
    /// pre-mutation order. No-op when focus was not among the removed ids, or
    /// when the focused row is still listed (e.g. archive under a search that
    /// includes archived mail).
    private func advanceAfterRemoving(_ removed: Set<String>, fromOrder order: [String],
                                      focus: String?) {
        guard let focus, removed.contains(focus) else { return }
        guard !threads.contains(where: { $0.id == focus }) else { return }
        selectionViaKeyboard = true
        if let neighbor = SelectionAdvance.neighborId(in: order, removing: removed, focus: focus),
           threads.contains(where: { $0.id == neighbor }) {
            selectedThreadId = neighbor
        } else {
            selectedThreadId = threads.first?.id
        }
    }

    func archive(_ thread: MailThread) {
        let wasSelected = selectedThreadId == thread.id
        let neighbor = SelectionAdvance.neighborId(in: selectionOrder, removing: thread.id)
        mutateThread(thread) { $0.inInbox = false } remote: { client, id in
            try await client.modifyThread(id: id, remove: ["INBOX"])
        }
        advanceSelection(after: thread, wasSelected: wasSelected, neighbor: neighbor)
        let priorFocus = wasSelected ? thread.id : selectedThreadId
        offerUndo("Archived") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep([thread.id])
            self.mutateThread(thread) { $0.inInbox = true } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"])
            }
            self.restoreSelectionFocus(priorFocus)
            self.undoAction = nil
        }
    }

    /// Bulk archive for multi-select. Advances focus once past the removed block.
    func archiveChecked() {
        let targets = checkedThreadsInOrder
        guard !targets.isEmpty else { return }
        let order = selectionOrder
        let removed = Set(targets.map(\.id))
        let focus = selectedThreadId
        mutateThreads(targets, local: { $0.inInbox = false }, remote: { client, id in
            try await client.modifyThread(id: id, remove: ["INBOX"])
        })
        clearCheckedThreads()
        advanceAfterRemoving(removed, fromOrder: order, focus: focus)
        let n = targets.count
        let ids = targets.map(\.id)
        offerUndo(n == 1 ? "Archived" : "Archived \(n) conversations") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            self.mutateThreads(targets, local: { $0.inInbox = true }, remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"])
            })
            self.restoreSelectionFocus(focus)
            self.undoAction = nil
        }
    }

    /// Gmail moves the whole thread to Spam; it leaves the inbox locally
    /// right away and drops out of Promotions/Social (those views exclude
    /// `inSpam`). Matches blocklist's labelIds/denorm update so optimistic
    /// UI and the next sync agree.
    func markSpam(_ thread: MailThread) {
        let wasSelected = selectedThreadId == thread.id
        let neighbor = SelectionAdvance.neighborId(in: selectionOrder, removing: thread.id)
        mutateThread(thread) { t in
            t.applyLabelMutation(add: ["SPAM"], remove: ["INBOX"])
        } remote: { client, id in
            try await client.modifyThread(id: id, add: ["SPAM"], remove: ["INBOX"])
        }
        advanceSelection(after: thread, wasSelected: wasSelected, neighbor: neighbor)
        let priorFocus = wasSelected ? thread.id : selectedThreadId
        offerUndo("Marked as spam") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep([thread.id])
            self.mutateThread(thread) { t in
                t.applyLabelMutation(add: ["INBOX"], remove: ["SPAM"])
            } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"], remove: ["SPAM"])
            }
            self.restoreSelectionFocus(priorFocus)
            self.undoAction = nil
        }
    }

    /// Inverse of `markSpam`: remove SPAM, restore INBOX. Used from the
    /// overflow menu when the thread is already in Spam (and as spam-undo).
    func markNotSpam(_ thread: MailThread) {
        let wasSelected = selectedThreadId == thread.id
        let neighbor = SelectionAdvance.neighborId(in: selectionOrder, removing: thread.id)
        mutateThread(thread) { t in
            t.applyLabelMutation(add: ["INBOX"], remove: ["SPAM"])
        } remote: { client, id in
            try await client.modifyThread(id: id, add: ["INBOX"], remove: ["SPAM"])
        }
        advanceSelection(after: thread, wasSelected: wasSelected, neighbor: neighbor)
        let priorFocus = wasSelected ? thread.id : selectedThreadId
        offerUndo("Marked as not spam") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep([thread.id])
            self.mutateThread(thread) { t in
                t.applyLabelMutation(add: ["SPAM"], remove: ["INBOX"])
            } remote: { client, id in
                try await client.modifyThread(id: id, add: ["SPAM"], remove: ["INBOX"])
            }
            self.restoreSelectionFocus(priorFocus)
            self.undoAction = nil
        }
    }

    /// Bulk spam: if any checked row is not spam, mark all spam; else not-spam
    /// all (mirrors star/read bulk majority and the single-thread `!` toggle).
    func markSpamChecked() {
        let targets = checkedThreadsInOrder
        guard !targets.isEmpty else { return }
        let order = selectionOrder
        let focus = selectedThreadId
        let markAsSpam = targets.contains { !$0.inSpam }
        if markAsSpam {
            mutateThreads(targets, local: { t in
                t.applyLabelMutation(add: ["SPAM"], remove: ["INBOX"])
            }, remote: { client, id in
                try await client.modifyThread(id: id, add: ["SPAM"], remove: ["INBOX"])
            })
        } else {
            mutateThreads(targets, local: { t in
                t.applyLabelMutation(add: ["INBOX"], remove: ["SPAM"])
            }, remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"], remove: ["SPAM"])
            })
        }
        let removed = Set(targets.map(\.id))
        clearCheckedThreads()
        // Not-spam usually keeps/restores rows; advance only when focus left.
        advanceAfterRemoving(removed, fromOrder: order, focus: focus)
        let n = targets.count
        let ids = targets.map(\.id)
        let undoLabel = markAsSpam
            ? (n == 1 ? "Marked as spam" : "Marked \(n) as spam")
            : (n == 1 ? "Marked as not spam" : "Marked \(n) as not spam")
        offerUndo(undoLabel) { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            if markAsSpam {
                self.mutateThreads(targets, local: { t in
                    t.applyLabelMutation(add: ["INBOX"], remove: ["SPAM"])
                }, remote: { client, id in
                    try await client.modifyThread(id: id, add: ["INBOX"], remove: ["SPAM"])
                })
            } else {
                self.mutateThreads(targets, local: { t in
                    t.applyLabelMutation(add: ["SPAM"], remove: ["INBOX"])
                }, remote: { client, id in
                    try await client.modifyThread(id: id, add: ["SPAM"], remove: ["INBOX"])
                })
            }
            self.restoreSelectionFocus(focus)
            self.undoAction = nil
        }
    }

    func trash(_ thread: MailThread) {
        // Gmail-style auto-advance: when the selected thread is trashed, land
        // on the next conversation down (or the one above if it was last)
        // instead of leaving nothing selected. Computed before the mutation
        // removes the row from `threads`.
        let wasSelected = selectedThreadId == thread.id
        let neighbor = SelectionAdvance.neighborId(in: selectionOrder, removing: thread.id)
        // Keep labelIds + denorm flags coherent (same pattern as markSpam) so
        // search filters on inTrash and any labelIds-based UI agree.
        mutateThread(thread) { t in
            t.applyLabelMutation(add: ["TRASH"], remove: ["INBOX"])
        } remote: { client, id in
            try await client.trashThread(id: id)
        }
        advanceSelection(after: thread, wasSelected: wasSelected, neighbor: neighbor)
        let priorFocus = wasSelected ? thread.id : selectedThreadId
        offerUndo("Moved to Trash") { [weak self] in
            guard let self else { return }
            // Pin before mutate so reloadThreads snapshots keepIds (opened-
            // under-is:unread rows were auto-marked read and dropped keepIds
            // on trash).
            self.pinReadStateKeep([thread.id])
            self.mutateThread(thread) { t in
                t.applyLabelMutation(add: ["INBOX"], remove: ["TRASH"])
            } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"], remove: ["TRASH"])
            }
            self.restoreSelectionFocus(priorFocus)
            self.undoAction = nil
        }
    }

    /// Bulk trash for multi-select.
    func trashChecked() {
        let targets = checkedThreadsInOrder
        guard !targets.isEmpty else { return }
        let order = selectionOrder
        let removed = Set(targets.map(\.id))
        let focus = selectedThreadId
        mutateThreads(targets, local: { t in
            t.applyLabelMutation(add: ["TRASH"], remove: ["INBOX"])
        }, remote: { client, id in
            try await client.trashThread(id: id)
        })
        clearCheckedThreads()
        advanceAfterRemoving(removed, fromOrder: order, focus: focus)
        let n = targets.count
        let ids = targets.map(\.id)
        offerUndo(n == 1 ? "Moved to Trash" : "Moved \(n) to Trash") { [weak self] in
            guard let self else { return }
            self.pinReadStateKeep(ids)
            self.mutateThreads(targets, local: { t in
                t.applyLabelMutation(add: ["INBOX"], remove: ["TRASH"])
            }, remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"], remove: ["TRASH"])
            })
            self.restoreSelectionFocus(focus)
            self.undoAction = nil
        }
    }

    func toggleStar(_ thread: MailThread) {
        let starring = !thread.isStarred
        mutateThread(thread) { $0.isStarred = starring } remote: { client, id in
            try await client.modifyThread(id: id, add: starring ? ["STARRED"] : [],
                                          remove: starring ? [] : ["STARRED"])
        }
    }

    /// Bulk star: if any checked thread is unstarred, star all; else unstar all.
    func toggleStarChecked() {
        let targets = checkedThreadsInOrder
        guard !targets.isEmpty else { return }
        let starring = targets.contains { !$0.isStarred }
        mutateThreads(targets, local: { $0.isStarred = starring }, remote: { client, id in
            try await client.modifyThread(id: id, add: starring ? ["STARRED"] : [],
                                          remove: starring ? [] : ["STARRED"])
        })
    }

    func setRead(_ thread: MailThread, read: Bool) {
        if readStateFilterActive { readStateKeepIds.insert(thread.id) }
        mutateThread(thread) { $0.isUnread = !read } remote: { client, id in
            try await client.modifyThread(id: id, add: read ? [] : ["UNREAD"],
                                          remove: read ? ["UNREAD"] : [])
        }
    }

    /// Bulk read toggle: if any checked is unread, mark all read; else unread.
    func toggleReadChecked() {
        let targets = checkedThreadsInOrder
        guard !targets.isEmpty else { return }
        let markRead = targets.contains { $0.isUnread }
        for thread in targets {
            setRead(thread, read: markRead)
        }
    }

    /// Snooze mirrors what Gmail's own snooze looks like over the API: the
    /// thread loses INBOX while sleeping and gets it back when the date
    /// passes (or on unsnooze), so other Gmail clients agree with us.
    /// `snoozeUntil` itself stays local — the API has no snooze field —
    /// which also means threads snoozed *in* Gmail arrive here as archived
    /// and reappear on sync when Gmail wakes them.
    func snooze(_ thread: MailThread, until date: Date?) {
        guard let date else {  // unsnooze: back to the inbox now
            mutateThread(thread) { $0.snoozeUntil = nil; $0.inInbox = true } remote: { client, id in
                try await client.modifyThread(id: id, add: ["INBOX"])
            }
            return
        }
        let wasSelected = selectedThreadId == thread.id
        let neighbor = SelectionAdvance.neighborId(in: threads.map(\.id), removing: thread.id)
        mutateThread(thread) { $0.snoozeUntil = date; $0.inInbox = false } remote: { client, id in
            try await client.modifyThread(id: id, remove: ["INBOX"])
        }
        advanceSelection(after: thread, wasSelected: wasSelected, neighbor: neighbor)
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInTomorrow(date) ? "'tomorrow' h a" : "MMM d, h a"
        offerUndo("Snoozed until \(formatter.string(from: date))") { [weak self] in
            guard let self else { return }
            self.snooze(thread, until: nil)
            self.undoAction = nil
        }
    }

    /// Wakes snoozed threads whose date has passed: clears the snooze and
    /// restores INBOX (locally and on Gmail). Runs on the sync tick.
    private func fireDueSnoozes() {
        let now = Date()
        let due = (try? db.read { db in
            try MailThread
                .filter(Column("snoozeUntil") != nil && Column("snoozeUntil") <= now)
                .fetchAll(db)
        }) ?? []
        for thread in due { snooze(thread, until: nil) }
    }

    // MARK: - Sending

    /// A composed message waiting out the undo-send window.
    struct PendingSend {
        /// Gmail API mailbox (OAuth account) — owns the threadId for replies.
        let accountId: String
        /// Address written in From: (primary or send-as of `accountId`).
        /// Empty means the primary (`accountId`).
        var fromEmail: String = ""
        let to: String
        let cc: String
        let bcc: String
        let subject: String
        let body: String
        let replyTo: Message?
        let forward: Bool
        /// Gmail Forward all — restored into the compose banner; HTML upgrade
        /// still re-detects from the body package if this is wrong/missing.
        var forwardAll: Bool = false
        let attachments: [MIMEBuilder.Attachment]
        let replacingDraft: Message?

        /// Effective From identity email.
        var effectiveFromEmail: String {
            fromEmail.isEmpty ? accountId : fromEmail
        }
    }

    @Published private(set) var pendingSend: PendingSend?
    private var pendingSendTimer: Timer?
    static let undoSendWindow: TimeInterval = 10

    /// Queue a message: it actually sends after `undoSendWindow` unless undone.
    func queueSend(_ pending: PendingSend) {
        guard !demoMode else {
            showNotice("Sending is disabled in the demo inbox")
            return
        }
        // A second send flushes the first immediately — one window at a time.
        if let previous = takePendingSend() {
            Task { await self.performSend(previous) }
        }
        pendingSend = pending
        undoTimer?.invalidate()
        undoAction = UndoAction(label: "Sending…") { [weak self] in self?.cancelPendingSend() }
        pendingSendTimer = Timer.scheduledTimer(withTimeInterval: Self.undoSendWindow,
                                                repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.flushPendingSend() }
        }
    }

    /// Undo: pull the message back into compose, nothing sent.
    func cancelPendingSend() {
        guard let p = takePendingSend() else { return }
        undoAction = nil
        composeRequest = ComposeRequest(replyTo: p.replyTo, forward: p.forward,
                                        forwardAll: p.forwardAll,
                                        editDraft: p.replacingDraft, restore: p)
    }

    /// Send the queued message now (window elapsed, or the app is quitting).
    func flushPendingSend() async {
        guard let p = takePendingSend() else { return }
        undoAction = nil
        await performSend(p)
    }

    private func takePendingSend() -> PendingSend? {
        pendingSendTimer?.invalidate()
        pendingSendTimer = nil
        defer { pendingSend = nil }
        return pendingSend
    }

    private func performSend(_ p: PendingSend) async {
        do {
            try await send(from: p.accountId, fromEmail: p.effectiveFromEmail,
                           to: p.to, cc: p.cc, bcc: p.bcc,
                           subject: p.subject, body: p.body, replyTo: p.replyTo,
                           forward: p.forward,
                           attachments: p.attachments, replacingDraft: p.replacingDraft)
            showNotice("Sent")
        } catch {
            // Bring the message back so nothing is lost.
            lastError = "Send failed: \(error.localizedDescription)"
            composeRequest = ComposeRequest(replyTo: p.replyTo, forward: p.forward,
                                            forwardAll: p.forwardAll,
                                            editDraft: p.replacingDraft, restore: p)
        }
    }

    // MARK: - Scheduled sends (send later)

    @Published private(set) var scheduledSends: [ScheduledSend] = []
    private var scheduledSendTimer: Timer?

    func reloadScheduledSends() {
        scheduledSends = (try? db.read {
            try ScheduledSend.order(Column("sendAt")).fetchAll($0)
        }) ?? []
        armScheduledSendTimer()
    }

    /// Persist a composed message to go out at `date`. Survives relaunch;
    /// anything overdue sends on next launch.
    func scheduleSend(_ p: PendingSend, at date: Date) {
        guard !demoMode else {
            showNotice("Scheduled sending is disabled in the demo inbox")
            return
        }
        let row = ScheduledSend(
            id: nil, accountId: p.accountId, fromEmail: p.effectiveFromEmail,
            toHeader: p.to, ccHeader: p.cc,
            bccHeader: p.bcc, subject: p.subject, body: p.body, sendAt: date,
            replyToMessageId: p.replyTo?.id, forward: p.forward,
            replacingDraftId: p.replacingDraft?.id,
            attachmentsJSON: ScheduledSend.encodeAttachments(p.attachments),
            createdAt: Date())
        try? db.write { db in try row.insert(db) }
        reloadScheduledSends()
        showNotice("Scheduled — sends \(SendSchedule.describe(date))")
    }

    /// Pull a scheduled message back into compose (nothing is lost).
    func editScheduledSend(_ s: ScheduledSend) {
        let p = pendingSend(from: s)
        try? db.write { db in _ = try ScheduledSend.deleteOne(db, key: s.id) }
        reloadScheduledSends()
        composeRequest = ComposeRequest(replyTo: p.replyTo, forward: p.forward,
                                        forwardAll: p.forwardAll,
                                        editDraft: p.replacingDraft, restore: p)
    }

    /// Skip the wait: goes through the normal undo-send window.
    func sendScheduledNow(_ s: ScheduledSend) {
        let p = pendingSend(from: s)
        try? db.write { db in _ = try ScheduledSend.deleteOne(db, key: s.id) }
        reloadScheduledSends()
        queueSend(p)
    }

    func discardScheduledSend(_ s: ScheduledSend) {
        try? db.write { db in _ = try ScheduledSend.deleteOne(db, key: s.id) }
        reloadScheduledSends()
        showNotice("Scheduled message discarded")
    }

    private func pendingSend(from s: ScheduledSend) -> PendingSend {
        // The referenced messages may have been pruned since; threading
        // headers then simply fall away. Bodies live off-row (v24) — use
        // messageBody so ReplyComposer/ForwardComposer can still match the
        // quote and emit Gmail-style HTML.
        let replyTo = s.replyToMessageId.flatMap { messageBody(id: $0) }
        let draft = s.replacingDraftId.flatMap { messageBody(id: $0) }
        return PendingSend(accountId: s.accountId, fromEmail: s.effectiveFromEmail,
                           to: s.toHeader, cc: s.ccHeader,
                           bcc: s.bccHeader, subject: s.subject, body: s.body,
                           replyTo: replyTo, forward: s.forward,
                           attachments: s.attachments, replacingDraft: draft)
    }

    private func armScheduledSendTimer() {
        scheduledSendTimer?.invalidate()
        scheduledSendTimer = nil
        guard let next = scheduledSends.map(\.sendAt).min() else { return }
        scheduledSendTimer = Timer.scheduledTimer(withTimeInterval: max(next.timeIntervalSinceNow, 1),
                                                  repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.fireDueScheduledSends() }
        }
    }

    func fireDueScheduledSends() async {
        guard !demoMode else { return }
        let due = scheduledSends.filter { $0.sendAt <= Date() }
        guard !due.isEmpty else { return }
        for s in due {
            let p = pendingSend(from: s)
            _ = try? await db.write { db in try ScheduledSend.deleteOne(db, key: s.id) }
            await performSend(p)
            Notifier.notify(title: "Scheduled message sent",
                            body: s.subject.isEmpty ? s.toHeader : s.subject,
                            id: "scheduled.\(s.id ?? 0)")
        }
        reloadScheduledSends()
    }

    func send(from accountId: String, fromEmail: String = "",
              to: String, cc: String, bcc: String = "", subject: String,
              body: String, replyTo message: Message? = nil, forward: Bool = false,
              attachments: [MIMEBuilder.Attachment] = [],
              replacingDraft draft: Message? = nil) async throws {
        // For a forward, `message` is the forwarded original: it supplies the
        // HTML body below, but must not thread the send into its conversation.
        let threadParent = forward ? nil : message
        // Replies/drafts must send through the mailbox that owns the thread.
        // A mismatched From account used to pass a foreign threadId → Gmail 404.
        let apiAccountId = SendIdentityResolver.apiAccountId(
            requested: accountId,
            replyAccountId: threadParent?.accountId,
            draftAccountId: draft?.accountId)
        let identityEmail = fromEmail.isEmpty ? apiAccountId : fromEmail
        let bodyHTML = htmlAlternative(body: body,
                                       forwardOf: forward ? message : nil,
                                       replyTo: forward ? nil : message,
                                       draft: draft)
        let raw = MIMEBuilder.build(
            from: fromHeader(accountId: apiAccountId, fromEmail: identityEmail),
            to: to, cc: cc, bcc: bcc, subject: subject,
            bodyText: body, bodyHTML: bodyHTML,
            inReplyTo: threadParent?.messageIdHeader,
            references: threadParent?.referencesHeader ?? draft?.referencesHeader,
            attachments: attachments
        )
        // A reply keeps its thread; so does a draft that lives in one.
        // Only pass threadId when it belongs to apiAccountId (always true after resolve).
        let gmailThreadId = (threadParent ?? draft).map { String($0.threadId.split(separator: ":").last!) }
        try await client(for: apiAccountId).send(raw: raw, threadId: gmailThreadId)
        if let draft { await deleteUnderlyingDraft(draft, silent: true) }
        await sync(accountId: apiAccountId)
    }

    /// HTML alternative for an outgoing message:
    /// 1. Untouched forward quote → original HTML under user text
    /// 2. Untouched reply quote → Gmail-style gmail_quote + original HTML
    /// 3. Unedited draft body → preserved draft HTML
    /// 4. Markdown body → rendered HTML (bold, headers, math, lists, …)
    /// 5. Otherwise → ComposeLinks linkification (markdown links + bare URLs)
    ///
    /// Forward single vs Forward-all is resolved by
    /// `ForwardComposer.matchHTMLUpgrade` (all-package first — see that
    /// method; drafts are excluded from Forward-all). Replies use
    /// `ReplyComposer` so nested history isn't re-markdown'd as `>` lines.
    private func htmlAlternative(body: String, forwardOf original: Message?,
                                 replyTo replyParent: Message? = nil,
                                 draft: Message?) -> String? {
        if let orig = original {
            let threadMsgs = messages(inThread: orig.threadId)
            if let match = ForwardComposer.matchHTMLUpgrade(
                body: body, original: orig, threadMessages: threadMsgs) {
                return ForwardComposer.htmlBody(userText: match.userText, parts: match.parts)
            }
            // Content drift (new mail in thread since compose) or an edited
            // quote: neither package matches → fall through to plain/markdown.
        }
        if let parent = replyParent,
           let match = ReplyComposer.matchHTMLUpgrade(body: body, original: parent) {
            return ReplyComposer.htmlBody(userText: match.userText, original: match.original)
        }
        if let draft, let html = draft.bodyHTML, !html.isEmpty, body == draft.bodyText {
            return html
        }
        // Markdown-authored body. Reply quotes that failed the upgrade above
        // still match `^>\s` here — best-effort, not Gmail-shaped.
        if Markdown.looksLikeMarkdown(body) {
            return Markdown.toHTML(body)
        }
        // Plain prose: still emit HTML when there are links to click.
        let fragment = ComposeLinks.htmlFragment(from: body)
        return fragment.isEmpty ? nil : fragment
    }

    /// Saves compose state as a real Gmail draft (shows up in Gmail too).
    /// Replaces `replacing` when re-saving an edited draft.
    /// - Parameter silent: skip the success toast (autosave / status UI owns feedback).
    /// - Parameter syncAfter: refresh local DB after save. Defaults to `!silent`
    ///   so autosave stays light; dismiss paths pass `true` so Drafts/thread
    ///   rows match Gmail (no stale "continue draft" after replace).
    /// - Returns: a lightweight Message stand-in for the new draft so the
    ///   next autosave can replace it without waiting on a full sync.
    @discardableResult
    func saveDraft(from accountId: String, fromEmail: String = "",
                   to: String, cc: String, bcc: String = "", subject: String,
                   body: String, replyTo message: Message? = nil, forward: Bool = false,
                   attachments: [MIMEBuilder.Attachment] = [],
                   replacing draft: Message? = nil,
                   silent: Bool = false,
                   syncAfter: Bool? = nil) async -> Message? {
        let shouldSync = syncAfter ?? !silent
        guard !demoMode else {
            if !silent { showNotice("Drafts aren't saved in the demo inbox") }
            return nil
        }
        // Same rules as send(): a forward's original doesn't thread the
        // draft, but supplies the HTML body when the quote is untouched.
        let threadParent = forward ? nil : message
        let apiAccountId = SendIdentityResolver.apiAccountId(
            requested: accountId,
            replyAccountId: threadParent?.accountId,
            draftAccountId: draft?.accountId)
        let identityEmail = fromEmail.isEmpty ? apiAccountId : fromEmail
        let raw = MIMEBuilder.build(
            from: fromHeader(accountId: apiAccountId, fromEmail: identityEmail),
            to: to, cc: cc, bcc: bcc, subject: subject, bodyText: body,
            bodyHTML: htmlAlternative(body: body,
                                      forwardOf: forward ? message : nil,
                                      replyTo: forward ? nil : message,
                                      draft: draft),
            inReplyTo: threadParent?.messageIdHeader,
            references: threadParent?.referencesHeader ?? draft?.referencesHeader,
            attachments: attachments
        )
        let gmailThreadId = ((threadParent ?? draft).map { String($0.threadId.split(separator: ":").last!) })
        do {
            let created = try await client(for: apiAccountId)
                .createDraft(raw: raw, threadId: gmailThreadId)
            if let draft { await deleteUnderlyingDraft(draft, silent: true) }
            if !silent {
                showNotice("Draft saved — find it in Drafts")
            }
            if shouldSync {
                await sync(accountId: apiAccountId)
            }
            // Stand-in for replace chaining. threadId prefers the local
            // account-prefixed id we already know; gmail bare id as fallback.
            let localThreadId = threadParent?.threadId
                ?? draft?.threadId
                ?? "\(apiAccountId):\(created.message.threadId)"
            return Message(
                id: "\(apiAccountId):\(created.message.id)",
                accountId: apiAccountId,
                gmailId: created.message.id,
                threadId: localThreadId,
                fromHeader: fromHeader(accountId: apiAccountId, fromEmail: identityEmail),
                toHeader: to, ccHeader: cc, bccHeader: bcc,
                subject: subject, date: Date(), snippet: String(body.prefix(120)),
                bodyText: body, bodyHTML: nil,
                messageIdHeader: "", referencesHeader: "",
                labelIds: "DRAFT", isUnread: false, hasAttachment: !attachments.isEmpty)
        } catch {
            // Always surface close-path failures (silent=false). Autosave keeps
            // lastError clean and uses the in-card "Draft not saved" status.
            if !silent {
                lastError = "Draft not saved: \(error.localizedDescription)"
            }
            return nil
        }
    }

    /// Lightweight sync after a silent autosave session ends (✕ / Esc / replace).
    func syncDraftMailbox(_ accountId: String) async {
        guard !demoMode, !accountId.isEmpty else { return }
        await sync(accountId: accountId)
    }

    // MARK: - Draft management

    /// Newest non-draft in a thread — thin wrapper over
    /// `ForwardComposer.newestSentMessage` for callers that already hold the store.
    func newestSentMessage(inThread threadId: String) -> Message? {
        ForwardComposer.newestSentMessage(in: messages(inThread: threadId))
    }

    /// Newest draft in a thread.
    func newestDraft(inThread threadId: String) -> Message? {
        ForwardComposer.newestDraft(in: messages(inThread: threadId))
    }

    /// A thread that is nothing but an unsent draft — opening it should hop
    /// straight into compose (Notion Mail-style), not the reading pane.
    /// Draft replies inside real conversations still open the thread.
    func isDraftOnly(_ thread: MailThread) -> Bool {
        guard thread.labels.contains("DRAFT") else { return false }
        let msgs = messages(inThread: thread.id)
        return !msgs.isEmpty && msgs.allSatisfy { ForwardComposer.hasDraftLabel($0.labelIds) }
    }

    /// Opens a specific draft back into compose. Reply drafts recover the
    /// parent message so send still attaches In-Reply-To and the Gmail-style
    /// HTML upgrade; forward / brand-new-compose drafts leave replyTo nil.
    func editDraft(_ draft: Message) {
        guard ForwardComposer.hasDraftLabel(draft.labelIds) else { return }
        let msgs = messages(inThread: draft.threadId)
        // Prefer the in-memory full body when the card was header-only.
        let full = messageBody(id: draft.id) ?? draft
        let parent = Self.replyParent(forDraft: full, inThread: msgs)
        openCompose(ComposeRequest(replyTo: parent, editDraft: full))
    }

    /// Opens the newest draft in a thread (list/context-menu / top-banner entry).
    func editDraft(inThread thread: MailThread) {
        guard let draft = newestDraft(inThread: thread.id) else { return }
        editDraft(draft)
    }

    /// Latest non-draft message to thread a reopened reply draft against.
    /// Nil for forward drafts (body carries the forward marker / Fwd: subject)
    /// and for draft-only threads (new compose never left the box).
    static func replyParent(forDraft draft: Message, inThread msgs: [Message]) -> Message? {
        if draft.bodyText.contains(ForwardComposer.marker) { return nil }
        if draft.subject.lowercased().hasPrefix("fwd:") { return nil }
        let nonDrafts = msgs.filter { !ForwardComposer.hasDraftLabel($0.labelIds) }
        guard !nonDrafts.isEmpty else { return nil }
        // Prefer matching References' last Message-ID (immediate parent) when
        // Gmail echoed it onto the draft row after save.
        if !draft.referencesHeader.isEmpty {
            let tokens = draft.referencesHeader
                .split(whereSeparator: \.isWhitespace).map(String.init)
            if let last = tokens.last {
                let bare = last.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                if let match = nonDrafts.last(where: {
                    let mid = $0.messageIdHeader
                        .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    return !mid.isEmpty && mid == bare
                }) {
                    return match
                }
            }
        }
        // Chronological last non-draft (msgs is oldest-first from messages(inThread:)).
        return nonDrafts.last
    }

    /// Deletes the Gmail draft behind a local draft message.
    func deleteUnderlyingDraft(_ draftMessage: Message, silent: Bool = false) async {
        do {
            let client = client(for: draftMessage.accountId)
            let drafts = try await client.listDrafts()
            guard let match = drafts.first(where: { $0.message.id == draftMessage.gmailId }) else {
                return
            }
            try await client.deleteDraft(id: match.id)
            if !silent {
                showNotice("Draft deleted")
                await sync(accountId: draftMessage.accountId)
            }
        } catch {
            if !silent { lastError = error.localizedDescription }
        }
    }

    /// Discard a specific draft (card-level Discard / confirmed alert).
    func deleteDraft(_ draft: Message) {
        Task { await deleteUnderlyingDraft(draft) }
    }

    /// Discard the newest draft in a thread (list context menu).
    func deleteDraft(inThread thread: MailThread) {
        guard let draft = newestDraft(inThread: thread.id) else { return }
        deleteDraft(draft)
    }

    /// Download every attachment on a message into a folder the user picks.
    func saveAllAttachments(_ attachments: [AttachmentRow], message: Message) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save \(attachments.count) Attachments Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            do {
                for att in attachments {
                    let data = try await client(for: message.accountId)
                        .getAttachment(messageId: message.gmailId, attachmentId: att.gmailAttachmentId)
                    let dest = Self.availableAttachmentURL(
                        in: dir, filename: MessageParser.safeFilename(att.filename))
                    try data.write(to: dest, options: .atomic)
                    Self.markQuarantined(dest)
                }
                await MainActor.run {
                    showNotice("Saved \(attachments.count) attachments")
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    // MARK: - Attachments

    /// Downloads a message's attachments as sendable MIME parts — used to
    /// carry the original files along on a forward, like Gmail does.
    func loadAttachments(for message: Message) async throws -> [MIMEBuilder.Attachment] {
        var out: [MIMEBuilder.Attachment] = []
        for att in attachments(for: message.id) {
            let data = try await client(for: message.accountId)
                .getAttachment(messageId: message.gmailId, attachmentId: att.gmailAttachmentId)
            out.append(.init(filename: MessageParser.safeFilename(att.filename),
                             mimeType: att.mimeType, data: data))
        }
        return out
    }

    /// Opens in the default app via a private temp file inside the sandbox
    /// (macOS purges it; nothing is written to user folders). The file is
    /// namespaced by message id (so same-named attachments never collide) and
    /// tagged with the quarantine attribute so Gatekeeper still gates it.
    /// Downloads an attachment into the per-message temp folder, reusing an
    /// already-downloaded copy so open → Quick Look → open doesn't re-fetch.
    private func attachmentTempURL(_ attachment: AttachmentRow, message: Message) async throws -> URL {
        // Keyed by attachment row too, so two same-named attachments on one
        // message can't serve each other's cached bytes.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MishMailAttachments", isDirectory: true)
            .appendingPathComponent(MessageParser.safeFilename(message.accountId), isDirectory: true)
            .appendingPathComponent(MessageParser.safeFilename(message.gmailId), isDirectory: true)
            .appendingPathComponent(String(attachment.id ?? 0), isDirectory: true)
        let url = dir.appendingPathComponent(MessageParser.safeFilename(attachment.filename))
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true {
                Self.markQuarantined(url)
                return url
            }
            try fm.removeItem(at: url)
        }
        let data = try await client(for: message.accountId)
            .getAttachment(messageId: message.gmailId, attachmentId: attachment.gmailAttachmentId)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        let written = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard written.isRegularFile == true, written.isSymbolicLink != true else {
            try? fm.removeItem(at: url)
            throw CocoaError(.fileWriteUnknown)
        }
        Self.markQuarantined(url)
        return url
    }

    /// Picks a non-existing destination so sender-controlled duplicate names
    /// cannot overwrite each other or a file already present in the folder.
    static func availableAttachmentURL(in directory: URL, filename: String) -> URL {
        let fm = FileManager.default
        let safe = MessageParser.safeFilename(filename)
        let original = directory.appendingPathComponent(safe)
        guard fm.fileExists(atPath: original.path) else { return original }
        let ns = safe as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        for index in 2...10_000 {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(safe)")
    }

    func openAttachment(_ attachment: AttachmentRow, message: Message) {
        if MessageParser.isRiskyAttachmentFilename(attachment.filename) {
            let alert = NSAlert()
            alert.messageText = "Open potentially dangerous attachment?"
            alert.informativeText =
                "“\(MessageParser.safeFilename(attachment.filename))” looks like an app, script, or installer. Only open it if you trust the sender."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            do {
                let url = try await attachmentTempURL(attachment, message: message)
                NSWorkspace.shared.open(url)
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Native Quick Look on an attachment (same sanitized, quarantined temp
    /// copy the Open path uses — no separate download).
    func quickLookAttachment(_ attachment: AttachmentRow, message: Message) {
        Task {
            do {
                let url = try await attachmentTempURL(attachment, message: message)
                QuickLookController.shared.show([url])
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Tags a written-out attachment with `com.apple.quarantine`. The flags
    /// deliberately omit the "user approved" bit, so an email attachment still
    /// triggers Gatekeeper's "downloaded from the Internet" first-open warning
    /// and any handling app's own web-content checks. Best-effort.
    static func markQuarantined(_ url: URL) {
        let stamp = String(format: "%08x", UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)))
        let value = "0001;\(stamp);MishMail;\(UUID().uuidString)"
        value.withCString { cstr in
            _ = setxattr(url.path, "com.apple.quarantine", cstr, strlen(cstr), 0, 0)
        }
    }

    /// Save As… — the user picks the destination via the system save panel,
    /// which is the only place outside the sandbox the app can write.
    func saveAttachment(_ attachment: AttachmentRow, message: Message) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MessageParser.safeFilename(attachment.filename)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                let data = try await client(for: message.accountId)
                    .getAttachment(messageId: message.gmailId, attachmentId: attachment.gmailAttachmentId)
                let values = try? destination.resourceValues(
                    forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                if values?.isSymbolicLink == true {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: destination, options: .atomic)
                Self.markQuarantined(destination)
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    // MARK: - Snippets

    /// Published, load-once cache of the snippets table. Every mutator below
    /// (and the startup seed) refreshes it after writing, so compose's `/`
    /// picker and Settings' table update live without a manual reload.
    @Published private(set) var allSnippets: [Snippet] = []

    private func reloadSnippets() {
        allSnippets = (try? db.read { try Snippet.order(Column("name")).fetchAll($0) }) ?? []
    }

    func saveSnippet(name: String, body: String, movesToBcc: Bool = false,
                     accountIds: [String] = []) {
        try? db.write { db in
            var s = Snippet(id: nil, name: name, body: body, movesToBcc: movesToBcc)
            s.accountIds = accountIds
            try s.insert(db)
        }
        reloadSnippets()
        objectWillChange.send()
    }

    func deleteSnippet(_ s: Snippet) {
        try? db.write { db in _ = try Snippet.deleteOne(db, key: s.id) }
        reloadSnippets()
        objectWillChange.send()
    }

    func updateSnippet(_ s: Snippet) {
        try? db.write { db in try s.update(db) }
        reloadSnippets()
        objectWillChange.send()
    }

    /// Imports snippets from a JSON file
    /// (`[{"name", "body", "movesToBcc", "accountIds"}]`), skipping any whose
    /// name already exists so re-importing is harmless.
    /// `unknownAccountIds` counts scope emails that don't match a signed-in
    /// account (typos hide the snippet until fixed).
    func importSnippets(from url: URL) throws -> (added: Int, skipped: Int, unknownAccountIds: Int) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let items = try SnippetImport.decode(Data(contentsOf: url))
        let planned = SnippetImport.plan(items, existingNames: allSnippets.map(\.name))
        let known = Set(accounts.map { $0.id.lowercased() })
        var unknownAccountIds = 0
        try db.write { db in
            for item in planned {
                var s = Snippet(id: nil, name: item.name.trimmingCharacters(in: .whitespaces),
                                body: item.body, movesToBcc: item.movesToBcc ?? false)
                let scope = item.accountIds ?? []
                s.accountIds = scope
                for email in scope {
                    let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !e.isEmpty, !known.contains(e.lowercased()) {
                        unknownAccountIds += 1
                    }
                }
                try s.insert(db)
            }
        }
        reloadSnippets()
        objectWillChange.send()
        return (planned.count, items.count - planned.count, unknownAccountIds)
    }
}
