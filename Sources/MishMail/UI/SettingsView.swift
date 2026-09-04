import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// Notion Mail-style settings window: a slim sidebar of panes on the left,
/// the selected pane on the right. Opens with Cmd-, or from the app sidebar.
struct SettingsView: View {
    @Environment(MailStore.self) var store

    enum Pane: String, Identifiable {
        case notionMail, accounts, googleAPI, filters, snippets, general, appearance, shortcuts, ai, updates

        var id: String { rawValue }

        var title: String {
            switch self {
            case .notionMail: return "Moving from Notion Mail"
            case .accounts: return "Accounts"
            case .googleAPI: return "Google API"
            case .filters: return "Gmail filters"
            case .snippets: return "Snippets"
            case .general: return "General"
            case .appearance: return "Appearance"
            case .shortcuts: return "Keyboard shortcuts"
            case .ai: return "AI"
            case .updates: return "Updates"
            }
        }

        var icon: String {
            switch self {
            case .notionMail: return "arrow.right.doc.on.clipboard"
            case .accounts: return "person.2"
            case .googleAPI: return "key"
            case .filters: return "line.3.horizontal.decrease"
            case .snippets: return "curlybraces"
            case .general: return "gearshape"
            case .appearance: return "textformat.size"
            case .shortcuts: return "keyboard"
            case .ai: return "sparkles"
            case .updates: return "arrow.down.circle"
            }
        }
    }

    @AppStorage("settingsPane") private var pane: Pane = .accounts
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $pane) {
                Section {
                    row(.notionMail)
                }
                Section("Account") {
                    row(.accounts)
                    row(.googleAPI)
                    row(.filters)
                    row(.snippets)
                }
                Section("App") {
                    row(.general)
                    row(.appearance)
                    row(.shortcuts)
                    row(.ai)
                    row(.updates)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 800, height: 520)
        .onAppear {
            if !OAuthConfig.isConfigured { pane = .googleAPI }
        }
    }

    private func row(_ p: Pane) -> some View {
        HStack {
            Label(p.title, systemImage: p.icon)
            if p == .updates, updates.available != nil {
                Spacer()
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            }
        }
        .tag(p)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .notionMail: NotionMailSettings()
        case .accounts: AccountsSettings()
        case .googleAPI: GoogleAPISettings()
        case .filters: GmailFiltersSettings()
        case .snippets: SnippetsSettings()
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .shortcuts: ShortcutsSettings(bindings: store.keyBindings)
        case .ai: AISettings()
        case .updates: UpdatesSettings()
        }
    }
}

/// Shared pane layout: Notion-style big title with a hairline under it.
struct PaneScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider().padding(.horizontal, 20)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct GoogleAPISettings: View {
    @State private var clientID: String = OAuthConfig.clientID
    @State private var clientSecret: String = OAuthConfig.clientSecret
    // Start in edit mode only when nothing is saved yet; otherwise show the
    // saved credentials read-only behind an explicit Edit button.
    @State private var editing = !OAuthConfig.isConfigured

    private var trimmedID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSecret: String { clientSecret.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Demo/UI-test processes never touch Keychain, so a pasted secret would
    /// be silently dropped (and the Client ID would leak into the shared
    /// Debug preferences). Don't offer the form there at all.
    private var isFixtureProcess: Bool {
        !OAuthConfig.usesKeychain(environment: ProcessInfo.processInfo.environment)
    }

    var body: some View {
        PaneScaffold(title: "Google API") {
            Form {
                if isFixtureProcess {
                    Section {
                        Text("The fictional demo can't store Google API credentials — nothing here syncs or signs in. Quit and run make run DEMO=0 to configure a real inbox.")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Google OAuth (Desktop app client)")
                    }
                } else if editing {
                    Section {
                        TextField("Client ID", text: $clientID)
                        SecureField("Client Secret", text: $clientSecret)
                        HStack {
                            Spacer()
                            if OAuthConfig.isConfigured {
                                Button("Cancel") {
                                    clientID = OAuthConfig.clientID
                                    clientSecret = OAuthConfig.clientSecret
                                    editing = false
                                }
                            }
                            Button("Save") {
                                OAuthConfig.clientID = trimmedID
                                OAuthConfig.clientSecret = trimmedSecret
                                clientID = trimmedID
                                clientSecret = trimmedSecret
                                editing = false
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(trimmedID.isEmpty)
                        }
                    } header: {
                        Text("Google OAuth (Desktop app client)")
                    } footer: {
                        Text("Create a free OAuth client in Google Cloud Console → APIs & Services → Credentials → Create Credentials → OAuth client ID → Desktop app. The secret is stored in your Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        LabeledContent("Client ID") {
                            Text(clientID)
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Client Secret") {
                            Text(clientSecret.isEmpty ? "Not set" : "••••••••••••")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Label("Configured", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Edit") { editing = true }
                        }
                    } header: {
                        Text("Google OAuth (Desktop app client)")
                    } footer: {
                        Text("These credentials are saved — the Client ID in app preferences, the secret in your Keychain. Click Edit to change them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        // First-run safety net: nothing is configured yet and the user
        // navigates away mid-paste — keep what they typed instead of
        // silently dropping it (the pane's @State dies with the pane).
        .onDisappear {
            if !isFixtureProcess, editing, !OAuthConfig.isConfigured, !trimmedID.isEmpty {
                OAuthConfig.clientID = trimmedID
                OAuthConfig.clientSecret = trimmedSecret
            }
        }
    }
}

struct UpdatesSettings: View {
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        PaneScaffold(title: "Updates",
                     subtitle: "Releases are published on GitHub (\(UpdateChecker.repo))") {
            Form {
                Section {
                    LabeledContent("Current version", value: updates.currentVersion)
                    if let release = updates.available {
                        LabeledContent("Latest version", value: release.version)
                        if !release.notes.isEmpty {
                            Text(release.notes)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(8)
                        }
                        HStack {
                            Button {
                                updates.openUpdate()
                            } label: {
                                if updates.installing {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("Updating…")
                                    }
                                } else {
                                    Text("Install and Relaunch")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(updates.installing)
                            Button("View on GitHub") { updates.openReleasePage() }
                        }
                    }
                    if let status = updates.status {
                        Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Installing downloads the release zip, checks SHA-256 (when published), code signature, Team ID, and notarization for Developer ID builds, then replaces MishMail where it's installed and restarts it. The first update asks once for permission to that folder, since the app is sandboxed. Failed checks open the GitHub release page; a failed install reveals the verified app in Finder to drag in by hand. Quiet daily checks also surface an update button in the sidebar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Button {
                            Task { await updates.check() }
                        } label: {
                            if updates.checking {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Checking…")
                                }
                            } else {
                                Text("Check for Updates")
                            }
                        }
                        // A check during an install would overwrite its
                        // progress status; `check` refuses anyway.
                        .disabled(updates.checking || updates.installing)
                        Spacer()
                        if let last = updates.lastChecked {
                            Text("Checked \(last, format: .relative(presentation: .named))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct AccountsSettings: View {
    @Environment(MailStore.self) var store

    var body: some View {
        PaneScaffold(title: "Accounts") {
            Form {
                ForEach(store.accounts) { account in
                    Section {
                        HStack {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(account.id)
                                    if store.accountsNeedingReauth.contains(account.id) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                            .help("Google no longer accepts this account's saved sign-in (expired or revoked). Reauthorize to resume syncing.")
                                    }
                                }
                                if let last = store.lastSyncByAccount[account.id] {
                                    Text("Last sync \(last, format: .relative(presentation: .named))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if store.accountsNeedingReauth.contains(account.id) {
                                Button("Reauthorize…") { store.addAccount(reauthorizing: account.id) }
                            }
                            if store.demoMode, account.id == DemoSeed.account {
                                Button("Exit Demo") { store.exitDemoMode() }
                            } else {
                                Button("Remove Account", role: .destructive) {
                                    store.removeAccount(account.id)
                                }
                            }
                        }
                        SyncWindowPicker(accountId: account.id)
                    }
                }
                Section {
                    Button(store.demoMode ? "Connect Google and exit demo…"
                                          : "Add Google Account…") {
                        store.addAccount()
                    }
                } footer: {
                    Text(store.demoMode
                         ? "After Google sign-in succeeds, MishMail removes the fictional inbox and starts syncing your account."
                         : "Keep mail from controls what is stored on this Mac per account — Gmail itself is never changed. Narrowing it (or choosing Nothing) removes the older local copies; widening downloads older mail in the background. Starred mail is always kept and downloaded regardless of age.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Gmail filters (read-only, Notion Mail-style sentences)

struct GmailFiltersSettings: View {
    @Environment(MailStore.self) var store

    private var anyLoading: Bool {
        store.accounts.contains { store.filtersLoading.contains($0.id) }
    }

    var body: some View {
        PaneScaffold(title: "Gmail filters",
                     subtitle: "The following Gmail filters are applied to all incoming mail") {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.accounts.isEmpty {
                        Text("Add a Google account to see its filters.")
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                    ForEach(store.accounts) { account in
                        if store.accounts.count > 1 {
                            Text(account.id)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 20)
                                .padding(.top, 16).padding(.bottom, 4)
                        }
                        accountSection(account.id)
                    }
                    HStack {
                        if anyLoading { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Edit filters in Gmail…") {
                            // Prefer the first account's authuser so multi-
                            // account users land on a real mailbox; Gmail's
                            // #settings/filters is per signed-in session.
                            let email = store.accounts.first?.id ?? ""
                            if let url = GmailWebLinks.filtersSettingsURL(accountEmail: email) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 12))
                        .disabled(store.demoMode)
                        .help(store.demoMode ? "Gmail is unavailable in the fictional inbox"
                                             : "Open Gmail filter settings")
                    }
                    .padding(20)
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func accountSection(_ accountId: String) -> some View {
        if let error = store.filtersLoadError[accountId],
           store.filtersByAccount[accountId] == nil {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 10)
        } else if let filters = store.filtersByAccount[accountId] {
            if filters.isEmpty {
                Text("No filters set up in Gmail for this account.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
            ForEach(filters) { filter in
                GmailFilterSentenceRow(filter: filter, accountId: accountId)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                Divider().padding(.leading, 20)
            }
        } else if store.filtersLoading.contains(accountId) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading filters…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        } else {
            EmptyView()
        }
    }

    private func load() async {
        // Shared cache with the per-message matching-filters disclosure.
        // Force refresh when opening Settings so edits made in Gmail show up.
        await withTaskGroup(of: Void.self) { group in
            for account in store.accounts {
                let id = account.id
                group.addTask { @MainActor in
                    await store.ensureFiltersLoaded(for: id, force: true)
                }
            }
        }
    }
}

// MARK: - Snippets (Notion Mail-style table with search + editor sheet)

struct SnippetsSettings: View {
    @Environment(MailStore.self) var store
    @State private var search = ""
    @State private var editing: Snippet?
    @State private var showImporter = false
    @State private var importResult: String?
    @State private var listContentHeight: CGFloat = 0
    @State private var listViewportHeight: CGFloat = 0

    private var filtered: [Snippet] {
        store.allSnippets.filter { $0.matches(search) }
    }

    /// True when the snippet list is taller than its viewport (overflow).
    private var listOverflows: Bool {
        listContentHeight > listViewportHeight + 8 && listViewportHeight > 0
    }

    var body: some View {
        PaneScaffold(title: "Snippets",
                     subtitle: "Reusable text you can drop into any email by typing / in compose. Import JSON or CSV, including a Notion Mail export.") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    SearchField(prompt: "Search snippets…", text: $search)
                        .frame(maxWidth: 280)

                    Spacer()

                    if let importResult {
                        Text(importResult)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Button("Import…") { showImporter = true }
                        .help("Import JSON or CSV snippets, including a Notion Mail export")
                    Button("Create new") {
                        editing = Snippet(id: nil, name: "", body: "")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)

                HStack(spacing: 0) {
                    Text("Shortcut")
                        .frame(width: 170, alignment: .leading)
                    Text("Preview")
                    Spacer()
                    Text("Accounts")
                        .frame(width: 110, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 6)
                Divider().padding(.horizontal, 20)

                // Constrain the list to the remaining pane height so it
                // actually scrolls (unbounded ScrollViews in a top-aligned
                // VStack get clipped with no scroll). Always-visible
                // indicators + a bottom fade make overflow obvious.
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered, id: \.listId) { snippet in
                                SnippetTableRow(snippet: snippet,
                                                knownAccountIds: store.accounts.map(\.id),
                                                edit: { editing = snippet },
                                                delete: { store.deleteSnippet(snippet) })
                                Divider().padding(.leading, 20)
                            }
                            if filtered.isEmpty {
                                Text(search.isEmpty
                                     ? "No snippets yet — create one to reuse text in compose."
                                     : "No snippets match “\(search)”.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(20)
                            }
                        }
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: SnippetScrollHeightKey.self,
                                    value: geo.size.height)
                            }
                        )
                    }
                    .scrollIndicators(.visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: SnippetViewportHeightKey.self,
                                value: geo.size.height)
                        }
                    )

                    if listOverflows {
                        VStack(spacing: 0) {
                            LinearGradient(
                                colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.92)],
                                startPoint: .top, endPoint: .bottom)
                                .frame(height: 28)
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("Scroll for more")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                            .frame(maxWidth: .infinity)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                        }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .onPreferenceChange(SnippetScrollHeightKey.self) { listContentHeight = $0 }
                .onPreferenceChange(SnippetViewportHeightKey.self) { listViewportHeight = $0 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json, .commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            importResult = SnippetFileImport.apply(result, store: store)
        }
    }
}

private struct SnippetScrollHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SnippetViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SnippetTableRow: View {
    let snippet: Snippet
    let knownAccountIds: [String]
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Click the row to edit — not a toggle or menu.
            Button(action: edit) {
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text("/\(snippet.name)")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if snippet.movesToBcc { MovesToBccBadge() }
                    }
                    .frame(width: 170, alignment: .leading)
                    Text(snippet.previewLine)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(scopeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(hasRemovedAccounts ? Color.orange : .secondary)
                        .lineLimit(1)
                        .frame(width: 110, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit “\(snippet.name)”")

            if hovering {
                Button(action: delete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete “\(snippet.name)”")
                .accessibilityLabel("Delete \(snippet.name)")
            } else {
                // Keep row width stable when the × appears on hover.
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
    }

    private var partitioned: (live: [String], removed: [String]) {
        snippet.accountIds(among: knownAccountIds)
    }

    private var hasRemovedAccounts: Bool { !partitioned.removed.isEmpty }

    private var scopeLabel: String {
        let ids = snippet.accountIds
        if ids.isEmpty { return "All accounts" }
        let live = partitioned.live
        let removed = partitioned.removed
        if live.isEmpty {
            return removed.count == 1 ? "Removed account" : "\(removed.count) removed"
        }
        if removed.isEmpty {
            if live.count == 1 { return live[0] }
            return "\(live.count) accounts"
        }
        // Mix of live + signed-out accounts.
        if live.count == 1 {
            return "\(live[0]) +\(removed.count)"
        }
        return "\(live.count) accts +\(removed.count)"
    }
}

private struct SnippetEditor: View {
    @Environment(MailStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let snippet: Snippet
    @State private var name: String
    @State private var body_: String
    @State private var movesToBcc: Bool
    /// Empty = available on every account (default). Includes any still-
    /// selected removed-account emails until the user clears them.
    @State private var selectedAccountIds: Set<String>
    @State private var limitToAccounts = false

    init(snippet: Snippet) {
        self.snippet = snippet
        _name = State(initialValue: snippet.name)
        _body_ = State(initialValue: snippet.body)
        _movesToBcc = State(initialValue: snippet.movesToBcc)
        let ids = Set(snippet.accountIds)
        _selectedAccountIds = State(initialValue: ids)
        _limitToAccounts = State(initialValue: !ids.isEmpty)
    }

    /// Scope emails not among currently signed-in accounts.
    private var orphanAccountIds: [String] {
        let known = Set(store.accounts.map { $0.id.lowercased() })
        return selectedAccountIds
            .filter { !known.contains($0.lowercased()) }
            .sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snippet.id == nil ? "New snippet" : "Edit snippet")
                .font(.headline)
            TextField("Shortcut name (typed after /)", text: $name)
            TemplateTextEditor(text: $body_)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Text("Type { for variables: {first_name} {name} {email} {date} {my_first_name} {my_name} — and on move-to-Bcc snippets, {bcc_first_name} for the introducer. Anything else in braces stays as a fill-in prompt.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Move recipients to Bcc when inserted", isOn: $movesToBcc)
                    .font(.system(size: 12.5))
                Text("Intro etiquette: To (the introducer) moves to Bcc, Cc moves up to To.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Account scope — same “per mailbox” grouping idea as Gmail filters.
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Limit to specific accounts", isOn: $limitToAccounts)
                    .font(.system(size: 12.5))
                    .onChange(of: limitToAccounts) {
                        if !limitToAccounts {
                            selectedAccountIds = []
                        } else if selectedAccountIds.isEmpty,
                                  let first = store.accounts.first {
                            selectedAccountIds = [first.id]
                        }
                    }
                Text(limitToAccounts
                     ? "Only show this snippet when composing from the accounts below."
                     : "Available when composing from any account.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if limitToAccounts {
                    if store.accounts.isEmpty && orphanAccountIds.isEmpty {
                        Text("Add a Google account first — until then this stays available everywhere.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(store.accounts) { account in
                                Toggle(isOn: Binding(
                                    get: { selectedAccountIds.contains(where: {
                                        $0.caseInsensitiveCompare(account.id) == .orderedSame
                                    }) },
                                    set: { on in
                                        // Drop any case-variant of this id, then re-add canonical.
                                        selectedAccountIds = Set(selectedAccountIds.filter {
                                            $0.caseInsensitiveCompare(account.id) != .orderedSame
                                        })
                                        if on { selectedAccountIds.insert(account.id) }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(account.id)
                                            .font(.system(size: 12.5))
                                        if !account.displayName.isEmpty,
                                           account.displayName != account.id {
                                            Text(account.displayName)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .padding(.vertical, 4)
                            }

                            // Signed-out / typo’d scope entries — removable so
                            // the snippet can become visible again.
                            ForEach(orphanAccountIds, id: \.self) { orphan in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(orphan)
                                            .font(.system(size: 12.5))
                                            .strikethrough()
                                        Text("Removed account — not signed in")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer(minLength: 8)
                                    Button("Remove") {
                                        selectedAccountIds.remove(orphan)
                                        if selectedAccountIds.isEmpty,
                                           store.accounts.isEmpty {
                                            limitToAccounts = false
                                        }
                                    }
                                    .font(.system(size: 11))
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    // ⌘↩ — plain Return inserts a newline in the body editor
                    // (NSTextView), same contract as compose Send.
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .help("Save (⌘↩)")
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private var canSave: Bool {
        let named = !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !body_.trimmingCharacters(in: .whitespaces).isEmpty
        // Allow saving a scoped snippet that only has removed-account ids so
        // the user can open the editor and clear them; block truly empty scope
        // when live accounts exist and limit is on.
        if limitToAccounts && selectedAccountIds.isEmpty && !store.accounts.isEmpty {
            return false
        }
        return named
    }

    private func save() {
        guard canSave else { return }
        // Persist currently selected ids. Orphans the user didn't Remove stay
        // on purpose (nothing dropped silently). Empty selection with limit
        // off → unscoped (all accounts).
        let ids = limitToAccounts ? Array(selectedAccountIds).sorted() : []
        if snippet.id == nil {
            store.saveSnippet(name: name, body: body_, movesToBcc: movesToBcc,
                              accountIds: ids)
        } else {
            var updated = snippet
            updated.name = name
            updated.body = body_
            updated.movesToBcc = movesToBcc
            updated.accountIds = ids
            store.updateSnippet(updated)
        }
        dismiss()
    }
}

/// System integration (default email reader, etc.) — not look-and-feel.
struct GeneralSettings: View {
    /// Lazy: don't hit LaunchServices on every view construction.
    @State private var isDefaultMailApp = false
    @State private var settingDefaultMail = false
    @State private var defaultMailError: String?

    /// Debug builds use a separate bundle id + sandbox; claiming mailto: only
    /// affects this build (not the installed Release app in /Applications).
    private var isDebugBundle: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true
    }

    private var defaultMailFooter: String {
        var parts = [
            "When set, clicking a mailto: link in a browser or another app opens compose here (To, Cc, Bcc, subject, and body when the link includes them).",
            "Opening .eml files is not supported yet.",
            "There is no in-app “unset”; change it in Apple Mail → Settings → General → Default email reader."
        ]
        if isDebugBundle {
            parts.append(
                "This is the Debug build — it claims mailto for itself only, from its build folder; a clean/rebuild can leave links pointing at a stale path. Use the installed Release app for a durable default.")
        }
        return parts.joined(separator: " ")
    }

    var body: some View {
        PaneScaffold(title: "General") {
            Form {
                Section {
                    if isDefaultMailApp {
                        Label("\(DefaultMailClient.appDisplayName) is your default email app",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button {
                                settingDefaultMail = true
                                defaultMailError = nil
                                DefaultMailClient.makeDefault { error in
                                    Task { @MainActor in
                                        settingDefaultMail = false
                                        if let error {
                                            defaultMailError = error.localizedDescription
                                        }
                                        isDefaultMailApp = DefaultMailClient.isDefault
                                    }
                                }
                            } label: {
                                if settingDefaultMail {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("Setting…")
                                    }
                                } else {
                                    Text("Make \(DefaultMailClient.appDisplayName) your default email app")
                                }
                            }
                            .disabled(settingDefaultMail)
                            Spacer()
                        }
                        if let defaultMailError {
                            Text(defaultMailError)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Default email app")
                } footer: {
                    Text(defaultMailFooter)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { isDefaultMailApp = DefaultMailClient.isDefault }
        // Re-check after changing the default in Apple Mail (or another app).
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefaultMailApp = DefaultMailClient.isDefault
        }
    }
}

struct AppearanceSettings: View {
    @Environment(MailStore.self) var store
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("badgeScope") private var badgeScopeRaw = MailStore.BadgeScope.all.rawValue
    @AppStorage("priorityMode") private var priorityModeRaw = PrioritySplit.Mode.starred.rawValue
    @AppStorage("vipAlwaysPins") private var vipAlwaysPins = true
    /// Days of recency for Priority hoist; 0 = all starred. Default 7.
    @AppStorage("priorityWindowDays") private var priorityWindowDays = 7
    /// Cap on Priority section size; 0 = no limit. Default 10.
    @AppStorage("priorityMaxCount") private var priorityMaxCount = 10
    @AppStorage(ThreadOpenStyle.storageKey) private var threadOpenStyleRaw =
        ThreadOpenStyle.fullWindow.rawValue
    /// Default `.ask` preserves privacy (no open-tracking until opt-in).
    @AppStorage(RemoteImagePolicy.defaultsKey) private var remoteImagePolicyRaw =
        RemoteImagePolicy.ask.rawValue
    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue
    /// Comma-separated raw values of compose footer / format buttons the user hid.
    @AppStorage(ComposeToolbarVisibility.storageKey) private var composeToolbarHidden = ""
    @State private var showVIPManager = false

    private var priorityMode: PrioritySplit.Mode {
        PrioritySplit.Mode(rawValue: priorityModeRaw) ?? .starred
    }

    var body: some View {
        PaneScaffold(title: "Appearance") {
            Form {
                Section {
                    Picker("Theme", selection: $appThemeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    // Apply here too: the main-window observer can't fire
                    // when Settings is the only open window.
                    .onChange(of: appThemeRaw) {
                        AppTheme.apply(.from(raw: appThemeRaw))
                    }
                } footer: {
                    Text("System follows your Mac's light/dark appearance; Light and Dark keep MishMail fixed regardless of macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Opening a conversation", selection: $threadOpenStyleRaw) {
                        Text("Fills the window").tag(ThreadOpenStyle.fullWindow.rawValue)
                        Text("Shows in a reading pane").tag(ThreadOpenStyle.readingPane.rawValue)
                        Text("Opens in a centered card").tag(ThreadOpenStyle.centerPeek.rawValue)
                    }
                } footer: {
                    Text("Fills the window is Superhuman-style: click a conversation (or press ↩) and it takes over the window; Esc or g i (any go-to) returns to the list. The reading pane shows conversations beside the message list instead. The centered card (Notion Mail-style center peek) floats the conversation over the list; Esc or clicking outside it returns to the list.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Priority section in Inbox", selection: $priorityModeRaw) {
                        ForEach(PrioritySplit.Mode.allCases, id: \.rawValue) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    if priorityMode == .starred || priorityMode == .starredImportant {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Also pin mail from VIP senders", isOn: $vipAlwaysPins)
                            Text("VIP mail joins the Priority section even when it isn't \(priorityMode == .starred ? "starred" : "starred or important").")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Picker("Only pin recent mail", selection: $priorityWindowDays) {
                            Text("Last 3 days").tag(3)
                            Text("Last 7 days").tag(7)
                            Text("Last 14 days").tag(14)
                            Text("Last 30 days").tag(30)
                            Text("All starred").tag(0)
                        }
                        Picker("Pin at most", selection: $priorityMaxCount) {
                            Text("5 conversations").tag(5)
                            Text("10 conversations").tag(10)
                            Text("25 conversations").tag(25)
                            Text("No limit").tag(0)
                        }
                    }
                } footer: {
                    Text("What pins to the top of the Inbox. VIPs only is the tightest — just mail from your VIP senders. Starred is what you've hand-picked; Starred + Important adds everything Gmail predicts matters, which can be a lot. Older starred mail stays in its place in the date list instead of pinning. When more qualify, only the newest pin; the rest stay in the date list.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Text(store.vipEmails.isEmpty
                             ? "No VIP senders yet"
                             : "\(store.vipEmails.count) VIP sender\(store.vipEmails.count == 1 ? "" : "s")")
                            .foregroundStyle(store.vipEmails.isEmpty ? AnyShapeStyle(.secondary)
                                                                     : AnyShapeStyle(.primary))
                        Spacer()
                        Button("Edit…") { showVIPManager = true }
                    }
                } header: {
                    Text("VIP senders")
                } footer: {
                    Text("New mail from these addresses pins to Priority the moment it arrives. You can also click a sender name in a message, or right-click any thread → Add sender to VIPs.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Text size", selection: $fontScale) {
                        Text("Small").tag(0.9)
                        Text("Default").tag(1.0)
                        Text("Large").tag(1.15)
                        Text("Extra Large").tag(1.3)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Also adjustable anywhere with Cmd + and Cmd −.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Load remote images", selection: $remoteImagePolicyRaw) {
                        ForEach(RemoteImagePolicy.allCases) { policy in
                            Text(policy.title).tag(policy.rawValue)
                        }
                    }
                } header: {
                    Text("Remote images")
                } footer: {
                    Text((RemoteImagePolicy(rawValue: remoteImagePolicyRaw) ?? .ask).footer
                         + " Cleartext image URLs stay blocked either way.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(ComposeToolbarItem.displayOrder) { item in
                        Toggle(isOn: Binding(
                            get: { ComposeToolbarVisibility.isVisible(item, hiddenRaw: composeToolbarHidden) },
                            set: { show in
                                composeToolbarHidden = ComposeToolbarVisibility.setting(
                                    item, hidden: !show, in: composeToolbarHidden)
                            }
                        )) {
                            Label(item.title, systemImage: item.systemImage)
                        }
                        .help(item.help)
                    }
                    if !composeToolbarHidden.isEmpty {
                        Button("Show all compose buttons") {
                            composeToolbarHidden = ""
                        }
                        .font(.system(size: 12))
                    }
                } header: {
                    Text("Compose toolbar")
                } footer: {
                    Text("Hide buttons you don't use (math, AI draft, format tools…) so the footer stays roomy on narrow windows. Keyboard shortcuts (⌘B, ⌘⇧M, ⌘/, …) and markdown you type still work.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Unread badge counts", selection: $badgeScopeRaw) {
                        Text("All accounts").tag(MailStore.BadgeScope.all.rawValue)
                        Text("Focused inbox").tag(MailStore.BadgeScope.focused.rawValue)
                        ForEach(store.accounts) { account in
                            Text(account.displayName == account.id
                                 ? account.id
                                 : "\(account.displayName) — \(account.id)")
                                .tag(MailStore.BadgeScope.account(account.id).rawValue)
                        }
                    }
                    .onChange(of: badgeScopeRaw) { store.refreshBadge() }
                } header: {
                    Text("Dock badge")
                } footer: {
                    Text("What the red unread count on the app icon covers. Focused inbox follows the account picked in the sidebar (all accounts when unified). Capped at 999+.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .sheet(isPresented: $showVIPManager) { VIPManager() }
    }
}

/// Full VIP list editor. Quick add-one field on top, hover-to-remove rows,
/// and a separate bulk section whose paste box pulls every email address out
/// of free-form text (commas, newlines, "Name <email>", CSV columns).
private struct VIPManager: View {
    @Environment(MailStore.self) var store
    @Environment(\.dismiss) private var dismiss
    @State private var newVIP = ""
    @State private var addGroup = ""
    @State private var pasteText = ""
    @State private var bulkGroup = ""
    @State private var filter = ""
    @State private var highlighted = 0
    @State private var dropTargeted = false
    @FocusState private var addFieldFocused: Bool

    private var visibleEmails: [String] {
        let all = store.vipEmails.sorted()
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? all : all.filter { $0.contains(f) }
    }

    private var groupedEmails: [String: [String]] {
        var groups: [String: [String]] = [:]
        for email in visibleEmails {
            let tags = store.vipGroups[email] ?? []
            if tags.isEmpty {
                groups["No group", default: []].append(email)
            } else {
                // Multi-group: list the sender under every tagged section.
                for group in tags {
                    groups[group, default: []].append(email)
                }
            }
        }
        return groups
    }

    private var hasGroupedEmails: Bool {
        store.allVIPGroupNames.count > 0
    }

    private var pendingEmails: [String] {
        PrioritySplit.parseEmails(pasteText).filter { !store.vipEmails.contains($0) }
    }

    private var addSuggestions: [MailStore.Contact] {
        let token = newVIP.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return [] }
        return store.contactSuggestions(for: token).filter { !store.vipEmails.contains($0.email) }
    }

    private func addOne() {
        guard newVIP.contains("@") else { return }
        store.addVIP(newVIP, group: addGroup.isEmpty ? nil : addGroup)
        newVIP = ""
    }

    private func accept(_ contact: MailStore.Contact) {
        store.addVIP(contact.email, group: addGroup.isEmpty ? nil : addGroup)
        newVIP = ""
    }

    /// Reads dropped .csv/.txt (any plain-text) files into the paste box.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            handled = true
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      let text = (try? String(contentsOf: url, encoding: .utf8))
                                 ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                else { return }
                DispatchQueue.main.async {
                    pasteText = pasteText.isEmpty ? text : pasteText + "\n" + text
                }
            }
        }
        return handled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("VIP senders")
                    .font(.headline)
                Spacer()
                if store.vipEmails.count > 8 {
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }

            HStack(spacing: 8) {
                TextField("Add a sender: email@example.com", text: $newVIP)
                    .textFieldStyle(.roundedBorder)
                    .focused($addFieldFocused)
                    .onChange(of: newVIP) { highlighted = 0 }
                    .onKeyPress(.downArrow) {
                        guard !addSuggestions.isEmpty else { return .ignored }
                        highlighted = min(highlighted + 1, addSuggestions.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !addSuggestions.isEmpty else { return .ignored }
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onSubmit {
                        if let pick = addSuggestions[safe: highlighted] { accept(pick) }
                        else { addOne() }
                    }
                GroupPickerCompact(selectedGroup: $addGroup, allGroups: store.allVIPGroupNames)
                Button("Add", action: addOne)
                    .disabled(!newVIP.contains("@"))
            }
            .overlay(alignment: .topLeading) {
                if addFieldFocused, !addSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(addSuggestions.enumerated()), id: \.element.id) { idx, contact in
                            Button {
                                accept(contact)
                            } label: {
                                HStack {
                                    Text(contact.name.isEmpty ? contact.email : contact.name)
                                        .font(.system(size: 12))
                                    if !contact.name.isEmpty {
                                        Text(contact.email)
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(idx == highlighted ? Color.notionAccent.opacity(0.18) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { highlighted = idx } }
                        }
                    }
                    .frame(width: 380, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .shadow(radius: 10)
                    .offset(y: 26)
                }
            }
            .zIndex(10)

            if hasGroupedEmails {
                List {
                    ForEach(store.allVIPGroupNames.sorted(), id: \.self) { groupName in
                        let enabled = store.vipGroupEnabled[groupName] ?? true
                        // Header toggle pauses the whole group's VIP status.
                        Section(header: HStack {
                            Text(groupName).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { enabled },
                                set: { store.setVIPGroupEnabled(groupName, $0) }))
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()
                                .help(enabled ? "Group counts as VIP — click to pause"
                                              : "Group paused — members aren't treated as VIPs")
                        }) {
                            ForEach(groupedEmails[groupName]?.sorted() ?? [], id: \.self) { email in
                                VIPRow(email: email,
                                       groupNames: store.vipGroups[email] ?? [],
                                       allGroups: store.allVIPGroupNames,
                                       remove: { store.removeVIP(email) },
                                       setGroups: { store.setVIPGroups(email, groups: $0) },
                                       toggleGroup: { store.toggleVIPGroup(email, group: $0) })
                                    .opacity(enabled ? 1 : 0.45)
                            }
                        }
                    }
                    if let noGroupEmails = groupedEmails["No group"]?.sorted() {
                        Section(header: Text("No group").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)) {
                            ForEach(noGroupEmails, id: \.self) { email in
                                VIPRow(email: email,
                                       groupNames: store.vipGroups[email] ?? [],
                                       allGroups: store.allVIPGroupNames,
                                       remove: { store.removeVIP(email) },
                                       setGroups: { store.setVIPGroups(email, groups: $0) },
                                       toggleGroup: { store.toggleVIPGroup(email, group: $0) })
                            }
                        }
                    }
                    if store.vipEmails.isEmpty {
                        Text("No VIP senders yet — add one above, paste a list below, click a sender name in a message, or right-click any thread → Add sender to VIPs.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 180)
            } else {
                List {
                    ForEach(visibleEmails, id: \.self) { email in
                        VIPRow(email: email,
                               groupNames: store.vipGroups[email] ?? [],
                               allGroups: store.allVIPGroupNames,
                               remove: { store.removeVIP(email) },
                               setGroups: { store.setVIPGroups(email, groups: $0) },
                               toggleGroup: { store.toggleVIPGroup(email, group: $0) })
                    }
                    if store.vipEmails.isEmpty {
                        Text("No VIP senders yet — add one above, paste a list below, click a sender name in a message, or right-click any thread → Add sender to VIPs.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 180)
            }

            Text("Bulk add")
                .font(.system(size: 12.5, weight: .medium))

            VStack(alignment: .leading, spacing: 6) {
                Text("Paste any text that contains email addresses — an address book export, a CSV column, To/Cc lines, or one address per line — or drag a CSV file in. Every address is picked up automatically; duplicates and ones already on the list are skipped.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $pasteText)
                    .font(.system(size: 12.5))
                    .frame(height: 96)
                    .overlay(alignment: .topLeading) {
                        if pasteText.isEmpty {
                            Text("Ada Lovelace <ada@example.org>, grace@example.mil\njudith@example.com\n…or drop a .csv / .txt file here")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [5, 3]))
                        .foregroundStyle(dropTargeted ? Color.notionAccent : Color(nsColor: .separatorColor)))
                    .onDrop(of: ["public.file-url"], isTargeted: $dropTargeted) { handleDrop($0) }
                HStack {
                    Text(pasteText.isEmpty ? " "
                         : pendingEmails.isEmpty
                            ? "No new addresses found in the pasted text."
                            : "Found \(pendingEmails.count) new address\(pendingEmails.count == 1 ? "" : "es").")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    GroupPickerCompact(selectedGroup: $bulkGroup, allGroups: store.allVIPGroupNames)
                    Button("Add \(pendingEmails.count) sender\(pendingEmails.count == 1 ? "" : "s")") {
                        store.addVIPs(pendingEmails, group: bulkGroup.isEmpty ? nil : bulkGroup)
                        pasteText = ""
                        bulkGroup = ""
                    }
                    .disabled(pendingEmails.isEmpty)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 500, height: 660)
        .onDrop(of: ["public.file-url"], isTargeted: nil) { handleDrop($0) }
    }
}

/// Shared group menu. Single-select mode (`select`) for the add/bulk fields;
/// multi-select mode (`toggle` + `clear`) for VIP rows that can hold several tags.
private struct GroupMenuButton: View {
    /// Neutral starter group names — no personal taxonomy committed in-repo.
    /// Hidden once the user has created them (or an equivalent).
    static let suggested = ["work", "family", "friends"]

    /// Currently assigned groups (empty = ungrouped).
    let current: [String]
    let allGroups: [String]
    /// Single-select path: replace membership with one group or clear.
    var select: ((String?) -> Void)? = nil
    /// Multi-select path: toggle one group on/off.
    var toggle: ((String) -> Void)? = nil
    /// Multi-select clear-all.
    var clear: (() -> Void)? = nil
    @State private var showNewGroup = false
    @State private var newGroupText = ""

    private var multi: Bool { toggle != nil }

    private var remainingSuggestions: [String] {
        Self.suggested.filter { !allGroups.contains($0) }
    }

    private var labelText: String {
        if current.isEmpty { return "No group" }
        if current.count == 1 { return current[0] }
        return current.sorted().joined(separator: ", ")
    }

    var body: some View {
        Menu {
            Button {
                if multi { clear?() } else { select?(nil) }
            } label: {
                if current.isEmpty { Label("No group", systemImage: "checkmark") }
                else { Text("No group") }
            }
            if !allGroups.isEmpty {
                Divider()
                ForEach(allGroups.sorted(), id: \.self) { group in
                    Button {
                        if multi { toggle?(group) } else { select?(group) }
                    } label: {
                        if current.contains(group) { Label(group, systemImage: "checkmark") }
                        else { Text(group) }
                    }
                }
            }
            if !remainingSuggestions.isEmpty {
                Divider()
                Section("Suggested") {
                    ForEach(remainingSuggestions, id: \.self) { group in
                        Button(group) {
                            if multi { toggle?(group) } else { select?(group) }
                        }
                    }
                }
            }
            Divider()
            Button("New group…") { showNewGroup = true }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                Text(labelText)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .fixedSize()
        .popover(isPresented: $showNewGroup, arrowEdge: .bottom) {
            HStack(spacing: 6) {
                TextField("Group name", text: $newGroupText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(commitNewGroup)
                Button("Create", action: commitNewGroup)
                    .disabled(newGroupText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }

    private func commitNewGroup() {
        let name = newGroupText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if multi { toggle?(name) } else { select?(name) }
        newGroupText = ""
        showNewGroup = false
    }
}

/// Group menu bound to a String selection ("" = no group), for add/bulk fields.
private struct GroupPickerCompact: View {
    @Binding var selectedGroup: String
    let allGroups: [String]

    var body: some View {
        GroupMenuButton(
            current: selectedGroup.isEmpty ? [] : [selectedGroup],
            allGroups: allGroups,
            select: { selectedGroup = $0 ?? "" })
    }
}

/// One VIP list row with multi-group picker and always-visible remove button.
private struct VIPRow: View {
    let email: String
    let groupNames: [String]
    let allGroups: [String]
    let remove: () -> Void
    let setGroups: ([String]) -> Void
    let toggleGroup: (String) -> Void

    var body: some View {
        HStack {
            Text(email)
                .lineLimit(1)
            Spacer()
            GroupMenuButton(
                current: groupNames,
                allGroups: allGroups,
                toggle: toggleGroup,
                clear: { setGroups([]) })
                .help("Tag with one or more groups — click again to remove a tag")
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from VIPs")
        }
    }
}

struct AISettings: View {
    @State private var url: String = Ollama.baseURL
    @State private var model: String = Ollama.model
    @State private var allowRemote: Bool = Ollama.allowRemoteEndpoint
    @State private var keepAlive: Int = Ollama.keepAliveSeconds
    @State private var contextTokens: Int = Ollama.contextTokens
    @AppStorage(MailStore.autoClassifyKey) private var autoClassify = true
    @AppStorage(MailStore.suggestRepliesKey) private var suggestReplies = true
    @State private var providers: [LLMProviderConfig] = LLMProviderStore.load()
    @State private var editingProvider: LLMProviderConfig?
    @State private var addingProvider = false
    @State private var usage: [LLMUsageLog.TaskSpend] = []
    @State private var showingClearUsageAlert = false
    /// Models installed in the local Ollama, from /api/tags. Empty when
    /// Ollama is not running.
    @State private var ollamaModels: [String] = []
    @State private var ollamaListError = ""
    @State private var disabledOllama = Ollama.disabledModels
    /// Per-vendor sign-in progress line ("Waiting for browser…", errors).
    @State private var vendorStatus: [LLMOAuthVendor: String] = [:]
    @State private var connectingVendor: LLMOAuthVendor?

    private var endpointIsRemote: Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host != "127.0.0.1" && host != "localhost" && host != "::1"
    }

    var body: some View {
        PaneScaffold(title: "AI") {
            Form {
                Section {
                    TextField("Ollama URL", text: $url)
                        .onChange(of: url) { Ollama.baseURL = url }
                    TextField("Model", text: $model)
                        .onChange(of: model) { Ollama.model = model }
                    if endpointIsRemote {
                        Toggle("Allow remote Ollama (sends mail content over HTTPS)", isOn: $allowRemote)
                            .onChange(of: allowRemote) { Ollama.allowRemoteEndpoint = allowRemote }
                    }
                    if !ollamaModels.isEmpty {
                        ForEach(ollamaModels, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { !disabledOllama.contains(name) },
                                set: { enabled in
                                    if enabled { disabledOllama.remove(name) }
                                    else { disabledOllama.insert(name) }
                                    Ollama.disabledModels = disabledOllama
                                }))
                        }
                    } else if !ollamaListError.isEmpty {
                        Text(ollamaListError).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Refresh installed models") { Task { await loadOllamaModels() } }
                        .buttonStyle(.borderless)
                } header: {
                    Text("Local AI drafting (Ollama)")
                } footer: {
                    Text(endpointIsRemote
                         ? "This URL is not on this Mac. MishMail will only send message content there if you enable the toggle above, and only over HTTPS."
                         : "AI drafting runs entirely on this Mac via Ollama. Install from ollama.com, then run: ollama pull \(model). The Draft with AI button appears when replying.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Keep model in memory", selection: $keepAlive) {
                        Text("Unload right after the reply").tag(0)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("Until I quit MishMail").tag(-1)
                    }
                    .onChange(of: keepAlive) { Ollama.keepAliveSeconds = keepAlive }
                    Picker("Context length", selection: $contextTokens) {
                        Text("4K — smallest memory use").tag(4_096)
                        Text("8K").tag(8_192)
                        Text("16K — recommended").tag(16_384)
                        Text("32K").tag(32_768)
                        Text("Model default").tag(0)
                    }
                    .onChange(of: contextTokens) { Ollama.contextTokens = contextTokens }
                    Button("Unload local model now") {
                        Task { await Ollama.unloadAllLoadedByMishMail() }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Local model memory")
                } footer: {
                    Text("A local model holds its weights in memory after it answers. A shorter time frees memory sooner but reloads the model on the next request. Context length sizes the key/value cache — “Model default” can reserve many gigabytes on a large model.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    thinkingPicker("Ask Mish", task: .askMish)
                    thinkingPicker("Drafts", task: .drafts)
                    thinkingPicker("Summaries", task: .summaries)
                    thinkingPicker("Auto-sort", task: .triage)
                } header: {
                    Text("Thinking (local models)")
                } footer: {
                    Text("A thinking model reasons before it answers. That helps Ask Mish, and mostly wastes time on a one-word category or a short draft — one classification measured 11.4 s with thinking and 0.85 s without. Models that cannot think ignore this.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach([LLMOAuthVendor.claude, .chatGPT, .grok, .openRouter], id: \.self) { vendor in
                        subscriptionRow(vendor)
                    }
                } header: {
                    Text("Subscriptions")
                } footer: {
                    Text("One click signs you in with your existing account and pulls the model list. No API key paste is needed. Claude, ChatGPT, and Grok use a public CLI client, so the token can do more than chat. OpenRouter creates a key for this app. Prefer a pasted key when you have one.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(providers) { provider in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.label)
                                Text("\(provider.kind.rawValue) · \(provider.defaultModel)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if provider.id != LLMProviderStore.builtInOllamaID {
                                Button("Edit") { editingProvider = provider }
                                    .buttonStyle(.borderless)
                                Button(role: .destructive) { remove(provider) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button { addingProvider = true } label: {
                        Label("Add provider", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Model providers")
                } footer: {
                    Text("Add your own API keys here (OpenRouter, Groq, custom endpoints). Keys stay in your Keychain. Subscriptions connect in the section above.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(LLMTask.allCases, id: \.self) { task in
                        TaskModelPicker(task: task, providers: providers,
                                        ollamaModels: Ollama.enabledModels(installed: ollamaModels))
                    }
                } header: {
                    Text("Model per task")
                } footer: {
                    Text("Pick which model each feature uses. Keep triage on a small local model. Use a bigger model for drafts.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    if usage.isEmpty {
                        Text("No model usage in the last 30 days.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(usage, id: \.task) { spend in
                            HStack(spacing: 8) {
                                Text(taskTitle(spend.task))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(LLMPricing.compactCount(spend.promptTokens)) in / \(LLMPricing.compactCount(spend.completionTokens)) out")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(spend.estimatedUSD.map(LLMPricing.formatUSD) ?? "—")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 62, alignment: .trailing)
                            }
                        }
                    }
                    Button("Clear usage data", role: .destructive) {
                        showingClearUsageAlert = true
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Usage (30 days)")
                } footer: {
                    Text("Costs are estimates based on the saved model prices.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Auto-sort new mail", isOn: $autoClassify)
                    if autoClassify, triageSendsOffDevice {
                        Text("Auto-sort is on, but Triage uses a hosted model. New mail is not sent there. Pick a local model for Triage, or turn auto-sort off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("After each sync, quietly tag new inbox threads (Reply needed, FYI, Newsletter, Receipt) with the Triage model. Auto-sort only runs when that model is local (Ollama on this Mac or on your LAN). A cloud triage model would send every new snippet off this Mac, so auto-sort skips it. A small fast model like llama3.2:3b is ideal here.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Suggest replies when you reply", isOn: $suggestReplies)
                } footer: {
                    Text("Opening a reply shows up to three suggested responses inside the compose card. Uses the Triage model above; the strip names the model it used.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                MCPSettingsSection()
            }
            .formStyle(.grouped)
            .sheet(isPresented: $addingProvider) {
                ProviderEditSheet(provider: nil) { _ in
                    providers = LLMProviderStore.load()
                }
            }
            .sheet(item: $editingProvider) { provider in
                ProviderEditSheet(provider: provider) { _ in
                    providers = LLMProviderStore.load()
                }
            }
            .onAppear {
                loadUsage()
                Task { await loadOllamaModels() }
            }
            .alert("Clear usage data?", isPresented: $showingClearUsageAlert) {
                Button("Clear", role: .destructive) { clearUsage() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes all saved model usage data.")
            }
        }
    }

    private var triageSendsOffDevice: Bool {
        let assignment = LLMProviderStore.assignment(for: .triage)
        let config = providers.first { $0.id == assignment.providerID }
        return config.map(LLMRemotePolicy.blocksSilentAutoSort) ?? false
    }

    @ViewBuilder
    private func subscriptionRow(_ vendor: LLMOAuthVendor) -> some View {
        let preset = LLMProviderStore.subscriptionPreset(for: vendor)
        let connected = LLMProviderStore.subscriptionProvider(for: vendor, in: providers)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.label)
                if let status = vendorStatus[vendor], !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if let connected {
                    Text("Connected · \(connected.models?.count ?? 1) models")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if connectingVendor == vendor {
                ProgressView().controlSize(.small)
            } else if let connected {
                Button("Refresh models") { Task { await refreshModels(for: connected) } }
                    .buttonStyle(.borderless)
                Button("Sign out") { disconnect(connected) }
                    .buttonStyle(.borderless)
            } else {
                Button("Sign in with \(preset.label)") { Task { await connect(vendor) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(connectingVendor != nil)
            }
        }
    }

    /// One-click subscription connect: OAuth sign-in, then pull the model
    /// list. A failed listing falls back to known model names — the sign-in
    /// itself must still land.
    private func connect(_ vendor: LLMOAuthVendor) async {
        let preset = LLMProviderStore.subscriptionPreset(for: vendor)
        connectingVendor = vendor
        vendorStatus[vendor] = vendor == .grok
            ? "Requesting device code…" : "Waiting for browser sign-in…"
        defer { connectingVendor = nil }
        let id = UUID()
        var config = LLMProviderConfig(
            id: id, kind: preset.kind, label: preset.label, baseURL: preset.baseURL,
            defaultModel: preset.fallbackModels[0], authMode: .oauth(vendor))
        do {
            try await LLMOAuthFlow.signIn(vendor: vendor, providerID: id) { code, uri in
                vendorStatus[vendor] = "Enter code \(code) at \(uri)"
            }
        } catch {
            vendorStatus[vendor] = error.localizedDescription
            return
        }
        vendorStatus[vendor] = "Fetching models…"
        let fetched = (try? await LLMClient.shared.listModels(config: config)) ?? []
        var allModels = Set(fetched)
        allModels.formUnion(preset.fallbackModels)
        config.models = Array(allModels).sorted()
        config.defaultModel = AskMishModelMenu.preferredDefault(for: config)
        var list = LLMProviderStore.load().filter { $0.id != id }
        list.append(config)
        LLMProviderStore.save(list)
        providers = LLMProviderStore.load()
        vendorStatus[vendor] = fetched.isEmpty
            ? "Connected. Model listing not offered here; using known models." : ""
    }

    private func refreshModels(for provider: LLMProviderConfig) async {
        guard case .oauth(let vendor) = provider.authMode else { return }
        let preset = LLMProviderStore.subscriptionPreset(for: vendor)
        vendorStatus[vendor] = "Fetching models…"
        var allModels = Set(preset.fallbackModels)
        var fetchError: String?
        do {
            let fetched = try await LLMClient.shared.listModels(config: provider)
            allModels.formUnion(fetched)
        } catch {
            // Keep the fallback models plus whatever was fetched before, but
            // say the live listing failed.
            allModels.formUnion(provider.models ?? [])
            fetchError = error.localizedDescription
        }
        var updated = provider
        // A failed fetch must not reassign the default: the stored model may
        // simply be missing from the fallback list, and silently switching it
        // would change what later chats run on.
        if fetchError == nil, !updated.defaultModel.isEmpty {
            allModels.insert(updated.defaultModel)
        }
        updated.models = Array(allModels).sorted()
        if fetchError == nil {
            updated.defaultModel = AskMishModelMenu.preferredDefault(for: updated)
        }
        var list = LLMProviderStore.load().filter { $0.id != provider.id }
        list.append(updated)
        LLMProviderStore.save(list)
        providers = LLMProviderStore.load()
        vendorStatus[vendor] = fetchError.map { "Live model list failed (\($0)). Showing known models." } ?? ""
    }

    private func disconnect(_ provider: LLMProviderConfig) {
        if case .oauth(let vendor) = provider.authMode { vendorStatus[vendor] = "" }
        remove(provider)
    }

    private func loadOllamaModels() async {
        do {
            let installed = try await Ollama.installedModels()
            ollamaModels = installed
            ollamaListError = installed.isEmpty
                ? "Ollama has no models installed. Run: ollama pull llama3.2" : ""
        } catch {
            ollamaModels = []
            ollamaListError = "Couldn't reach Ollama at \(Ollama.baseURL)."
        }
    }

    /// Thinking-effort picker for one task. Bound straight to UserDefaults
    /// through `Ollama`, so it needs no view state of its own.
    private func thinkingPicker(_ label: String, task: LLMTask) -> some View {
        Picker(label, selection: Binding(
            get: { Ollama.thinking(for: task).rawValue },
            set: { Ollama.setThinking(LLMThinking(rawValue: $0), for: task) })) {
                Text("Off — fastest").tag("off")
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
                Text("Model default").tag("default")
            }
    }

    private func taskTitle(_ task: LLMTask) -> String {
        switch task {
        case .drafts: return "Drafts"
        case .summaries: return "Summaries"
        case .triage: return "Triage"
        case .askMish: return "Ask Mish"
        }
    }

    private func loadUsage() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        Task {
            let rows = (try? await AppDatabase.shared.dbPool.read { db in
                try LLMUsageRow
                    .filter(Column("createdAt") >= cutoff)
                    .fetchAll(db)
            }) ?? []
            let summary = LLMUsageLog.summarize(
                rows: rows, since: cutoff, overrides: LLMPricing.loadOverrides())
            await MainActor.run {
                usage = summary
            }
        }
    }

    private func clearUsage() {
        Task {
            do {
                _ = try await AppDatabase.shared.dbPool.write { db in
                    try LLMUsageRow.deleteAll(db)
                }
                await MainActor.run {
                    usage = []
                }
            } catch {
                // The button is intentionally quiet if the database is closing.
            }
        }
    }

    /// Drops the provider, its secrets, and any task still pointing at it, so
    /// no task is left assigned to a provider that no longer exists.
    private func remove(_ provider: LLMProviderConfig) {
        if OAuthConfig.usesKeychain(environment: ProcessInfo.processInfo.environment) {
            Keychain.delete(LLMProviderStore.keychainKey(for: provider.id))
            Keychain.delete(LLMProviderStore.oauthKeychainKey(for: provider.id))
        }
        var list = providers
        list.removeAll { $0.id == provider.id }
        LLMProviderStore.save(list)
        providers = LLMProviderStore.load()
        let fallback = LLMProviderStore.builtInOllama()
        for task in LLMTask.allCases
        where LLMProviderStore.assignment(for: task).providerID == provider.id {
            LLMProviderStore.setAssignment(
                LLMTaskAssignment(providerID: fallback.id, model: fallback.defaultModel),
                for: task)
        }
    }
}

/// One row of "Model per task": pick the exact provider + model a feature
/// uses. Subscription providers list their fetched models; Ollama lists the
/// locally installed (and not disabled) ones.
private struct TaskModelPicker: View {
    struct Entry: Hashable {
        let providerID: UUID
        let model: String
        let label: String
    }

    let task: LLMTask
    let providers: [LLMProviderConfig]
    let ollamaModels: [String]
    @State private var assignment: LLMTaskAssignment

    init(task: LLMTask, providers: [LLMProviderConfig], ollamaModels: [String]) {
        self.task = task
        self.providers = providers
        self.ollamaModels = ollamaModels
        _assignment = State(initialValue: LLMProviderStore.assignment(for: task))
    }

    private var entries: [Entry] {
        providers.flatMap { provider -> [Entry] in
            let models: [String]
            if provider.kind == .ollama {
                // Keep the stored default visible even if Ollama is down.
                models = ollamaModels.isEmpty ? [provider.defaultModel] : ollamaModels
            } else {
                var listed = provider
                var list = provider.models ?? []
                if !list.contains(provider.defaultModel) && !provider.defaultModel.isEmpty {
                    list.append(provider.defaultModel)
                }
                if let vendor = AskMishModelMenu.subscriptionVendor(of: provider) {
                    let preset = LLMProviderStore.subscriptionPreset(for: vendor)
                    for m in preset.fallbackModels where !list.contains(m) {
                        list.append(m)
                    }
                }
                listed.models = list
                let curated = AskMishModelMenu.models(for: listed).models
                models = curated.isEmpty ? [provider.defaultModel] : curated
            }
            return models.map {
                Entry(providerID: provider.id, model: $0, label: "\(provider.label) · \($0)")
            }
        }
    }

    private var title: String {
        switch task {
        case .drafts: return "Drafts"
        case .summaries: return "Summaries"
        case .triage: return "Triage"
        case .askMish: return "Ask Mish"
        }
    }

    /// A stored assignment can name a provider or model that is gone. Fall
    /// back to that provider's first entry, then to the built-in Ollama row.
    private var selected: Entry {
        let all = entries
        if let exact = all.first(where: {
            $0.providerID == assignment.providerID && $0.model == assignment.model
        }) { return exact }
        if let sameProvider = all.first(where: { $0.providerID == assignment.providerID }) {
            return sameProvider
        }
        return all.first(where: { $0.providerID == LLMProviderStore.builtInOllamaID })
            ?? Entry(providerID: LLMProviderStore.builtInOllamaID,
                     model: Ollama.model, label: "Ollama (local) · \(Ollama.model)")
    }

    var body: some View {
        Picker(title, selection: Binding(
            get: { selected },
            set: { entry in
                assignment = LLMTaskAssignment(providerID: entry.providerID, model: entry.model)
                LLMProviderStore.setAssignment(assignment, for: task)
            })) {
            ForEach(entries, id: \.self) { entry in
                Text(entry.label).tag(entry)
            }
        }
        // The provider list changes under us (add/edit/remove rewrites
        // assignments), so re-read the stored choice instead of trusting
        // the value this row started with.
        .onChange(of: providers) { assignment = LLMProviderStore.assignment(for: task) }
    }
}

/// Add or edit one provider. The key goes straight to the Keychain on save;
/// the sheet never re-displays a stored key.
private struct ProviderEditSheet: View {
    let provider: LLMProviderConfig?
    let onSave: (LLMProviderConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Preset {
        let name: String
        let kind: LLMProviderKind
        let baseURL: String
        let defaultModel: String
        let keyHint: String
    }
    private static let presets: [Preset] = [
        Preset(name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com",
               defaultModel: "claude-opus-5", keyHint: "console.anthropic.com"),
        Preset(name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1",
               defaultModel: "gpt-5", keyHint: "platform.openai.com"),
        Preset(name: "Google Gemini", kind: .openAICompatible,
               baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
               defaultModel: "gemini-3.7-flash", keyHint: "aistudio.google.com"),
        Preset(name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1",
               defaultModel: "openai/gpt-4o", keyHint: "openrouter.ai/keys"),
        Preset(name: "Grok (xAI)", kind: .openAICompatible, baseURL: "https://api.x.ai/v1",
               defaultModel: "grok-4.6", keyHint: "console.x.ai"),
        Preset(name: "Groq", kind: .openAICompatible, baseURL: "https://api.groq.com/openai/v1",
               defaultModel: "", keyHint: "console.groq.com"),
    ]

    @State private var presetIndex = 0
    @State private var label = ProviderEditSheet.presets[0].name
    @State private var baseURL = ProviderEditSheet.presets[0].baseURL
    @State private var modelID = ProviderEditSheet.presets[0].defaultModel
    @State private var apiKey = ""
    @State private var useOAuth = true
    @State private var models: [String] = []
    @State private var status = ""
    /// One id per sheet lifetime for a brand-new provider. Both fetchModels()
    /// and save() must use it, or the key written before a fetch becomes
    /// unreachable under a second, different UUID.
    @State private var draftID = UUID()
    /// onAppear sets presetIndex programmatically, which fires onChange. Suppress
    /// the preset-applied reset once so a stored custom Base URL survives editing.
    @State private var suppressPresetApply = false
    @State private var hostConsent = false

    private var kind: LLMProviderKind { Self.presets[presetIndex].kind }
    private var oauthVendor: LLMOAuthVendor? {
        switch Self.presets[presetIndex].name {
        case "Anthropic": return .claude
        case "OpenAI": return .chatGPT
        case "Grok (xAI)": return .grok
        case "OpenRouter": return .openRouter
        default: return nil
        }
    }

    private static func vendorLabel(_ vendor: LLMOAuthVendor) -> String {
        switch vendor {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .grok: return "Grok"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        }
    }

    /// Demo and UI-test processes never touch the Keychain, so a pasted key
    /// would be dropped without a word. Block saving there instead.
    private var canStoreSecrets: Bool {
        OAuthConfig.usesKeychain(environment: ProcessInfo.processInfo.environment)
    }

    private var customOrigin: String? {
        guard let origin = LLMRemotePolicy.origin(of: baseURL),
              let host = LLMRemotePolicy.host(of: baseURL),
              !LLMRemotePolicy.isKnownHost(host),
              let url = URL(string: LLMEndpoint.trimmedBase(baseURL)),
              !LLMEndpoint.isLoopback(url) else { return nil }
        return origin
    }

    private var saveDisabled: Bool {
        !canStoreSecrets || label.isEmpty || modelID.isEmpty
            || (!useOAuth && apiKey.isEmpty && provider == nil)
            || (customOrigin != nil && !hostConsent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(provider == nil ? "Add provider" : "Edit provider").font(.headline)
            Picker("Preset", selection: $presetIndex) {
                ForEach(Self.presets.indices, id: \.self) { i in
                    Text(Self.presets[i].name).tag(i)
                }
            }
            .onChange(of: presetIndex) {
                // A programmatic change from onAppear must not overwrite the
                // stored Base URL of an existing provider.
                if suppressPresetApply {
                    suppressPresetApply = false
                    return
                }
                let preset = Self.presets[presetIndex]
                baseURL = preset.baseURL
                label = preset.name
                modelID = preset.defaultModel
                useOAuth = oauthVendor != nil && provider == nil
                if let vendor = oauthVendor {
                    let fallback = LLMProviderStore.subscriptionPreset(for: vendor).fallbackModels
                    models = fallback
                    if modelID.isEmpty, let first = fallback.first { modelID = first }
                }
            }
            if let vendor = oauthVendor {
                Picker("Sign in with", selection: $useOAuth) {
                    Text("\(Self.vendorLabel(vendor)) subscription").tag(true)
                    Text("API key").tag(false)
                }
                .pickerStyle(.segmented)
                Text(useOAuth
                     ? (vendor == .openRouter
                        ? "Save opens your browser to sign in. OpenRouter creates an API key for this app. Usage uses your OpenRouter credits."
                        : "Save opens your browser to sign in. No key is needed. Usage counts against your subscription, so no dollar cost is shown.")
                     : "Paste an API key from \(Self.presets[presetIndex].keyHint). The key stays in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(Self.presets[presetIndex].name) does not offer a subscription sign-in. Paste an API key from \(Self.presets[presetIndex].keyHint).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !useOAuth {
                SecureField("API key", text: $apiKey)
            }
            TextField("Label", text: $label)
            TextField("Base URL", text: $baseURL)
                .onChange(of: customOrigin) { _, origin in
                    if let existing = provider,
                       let origin,
                       let stored = LLMProviderStore.consentedHost(for: existing.id),
                       stored == origin
                        || stored == LLMRemotePolicy.host(of: existing.baseURL) {
                        hostConsent = true
                    } else if origin != nil {
                        hostConsent = false
                    }
                }
            if let origin = customOrigin {
                Toggle("Mail from this Mac will go to \(origin).", isOn: $hostConsent)
                    .font(.caption)
            }
            HStack {
                TextField("Model", text: $modelID)
                Button("Fetch models") { Task { await fetchModels() } }
                    .disabled(!canStoreSecrets)
            }
            if !models.isEmpty {
                Picker("Available", selection: $modelID) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            if !canStoreSecrets {
                Text("This build cannot store keys. Quit and run make run DEMO=0 to add a provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveDisabled)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            guard let existing = provider else {
                if let vendor = oauthVendor {
                    models = LLMProviderStore.subscriptionPreset(for: vendor).fallbackModels
                }
                return
            }
            label = existing.label
            baseURL = existing.baseURL
            modelID = existing.defaultModel
            models = existing.models ?? []
            if existing.baseURL.contains("generativelanguage.googleapis.com") {
                let fallback = LLMProviderStore.subscriptionPreset(for: .gemini).fallbackModels
                for m in fallback where !models.contains(m) {
                    models.append(m)
                }
            }
            if !models.contains(modelID) && !modelID.isEmpty {
                models.append(modelID)
            }
            let matched = Self.presets.firstIndex { $0.baseURL == existing.baseURL }
                ?? Self.presets.firstIndex { $0.kind == existing.kind }
                ?? 0
            if matched != presetIndex {
                suppressPresetApply = true
                presetIndex = matched
            }
            if case .oauth = existing.authMode { useOAuth = true } else { useOAuth = false }
            if let origin = LLMRemotePolicy.origin(of: existing.baseURL),
               let stored = LLMProviderStore.consentedHost(for: existing.id),
               stored == origin || stored == LLMRemotePolicy.host(of: existing.baseURL) {
                hostConsent = true
            }
        }
    }

    private func currentConfig(id: UUID) -> LLMProviderConfig {
        var allModels = models
        if !modelID.isEmpty && !allModels.contains(modelID) {
            allModels.append(modelID)
        }
        if let vendor = oauthVendor {
            let preset = LLMProviderStore.subscriptionPreset(for: vendor)
            for m in preset.fallbackModels where !allModels.contains(m) {
                allModels.append(m)
            }
        }
        return LLMProviderConfig(
            id: id, kind: kind, label: label, baseURL: baseURL, defaultModel: modelID,
            authMode: useOAuth ? .oauth(oauthVendor ?? .claude) : .apiKey,
            models: allModels.isEmpty ? nil : allModels.sorted(),
            // Editing a provider must not wipe the user's picker pins.
            pinnedModels: provider?.pinnedModels)
    }

    private func fetchModels() async {
        guard canStoreSecrets else { return }
        status = "Fetching…"
        let id = provider?.id ?? draftID
        if !useOAuth, !apiKey.isEmpty {
            try? Keychain.set(apiKey, forKey: LLMProviderStore.keychainKey(for: id))
        }
        do {
            let fetched = try await LLMClient.shared.listModels(config: currentConfig(id: id))
            var combined = Set(fetched)
            if let vendor = oauthVendor {
                let preset = LLMProviderStore.subscriptionPreset(for: vendor)
                combined.formUnion(preset.fallbackModels)
            }
            models = Array(combined).sorted()
            status = models.isEmpty ? "No models returned." : "Found \(models.count) models."
        } catch {
            if let vendor = oauthVendor {
                let preset = LLMProviderStore.subscriptionPreset(for: vendor)
                models = preset.fallbackModels
                status = "Using known models (\(models.count))."
            } else {
                status = error.localizedDescription
            }
        }
    }

    private func save() async {
        guard canStoreSecrets else { return }
        let id = provider?.id ?? draftID
        let config = currentConfig(id: id)
        do {
            if useOAuth, let vendor = oauthVendor {
                status = "Waiting for browser sign-in…"
                try await LLMOAuthFlow.signIn(vendor: vendor, providerID: id) { code, uri in
                    status = "Enter code \(code) at \(uri) to finish sign-in…"
                }
            } else if !apiKey.isEmpty {
                try Keychain.set(apiKey, forKey: LLMProviderStore.keychainKey(for: id))
            }
            var list = LLMProviderStore.load().filter { $0.id != id }
            list.append(config)
            LLMProviderStore.save(list)
            if let origin = customOrigin, hostConsent {
                LLMProviderStore.setConsentedHost(origin, for: id)
            } else if customOrigin == nil {
                LLMProviderStore.setConsentedHost(nil, for: id)
            }
            onSave(config)
            dismiss()
        } catch {
            status = error.localizedDescription
        }
    }
}

/// Settings block for the in-process MCP Streamable HTTP server.
private struct MCPSettingsSection: View {
    @Environment(MailStore.self) private var store
    @State private var copied = false
    @State private var client: MCPConnectSnippets.Client = .claudeCode
    @State private var portText = ""

    var body: some View {
        Section {
            Toggle("Enable MCP server", isOn: Binding(
                get: { store.isMCPEnabled },
                set: { store.isMCPEnabled = $0 }
            ))
            LabeledContent("Port") {
                TextField("41888", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(applyPort)
                    .onAppear { portText = "\(store.mcpPreferredPort)" }
            }
            if store.mcpRunning, let port = store.mcpPort {
                LabeledContent("Discovery file") {
                    Text(store.mcpDiscoveryURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let token = store.mcpToken {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Connect command", selection: $client) {
                            ForEach(MCPConnectSnippets.Client.allCases) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .pickerStyle(.menu)
                        Text(MCPConnectSnippets.snippet(for: client, port: port, token: token))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                MCPConnectSnippets.snippet(for: client, port: port, token: token),
                                forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy connect command",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("MCP")
        } footer: {
            Text("Lets local AI agents (Claude Code, Codex, etc.) read mail, manage drafts, set thread summaries, and edit VIPs over 127.0.0.1. Off by default; the bearer token lives in your Keychain and is not written to mcp.json. A fixed port keeps agent configs valid across relaunches — set 0 for a random port each launch.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Persist the port field (restarts the server if running). Non-numeric
    /// input reverts to the stored value.
    private func applyPort() {
        guard let n = Int(portText.trimmingCharacters(in: .whitespaces)), (0...65535).contains(n) else {
            portText = "\(store.mcpPreferredPort)"
            return
        }
        store.mcpPreferredPort = n
        portText = "\(store.mcpPreferredPort)"
    }
}
