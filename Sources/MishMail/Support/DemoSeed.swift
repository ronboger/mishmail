import Foundation
import GRDB

/// Fills the database with realistic but entirely fictional mail
/// so the app can be screenshotted for the README without touching a real
/// Gmail account. Everything here is fake — names, addresses, and bodies are
/// invented — so nothing private can leak into a screenshot.
///
/// Activated by launching Debug with `MISHMAIL_DEMO=1` (see `make demo`) or by
/// choosing “Try demo inbox” during first-run setup. The persisted path is
/// allowed only while there are no real accounts, and exiting removes the
/// fictional mailbox again.
enum DemoSeed {
    private static let defaultsKey = "demoModeEnabled"

    static var isActive: Bool {
        ProcessInfo.processInfo.environment["MISHMAIL_DEMO"] == "1"
            || UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static let account = "you@example.com"
    static let vipSenders: Set<String> = ["dana@brightloop.io", "priya@example.edu"]

    static func canActivate(accountIDs: [String]) -> Bool {
        accountIDs.isEmpty || accountIDs.allSatisfy { $0 == account }
    }

    @discardableResult
    static func activate(_ db: DatabasePool) -> Bool {
        guard let existing = accountIDs(in: db), canActivate(accountIDs: existing),
              seed(db) else { return false }
        UserDefaults.standard.set(true, forKey: defaultsKey)
        return true
    }

    /// Removes only rows owned by the fictional account. This remains safe if
    /// an older build accidentally allowed a real account to coexist with it.
    @discardableResult
    static func deactivate(_ db: DatabasePool) -> Bool {
        guard clearDemoData(db) else { return false }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return true
    }

    /// Wipes demo-owned mail tables and inserts a fresh inbox. Idempotent:
    /// every demo launch reseeds from scratch, so screenshots are deterministic.
    @discardableResult
    static func seedIfRequested(_ db: DatabasePool) -> Bool {
        guard isActive else { return false }
        // A read failure is not an empty database. Abort instead of treating
        // uncertainty as permission to modify persistent mail state.
        guard let existing = accountIDs(in: db) else { return false }
        guard canActivate(accountIDs: existing) else {
            NSLog("MishMail: demo seed skipped — a real account is signed in")
            // Recover state left by an older mixed-account build. Cleanup is
            // demo-account-scoped, so the real mailbox remains untouched.
            if !existing.contains(account) || clearDemoData(db) {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
            return false
        }
        return seed(db)
    }

    private static func accountIDs(in db: DatabasePool) -> [String]? {
        do {
            return try db.read { try String.fetchAll($0, sql: "SELECT id FROM account") }
        } catch {
            NSLog("MishMail: demo account check failed — %@", "\(error)")
            return nil
        }
    }

    /// Clear + insert is one transaction: a failed fixture insert rolls the
    /// cleanup back instead of leaving a half-created demo mailbox.
    private static func seed(_ db: DatabasePool) -> Bool {
        do {
            try db.write { database in
                try clearDemoData(in: database)

                let acct = Account(id: account, displayName: "Personal",
                                   historyId: nil, lastSyncAt: Date(), senderName: "Alex Rivera")
                try acct.insert(database)

                for label in userLabels {
                    let row = LabelRow(id: "\(account):\(label.id)", accountId: account,
                                       gmailLabelId: label.id, name: label.name, type: "user",
                                       color: label.color, sortOrder: label.order)
                    try row.insert(database)
                }

                var touched = Set<String>()
                var pending: [SyncEngine.PendingUpsert] = []
                for msg in messages() {
                    pending.append(.init(message: msg, attachments: []))
                    touched.insert(msg.threadId)
                }
                // Same body-split path as live sync (v24 message_body).
                _ = try SyncEngine.upsertPending(database, items: pending)
                try SyncEngine.deriveThreads(database, for: touched, accountId: account)

                for (threadId, category) in aiCategories {
                    let row = ThreadAICategory(threadId: threadId, category: category)
                    try row.insert(database)
                }
            }
            return true
        } catch {
            NSLog("MishMail: demo seed failed — %@", "\(error)")
            return false
        }
    }

    private static func clearDemoData(_ db: DatabasePool) -> Bool {
        do {
            try db.write { try clearDemoData(in: $0) }
            return true
        } catch {
            NSLog("MishMail: demo cleanup failed — %@", "\(error)")
            return false
        }
    }

    private static func clearDemoData(in database: GRDB.Database) throws {
        // account cascades through messages, bodies, attachments, threads,
        // thread labels, and labels. The remaining tables are not account-FK'd.
        try database.execute(sql: "DELETE FROM threadAI WHERE threadId LIKE ?",
                             arguments: ["\(account):%"])
        try database.execute(sql: "DELETE FROM scheduledSend WHERE accountId = ?",
                             arguments: [account])
        try database.execute(sql: "DELETE FROM savedView WHERE accountId = ?",
                             arguments: [account])
        try database.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [account])
    }

    // MARK: - Fixture data

    private struct DemoLabel { let id, name, color: String; let order: Int }

    /// Deliberately long list with near-duplicate clusters so the "l" picker's
    /// type-to-filter (and scroll-past-the-fold) can be exercised in demo mode.
    /// Order is the organizer / picker order: early rows sit above the fold;
    /// clusters further down force typing or ↓ to reach.
    private static let userLabels: [DemoLabel] = {
        // (id suffix, display name, color) — order is array index.
        let rows: [(String, String, String)] = [
            // Top of the list (visible without scrolling).
            ("work", "Work", "#6E56CF"),
            ("research", "Research", "#30A46C"),
            ("personal", "Personal", "#E5484D"),
            ("starred_keep", "Starred / keep", "#F5D90A"),
            ("follow_up", "Follow up", "#E5484D"),
            ("waiting", "Waiting on", "#AB4ABA"),
            ("travel", "Travel", "#12A594"),
            ("family", "Family", "#E93D82"),
            ("friends", "Friends", "#D6409F"),
            // Investment cluster — typing "inv" must surface several of these.
            ("investment", "Investment Updates", "#0091FF"),
            ("investor", "investor updates", "#F76B15"),
            ("investors", "Investors", "#3E63DD"),
            ("invest_lp", "Investment / LP notes", "#0090FF"),
            ("invest_thesis", "Investment thesis", "#5B5BD6"),
            ("inv_committee", "Investment Committee", "#6E56CF"),
            ("invoices", "Invoices", "#30A46C"),
            ("invite", "Invites", "#F76B15"),
            // Receipt / finance cluster further down.
            ("receipts", "Receipts", "#978365"),
            ("receipts_tax", "Receipts — tax", "#AD7F58"),
            ("receipts_2025", "Receipts 2025", "#A18072"),
            ("receipts_2026", "Receipts 2026", "#A18072"),
            ("expenses", "Expenses", "#FFB224"),
            ("expense_reports", "Expense reports", "#F76808"),
            ("reimbursements", "Reimbursements", "#E5484D"),
            // Project / product cluster (mid list).
            ("project_alpha", "Project Alpha", "#3E63DD"),
            ("project_beta", "Project Beta", "#0090FF"),
            ("project_gamma", "Project Gamma", "#12A594"),
            ("product", "Product", "#6E56CF"),
            ("product_feedback", "Product feedback", "#5B5BD6"),
            ("product_roadmap", "Product roadmap", "#7C66DC"),
            ("design", "Design", "#E93D82"),
            ("design_review", "Design review", "#D6409F"),
            ("eng", "Engineering", "#30A46C"),
            ("eng_oncall", "Engineering / on-call", "#3D9A50"),
            ("eng_hiring", "Engineering hiring", "#46A758"),
            // Hiring / people (similar wording).
            ("hiring", "Hiring", "#E5484D"),
            ("hiring_eng", "Hiring — eng", "#E5484D"),
            ("hiring_design", "Hiring — design", "#E93D82"),
            ("candidates", "Candidates", "#AB4ABA"),
            ("candidates_pass", "Candidates / pass", "#8E4EC6"),
            ("intros", "Intros", "#0091FF"),
            ("intros_lp", "Intros — LPs", "#3E63DD"),
            ("intros_founders", "Intros — founders", "#12A594"),
            // News / newsletters.
            ("news", "News", "#978365"),
            ("newsletters", "Newsletters", "#A18072"),
            ("news_ai", "News — AI", "#5B5BD6"),
            ("news_climate", "News — climate", "#30A46C"),
            // Nested-style Gmail names further down the list.
            ("clients", "Clients", "#0090FF"),
            ("clients_acme", "Clients/Acme", "#3E63DD"),
            ("clients_northwind", "Clients/Northwind", "#12A594"),
            ("clients_brightloop", "Clients/Brightloop", "#6E56CF"),
            ("vendors", "Vendors", "#F76B15"),
            ("vendors_aws", "Vendors/AWS", "#FFB224"),
            ("vendors_stripe", "Vendors/Stripe", "#E93D82"),
            // Legal / admin tail of the list (must scroll or type to reach).
            ("legal", "Legal", "#8B8D98"),
            ("legal_contracts", "Legal — contracts", "#6C6E79"),
            ("legal_nda", "Legal — NDAs", "#6C6E79"),
            ("admin", "Admin", "#978365"),
            ("admin_hr", "Admin / HR", "#A18072"),
            ("admin_it", "Admin / IT", "#AD7F58"),
            ("archive_2024", "Archive 2024", "#8B8D98"),
            ("archive_2025", "Archive 2025", "#8B8D98"),
            ("zzz_misc", "zzz misc", "#6C6E79"),
            ("zzz_triage", "zzz triage later", "#6C6E79"),
            ("university", "University", "#3E63DD"),
            ("university_alumni", "University alumni", "#0090FF"),
            ("board", "Board", "#E5484D"),
            ("board_pack", "Board pack", "#E93D82"),
            ("board_minutes", "Board minutes", "#D6409F"),
        ]
        return rows.enumerated().map { i, row in
            DemoLabel(id: "Label_\(row.0)", name: row.1, color: row.2, order: i)
        }
    }()

    private static func date(_ hoursAgo: Double) -> Date {
        Date().addingTimeInterval(-hoursAgo * 3600)
    }

    private static let aiCategories: [String: String] = [
        "\(account):t1": "Reply needed",
        "\(account):t2": "Reply needed",
        "\(account):t3": "FYI",
        "\(account):t4": "Receipt",
        "\(account):t5": "Newsletter",
        "\(account):t6": "FYI",
        "\(account):t7": "Reply needed",
        "\(account):t8": "Newsletter",
        "\(account):t9": "Receipt",
        "\(account):t10": "Other",
    ]

    private static func messages() -> [Message] {
        var out: [Message] = []
        func add(_ t: String, from: String, subject: String, snippet: String,
                 body: String, hoursAgo: Double, unread: Bool, starred: Bool = false,
                 attachment: Bool = false, extraLabels: [String] = []) {
            var labels = ["INBOX"] + extraLabels
            if starred { labels.append("STARRED") }
            if unread { labels.append("UNREAD") }
            out.append(Message(
                id: "\(account):m_\(t)_\(out.count)",
                accountId: account,
                gmailId: "m_\(t)_\(out.count)",
                threadId: "\(account):\(t)",
                fromHeader: from,
                toHeader: "Alex Rivera <\(account)>",
                ccHeader: "",
                subject: subject,
                date: date(hoursAgo),
                snippet: snippet,
                bodyText: body,
                bodyHTML: nil,
                messageIdHeader: "<\(t)-\(out.count)@example.com>",
                referencesHeader: "",
                labelIds: labels.joined(separator: " "),
                isUnread: unread,
                hasAttachment: attachment))
        }

        add("t1", from: "Dana Okafor <dana@brightloop.io>",
            subject: "Re: Design review Monday",
            snippet: "Thanks for sending the mockups over — the team loved the new inbox layout. A couple of questions before Monday…",
            body: "Thanks for sending the mockups over — the team loved the new inbox layout.\n\nA couple of questions before Monday:\n1. Are the keyboard shortcuts final, or still open for feedback?\n2. Can you share the dark-mode variant of the compose window?\n\nHappy to hop on a call if that's easier.\n\nBest,\nDana",
            hoursAgo: 1.5, unread: true, starred: true, extraLabels: ["Label_work"])

        add("t2", from: "Priya Raman <priya@example.edu>",
            subject: "Draft ready for your review",
            snippet: "I've pushed the revised figures to the shared folder. Figure 3 now uses the corrected normalization — take a look when you get a chance.",
            body: "Hi Alex,\n\nI've pushed the revised figures to the shared folder. Figure 3 now uses the corrected normalization.\n\nCan you review before I send it to the co-authors Thursday?\n\nThanks,\nPriya",
            hoursAgo: 3, unread: true, extraLabels: ["Label_research"])

        add("t3", from: "GitHub <notifications@github.com>",
            subject: "[mishmail] CI passed on main",
            snippet: "All checks have passed for the latest push to main. 142 tests, 0 failures.",
            body: "All checks have passed for the latest push to main.\n\n142 tests, 0 failures.\n\nView the run on GitHub.",
            hoursAgo: 5, unread: false)

        add("t4", from: "Stripe <receipts@stripe.com>",
            subject: "Your receipt from Anthropic",
            snippet: "Receipt #2049-8831. Amount paid $20.00. Thanks for your business.",
            body: "Receipt #2049-8831\n\nAmount paid: $20.00\nDate: today\n\nThanks for your business.",
            hoursAgo: 8, unread: false, attachment: true)

        add("t5", from: "Stratechery <newsletter@stratechery.com>",
            subject: "The State of Local AI",
            snippet: "Running models on-device has quietly gone from a curiosity to a genuine product strategy. This week: what changed…",
            body: "Running models on-device has quietly gone from a curiosity to a genuine product strategy.\n\nThis week we look at what changed and who benefits.",
            hoursAgo: 11, unread: true)

        add("t6", from: "Calendar <calendar@example.com>",
            subject: "Reminder: Board sync at 2pm",
            snippet: "This is a reminder that Board sync starts in one hour. Video link is attached to the event.",
            body: "Reminder: Board sync starts in one hour.\n\nThe video link is on the calendar event.",
            hoursAgo: 20, unread: false)

        add("t7", from: "Marcus Bell <marcus@brightloop.io>",
            subject: "Intro: you <> Sarah at Northwind",
            snippet: "Alex, meet Sarah — she's leading platform at Northwind and has been thinking hard about exactly the problem you're solving.",
            body: "Alex, meet Sarah — she's leading platform at Northwind.\n\nSarah, Alex has been building a native mail client worth a look.\n\nI'll get out of the way!\n\nMarcus",
            hoursAgo: 26, unread: true, starred: true)

        add("t8", from: "Hacker Newsletter <hn@hackernewsletter.com>",
            subject: "Hacker Newsletter #742",
            snippet: "The best of the week from Hacker News, hand-curated. Featured: a deep dive on SQLite internals.",
            body: "The best of the week from Hacker News.\n\nFeatured this week: a deep dive on SQLite internals.",
            hoursAgo: 30, unread: false)

        add("t9", from: "Apple <no_reply@email.apple.com>",
            subject: "Your invoice from the App Store",
            snippet: "Invoice for your recent purchase. Total: $2.99.",
            body: "Your invoice from the App Store.\n\nTotal: $2.99.",
            hoursAgo: 44, unread: false, attachment: true, extraLabels: ["Label_investment"])

        add("t10", from: "Jordan Lee <jordan@example.com>",
            subject: "Dinner Saturday?",
            snippet: "A few of us are getting together Saturday around 7. Would love for you to come — let me know!",
            body: "Hey! A few of us are getting together Saturday around 7.\n\nWould love for you to come — let me know!\n\nJordan",
            hoursAgo: 52, unread: false, extraLabels: ["Label_personal"])

        return out
    }
}
