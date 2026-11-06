import Foundation

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
    case outbox         // drafts saved offline, waiting to upload (not Gmail threads)
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
        case .outbox: return "Outbox"
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
        case .scheduled, .outbox, .saved: return nil
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
    enum ReadFilter { case any, read, unread }
    enum PresenceFilter { case any, present, absent }

    var read: ReadFilter = .any
    var attachments: PresenceFilter = .any
    var calendar: PresenceFilter = .any
    var unreadOnly: Bool { read == .unread }
    var readOnly: Bool { read == .read }
    var hasAttachmentOnly: Bool { attachments == .present }
    var noAttachmentOnly: Bool { attachments == .absent }
    var calendarOnly: Bool { calendar == .present }
    var hideCalendar: Bool { calendar == .absent }

    var category = CategoryFilter()
    var showArchived = false
    var labelId: String?
    var labelName: String?
    var labelExclude = false
    var senderContains = ""
    var senderExclude = false
    var fromEmailContains: String?
    var showSent = false
    var toContains = ""
    var ccContains = ""
    var bccContains = ""
    var subjectContains = ""
    var dateWindow: DateWindow?

    init() {}

    // Keep saved views readable in both directions across app versions.
    private enum CodingKeys: String, CodingKey {
        case unreadOnly, readOnly, hasAttachmentOnly, noAttachmentOnly, calendarOnly, hideCalendar
        case category, showArchived, labelId, labelName, labelExclude, senderContains, senderExclude
        case fromEmailContains, showSent, toContains, ccContains, bccContains, subjectContains, dateWindow
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func enabled(_ key: CodingKeys) throws -> Bool {
            try values.decodeIfPresent(Bool.self, forKey: key) ?? false
        }
        // The positive choice wins for contradictory legacy flags, e.g. a
        // saved view whose editor enabled Unread over a previous Read filter.
        read = try enabled(.unreadOnly) ? .unread : enabled(.readOnly) ? .read : .any
        attachments = try enabled(.hasAttachmentOnly) ? .present : enabled(.noAttachmentOnly) ? .absent : .any
        calendar = try enabled(.calendarOnly) ? .present : enabled(.hideCalendar) ? .absent : .any
        category = try values.decodeIfPresent(CategoryFilter.self, forKey: .category) ?? CategoryFilter()
        showArchived = try values.decodeIfPresent(Bool.self, forKey: .showArchived) ?? false
        labelId = try values.decodeIfPresent(String.self, forKey: .labelId)
        labelName = try values.decodeIfPresent(String.self, forKey: .labelName)
        labelExclude = try values.decodeIfPresent(Bool.self, forKey: .labelExclude) ?? false
        senderContains = try values.decodeIfPresent(String.self, forKey: .senderContains) ?? ""
        senderExclude = try values.decodeIfPresent(Bool.self, forKey: .senderExclude) ?? false
        fromEmailContains = try values.decodeIfPresent(String.self, forKey: .fromEmailContains)
        showSent = try values.decodeIfPresent(Bool.self, forKey: .showSent) ?? false
        toContains = try values.decodeIfPresent(String.self, forKey: .toContains) ?? ""
        ccContains = try values.decodeIfPresent(String.self, forKey: .ccContains) ?? ""
        bccContains = try values.decodeIfPresent(String.self, forKey: .bccContains) ?? ""
        subjectContains = try values.decodeIfPresent(String.self, forKey: .subjectContains) ?? ""
        dateWindow = try values.decodeIfPresent(DateWindow.self, forKey: .dateWindow)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(category, forKey: .category)
        try values.encode(showArchived, forKey: .showArchived)
        try values.encodeIfPresent(labelId, forKey: .labelId)
        try values.encodeIfPresent(labelName, forKey: .labelName)
        try values.encode(labelExclude, forKey: .labelExclude)
        try values.encode(senderContains, forKey: .senderContains)
        try values.encode(senderExclude, forKey: .senderExclude)
        try values.encodeIfPresent(fromEmailContains, forKey: .fromEmailContains)
        try values.encode(showSent, forKey: .showSent)
        try values.encode(toContains, forKey: .toContains)
        try values.encode(ccContains, forKey: .ccContains)
        try values.encode(bccContains, forKey: .bccContains)
        try values.encode(subjectContains, forKey: .subjectContains)
        try values.encodeIfPresent(dateWindow, forKey: .dateWindow)
        try values.encode(unreadOnly, forKey: .unreadOnly)
        try values.encode(readOnly, forKey: .readOnly)
        try values.encode(hasAttachmentOnly, forKey: .hasAttachmentOnly)
        try values.encode(noAttachmentOnly, forKey: .noAttachmentOnly)
        try values.encode(calendarOnly, forKey: .calendarOnly)
        try values.encode(hideCalendar, forKey: .hideCalendar)
    }

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
