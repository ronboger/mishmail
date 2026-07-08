import SwiftUI
import UniformTypeIdentifiers

/// Notion Mail-style settings window: a slim sidebar of panes on the left,
/// the selected pane on the right. Opens with Cmd-, or from the app sidebar.
struct SettingsView: View {
    @EnvironmentObject var store: MailStore

    enum Pane: String, Identifiable {
        case accounts, googleAPI, filters, snippets, appearance, shortcuts, ai, updates

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accounts: return "Accounts"
            case .googleAPI: return "Google API"
            case .filters: return "Gmail filters"
            case .snippets: return "Snippets"
            case .appearance: return "Appearance"
            case .shortcuts: return "Keyboard shortcuts"
            case .ai: return "AI"
            case .updates: return "Updates"
            }
        }

        var icon: String {
            switch self {
            case .accounts: return "person.2"
            case .googleAPI: return "key"
            case .filters: return "line.3.horizontal.decrease"
            case .snippets: return "curlybraces"
            case .appearance: return "textformat.size"
            case .shortcuts: return "keyboard"
            case .ai: return "sparkles"
            case .updates: return "arrow.down.circle"
            }
        }
    }

    @State private var pane: Pane = .accounts
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $pane) {
                Section("Account") {
                    row(.accounts)
                    row(.googleAPI)
                    row(.filters)
                    row(.snippets)
                }
                Section("App") {
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
        case .accounts: AccountsSettings()
        case .googleAPI: GoogleAPISettings()
        case .filters: GmailFiltersSettings()
        case .snippets: SnippetsSettings()
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
        }
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

    var body: some View {
        PaneScaffold(title: "Google API") {
            Form {
                if editing {
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
            if editing, !OAuthConfig.isConfigured, !trimmedID.isEmpty {
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
                            Button("Update App") { updates.openUpdate() }
                                .buttonStyle(.borderedProminent)
                            Button("View on GitHub") {
                                NSWorkspace.shared.open(release.htmlURL)
                            }
                        }
                    } else if let status = updates.status {
                        Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Update App downloads the latest release; drag the new PerfectMail into Applications to replace this copy. The app also checks quietly once a day and shows an update button in the sidebar when one is available.")
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
                        .disabled(updates.checking)
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
    @EnvironmentObject var store: MailStore

    var body: some View {
        PaneScaffold(title: "Accounts") {
            Form {
                ForEach(store.accounts) { account in
                    Section {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.id)
                                if let last = account.lastSyncAt {
                                    Text("Last sync \(last, format: .relative(presentation: .named))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Remove Account", role: .destructive) {
                                store.removeAccount(account.id)
                            }
                        }
                        SyncWindowPicker(accountId: account.id)
                    }
                }
                Section {
                    Button("Add Google Account…") { store.addAccount() }
                } footer: {
                    Text("Keep mail from controls what is stored on this Mac per account — Gmail itself is never changed. Narrowing it (or choosing Nothing) removes the older local copies; widening downloads older mail in the background. Starred mail is always kept and downloaded regardless of age.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Gmail filters (read-only, Notion Mail-style sentences)

struct GmailFiltersSettings: View {
    @EnvironmentObject var store: MailStore
    // One value per account with exactly two cases, so filters and errors
    // can't drift out of sync.
    private enum LoadState {
        case loaded([GFilter])
        case failed(String)
    }
    @State private var results: [String: LoadState] = [:]
    @State private var loading = false

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
                        if loading { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Edit filters in Gmail…") {
                            NSWorkspace.shared.open(
                                URL(string: "https://mail.google.com/mail/u/0/#settings/filters")!)
                        }
                        .font(.system(size: 12))
                    }
                    .padding(20)
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func accountSection(_ accountId: String) -> some View {
        switch results[accountId] {
        case .failed(let error):
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 10)
        case .loaded(let filters):
            if filters.isEmpty {
                Text("No filters set up in Gmail for this account.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
            ForEach(filters) { filter in
                FilterRowView(filter: filter, accountId: accountId)
                Divider().padding(.leading, 20)
            }
        case nil:
            EmptyView()
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // Accounts fetch concurrently; results land as each one finishes.
        await withTaskGroup(of: (String, Result<[GFilter], Error>).self) { group in
            for account in store.accounts {
                let id = account.id
                let client = store.client(for: id)
                group.addTask {
                    do { return (id, .success(try await client.listFilters())) }
                    catch { return (id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let filters):
                    results[id] = .loaded(filters)
                case .failure(GmailError.http(403, _)):
                    results[id] = .failed(
                        "PerfectMail doesn't have permission to read this account's filters yet. Remove and re-add the account (Accounts pane) to grant it.")
                case .failure(let error):
                    results[id] = .failed(error.localizedDescription)
                }
            }
        }
    }
}

/// One filter rendered as a Notion Mail-style sentence:
/// "If mail is from x@y.com, then Add label ian and Skip inbox".
private struct FilterRowView: View {
    @EnvironmentObject var store: MailStore
    let filter: GFilter
    let accountId: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: Circle())
            sentence
                .font(.system(size: 13))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var iconName: String {
        let adds = filter.action?.addLabelIds ?? []
        if filter.action?.forward != nil { return "arrowshape.turn.up.right" }
        if adds.contains(where: { !["TRASH", "SPAM", "STARRED", "IMPORTANT"].contains($0)
                                  && !$0.hasPrefix("CATEGORY_") }) { return "tag" }
        if adds.contains("TRASH") { return "trash" }
        if adds.contains("SPAM") || (filter.action?.removeLabelIds ?? []).contains("SPAM") {
            return "nosign"
        }
        return "line.3.horizontal.decrease"
    }

    private var sentence: Text {
        let conditions = conditionPhrases
        let actions = actionPhrases
        var t = Text("If mail ").foregroundColor(.secondary)
        for (i, c) in conditions.enumerated() {
            if i > 0 { t = t + Text(" and ").foregroundColor(.secondary) }
            t = t + c.styled
        }
        t = t + Text(", then ").foregroundColor(.secondary)
        for (i, a) in actions.enumerated() {
            if i > 0 { t = t + Text(" and ").foregroundColor(.secondary) }
            t = t + a.styled
        }
        return t
    }

    /// A phrase with plain lead-in text and an emphasized (accent) value.
    private struct Phrase {
        var plain: String
        var value: String = ""

        var styled: Text {
            let lead = Text(plain).foregroundColor(.primary)
            guard !value.isEmpty else { return lead }
            return lead + Text(value).foregroundColor(.accentColor)
        }
    }

    private var conditionPhrases: [Phrase] {
        var out: [Phrase] = []
        if let from = filter.criteria?.from { out.append(.init(plain: "is from ", value: from)) }
        if let to = filter.criteria?.to { out.append(.init(plain: "is to ", value: to)) }
        if let subject = filter.criteria?.subject { out.append(.init(plain: "has subject ", value: subject)) }
        if let query = filter.criteria?.query { out.append(.init(plain: "matches ", value: query)) }
        if let negated = filter.criteria?.negatedQuery { out.append(.init(plain: "does not match ", value: negated)) }
        if filter.criteria?.hasAttachment == true { out.append(.init(plain: "has an attachment")) }
        if let size = filter.criteria?.size {
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(size),
                                                      countStyle: .binary)
            let comparison = filter.criteria?.sizeComparison == "smaller" ? "smaller" : "larger"
            out.append(.init(plain: "is \(comparison) than ", value: formatted))
        }
        if out.isEmpty { out.append(.init(plain: "arrives")) }
        return out
    }

    private var actionPhrases: [Phrase] {
        var out: [Phrase] = []
        for id in filter.action?.addLabelIds ?? [] {
            switch id {
            case "TRASH": out.append(.init(plain: "Delete it"))
            case "STARRED": out.append(.init(plain: "Star it"))
            case "IMPORTANT": out.append(.init(plain: "Always mark it as important"))
            case "SPAM": out.append(.init(plain: "Send it to Spam"))
            case let cat where cat.hasPrefix("CATEGORY_"):
                let name = cat.dropFirst("CATEGORY_".count).capitalized
                out.append(.init(plain: "Categorize as ", value: name))
            default:
                let name = store.labelName(id, account: accountId) ?? id
                out.append(.init(plain: "Add label ", value: name))
            }
        }
        for id in filter.action?.removeLabelIds ?? [] {
            switch id {
            case "INBOX": out.append(.init(plain: "Skip inbox"))
            case "UNREAD": out.append(.init(plain: "Mark it as read"))
            case "SPAM": out.append(.init(plain: "Never send it to Spam"))
            case "IMPORTANT": out.append(.init(plain: "Never mark it as important"))
            default:
                let name = store.labelName(id, account: accountId) ?? id
                out.append(.init(plain: "Remove label ", value: name))
            }
        }
        if let forward = filter.action?.forward {
            out.append(.init(plain: "Forward to ", value: forward))
        }
        if out.isEmpty { out.append(.init(plain: "do nothing")) }
        return out
    }
}

// MARK: - Snippets (Notion Mail-style table with search + editor sheet)

struct SnippetsSettings: View {
    @EnvironmentObject var store: MailStore
    @State private var search = ""
    @State private var editing: Snippet?
    // Cached so search keystrokes and store publishes don't re-query
    // SQLite; reloaded after every create/edit/delete.
    @State private var all: [Snippet] = []
    @State private var showImporter = false
    @State private var importResult: String?

    private var filtered: [Snippet] {
        all.filter { $0.matches(search) }
    }

    var body: some View {
        PaneScaffold(title: "Snippets",
                     subtitle: "Reusable text you can drop into any email by typing / in compose") {
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
                        .help("Import snippets from a JSON file: [{\"name\", \"body\", \"movesToBcc\"}]")
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
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 6)
                Divider().padding(.horizontal, 20)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { snippet in
                            SnippetTableRow(snippet: snippet,
                                            edit: { editing = snippet },
                                            delete: {
                                                store.deleteSnippet(snippet)
                                                all = store.snippets()
                                            })
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
                }
            }
        }
        .onAppear { all = store.snippets() }
        .sheet(item: $editing, onDismiss: { all = store.snippets() }) { snippet in
            SnippetEditor(snippet: snippet)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do {
                    let counts = try store.importSnippets(from: url)
                    all = store.snippets()
                    importResult = counts.skipped == 0
                        ? "Imported \(counts.added)"
                        : "Imported \(counts.added), skipped \(counts.skipped) existing"
                } catch {
                    importResult = "Import failed: \(error.localizedDescription)"
                }
            case .failure:
                break
            }
        }
    }
}

private struct SnippetTableRow: View {
    let snippet: Snippet
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
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
            Menu {
                Button("Edit…") { edit() }
                Button("Delete", role: .destructive) { delete() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { edit() }
    }
}

private struct SnippetEditor: View {
    @EnvironmentObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    let snippet: Snippet
    @State private var name: String
    @State private var body_: String
    @State private var movesToBcc: Bool

    init(snippet: Snippet) {
        self.snippet = snippet
        _name = State(initialValue: snippet.name)
        _body_ = State(initialValue: snippet.body)
        _movesToBcc = State(initialValue: snippet.movesToBcc)
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
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if snippet.id == nil {
                        store.saveSnippet(name: name, body: body_, movesToBcc: movesToBcc)
                    } else {
                        var updated = snippet
                        updated.name = name
                        updated.body = body_
                        updated.movesToBcc = movesToBcc
                        store.updateSnippet(updated)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || body_.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

struct AppearanceSettings: View {
    @EnvironmentObject var store: MailStore
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("badgeScope") private var badgeScopeRaw = MailStore.BadgeScope.all.rawValue
    @AppStorage("priorityMode") private var priorityModeRaw = PrioritySplit.Mode.starred.rawValue
    @AppStorage("vipAlwaysPins") private var vipAlwaysPins = true
    @State private var showVIPManager = false

    private var priorityMode: PrioritySplit.Mode {
        PrioritySplit.Mode(rawValue: priorityModeRaw) ?? .starred
    }

    var body: some View {
        PaneScaffold(title: "Appearance") {
            Form {
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
                    }
                } footer: {
                    Text("What pins to the top of the Inbox. VIPs only is the tightest — just mail from your VIP senders. Starred is what you've hand-picked; Starred + Important adds everything Gmail predicts matters, which can be a lot.")
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
                    Text("New mail from these addresses pins to Priority the moment it arrives. You can also right-click any thread → Add sender to VIPs.")
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
    @EnvironmentObject var store: MailStore
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
            let group = store.vipGroups[email] ?? "No group"
            if groups[group] == nil {
                groups[group] = []
            }
            groups[group]?.append(email)
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
                        if let emails = groupedEmails[groupName]?.sorted() {
                            Section(header: Text(groupName).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)) {
                                ForEach(emails, id: \.self) { email in
                                    VIPRow(email: email,
                                           groupName: store.vipGroups[email],
                                           allGroups: store.allVIPGroupNames,
                                           remove: { store.removeVIP(email) },
                                           setGroup: { store.setVIPGroup(email, group: $0) })
                                }
                            }
                        }
                    }
                    if let noGroupEmails = groupedEmails["No group"]?.sorted() {
                        Section(header: Text("No group").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)) {
                            ForEach(noGroupEmails, id: \.self) { email in
                                VIPRow(email: email,
                                       groupName: store.vipGroups[email],
                                       allGroups: store.allVIPGroupNames,
                                       remove: { store.removeVIP(email) },
                                       setGroup: { store.setVIPGroup(email, group: $0) })
                            }
                        }
                    }
                    if store.vipEmails.isEmpty {
                        Text("No VIP senders yet — add one above, paste a list below, or right-click any thread → Add sender to VIPs.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 180)
            } else {
                List {
                    ForEach(visibleEmails, id: \.self) { email in
                        VIPRow(email: email,
                               groupName: store.vipGroups[email],
                               allGroups: store.allVIPGroupNames,
                               remove: { store.removeVIP(email) },
                               setGroup: { store.setVIPGroup(email, group: $0) })
                    }
                    if store.vipEmails.isEmpty {
                        Text("No VIP senders yet — add one above, paste a list below, or right-click any thread → Add sender to VIPs.")
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

/// Compact group picker for add/bulk fields.
private struct GroupPickerCompact: View {
    @Binding var selectedGroup: String
    let allGroups: [String]
    @State private var newGroupText = ""
    @State private var showNewGroup = false

    private var displayText: String {
        selectedGroup.isEmpty ? "group" : selectedGroup
    }

    var body: some View {
        if showNewGroup {
            HStack(spacing: 4) {
                TextField("New", text: $newGroupText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Button("OK") {
                    if !newGroupText.trimmingCharacters(in: .whitespaces).isEmpty {
                        selectedGroup = newGroupText.trimmingCharacters(in: .whitespaces)
                        newGroupText = ""
                        showNewGroup = false
                    }
                }
                .font(.system(size: 11))
            }
        } else {
            Menu {
                Button("No group") {
                    selectedGroup = ""
                }
                Divider()
                ForEach(allGroups.sorted(), id: \.self) { group in
                    Button(group) {
                        selectedGroup = group
                    }
                }
                Divider()
                Button("New group…") {
                    showNewGroup = true
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text(displayText)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
            .frame(width: 90)
        }
    }
}

/// One VIP list row with group picker and always-visible remove button.
private struct VIPRow: View {
    let email: String
    let groupName: String?
    let allGroups: [String]
    let remove: () -> Void
    let setGroup: (String?) -> Void

    private var currentGroup: String {
        groupName ?? "No group"
    }

    var body: some View {
        HStack {
            Text(email)
                .lineLimit(1)
            Spacer()
            Menu {
                Button("No group") {
                    setGroup(nil)
                }
                Divider()
                ForEach(allGroups.sorted(), id: \.self) { group in
                    Button(group) {
                        setGroup(group)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text(currentGroup)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
            .frame(width: 100)
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
    @AppStorage(MailStore.autoClassifyKey) private var autoClassify = true

    var body: some View {
        PaneScaffold(title: "AI") {
            Form {
                Section {
                    TextField("Ollama URL", text: $url)
                        .onChange(of: url) { Ollama.baseURL = url }
                    TextField("Model", text: $model)
                        .onChange(of: model) { Ollama.model = model }
                } header: {
                    Text("Local AI drafting (Ollama)")
                } footer: {
                    Text("AI drafting runs entirely on this Mac via Ollama. Install from ollama.com, then run: ollama pull \(model). The Draft with AI button appears when replying.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Auto-sort new mail", isOn: $autoClassify)
                } footer: {
                    Text("After each sync, quietly tag new inbox threads (Reply needed, FYI, Newsletter, Receipt) with the local model. Skips silently when Ollama isn't running. A small fast model like llama3.2:3b is ideal here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}
