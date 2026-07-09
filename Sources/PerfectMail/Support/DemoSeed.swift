import Foundation
import GRDB

/// Fills the (Debug-only) database with realistic but entirely fictional mail
/// so the app can be screenshotted for the README without touching a real
/// Gmail account. Everything here is fake — names, addresses, and bodies are
/// invented — so nothing private can leak into a screenshot.
///
/// Activated by launching with the `PERFECTMAIL_DEMO=1` environment variable
/// (see `make demo`). It is compiled only into Debug builds and, even then,
/// does nothing unless that variable is set — so it can never run in the
/// Release app you install or ship.
enum DemoSeed {
    static var isActive: Bool {
        // Hard-disabled outside Debug so no environment variable can ever
        // wipe/replace a real mail cache in the installed Release app.
        #if DEBUG
        ProcessInfo.processInfo.environment["PERFECTMAIL_DEMO"] == "1"
        #else
        false
        #endif
    }

    static let account = "you@example.com"

    /// Wipes the mail tables and inserts a fresh demo inbox. Idempotent: every
    /// launch reseeds from scratch, so the screenshots are deterministic.
    static func seedIfRequested(_ db: DatabasePool) {
        guard isActive else { return }
        // Never clobber a real signed-in account: the wipe below only runs on
        // a fresh database or one that already holds only the demo fixture.
        // (`make run DEMO=0` is the verb for a real-account Debug session.)
        let existing = (try? db.read { try Account.fetchAll($0) }) ?? []
        guard existing.allSatisfy({ $0.id == account }) else {
            NSLog("PerfectMail: demo seed skipped — a real account is signed in")
            return
        }
        try? db.write { database in
            for table in ["message", "thread", "threadAI", "label", "vipSender",
                          "attachment", "account"] {
                try? database.execute(sql: "DELETE FROM \(table)")
            }

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
            for msg in messages() {
                let m = msg
                try m.insert(database)
                touched.insert(m.threadId)
            }
            try SyncEngine.deriveThreads(database, for: touched, accountId: account)

            for (threadId, category) in aiCategories {
                let row = ThreadAICategory(threadId: threadId, category: category)
                try row.insert(database)
            }

            for vip in ["dana@brightloop.io", "priya@example.edu"] {
                let v = VIPSender(email: vip)
                try v.insert(database)
            }
        }
    }

    // MARK: - Fixture data

    private struct DemoLabel { let id, name, color: String; let order: Int }
    private static let userLabels: [DemoLabel] = [
        DemoLabel(id: "Label_work", name: "Work", color: "#6E56CF", order: 0),
        DemoLabel(id: "Label_research", name: "Research", color: "#30A46C", order: 1),
        DemoLabel(id: "Label_personal", name: "Personal", color: "#E5484D", order: 2),
        // Near-duplicate names (case + wording) so label-picker search can be
        // exercised: typing "inv" must surface both of these.
        DemoLabel(id: "Label_investment", name: "Investment Updates", color: "#0091FF", order: 3),
        DemoLabel(id: "Label_investor", name: "investor updates", color: "#F76B15", order: 4),
    ]

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
            subject: "[perfectmail] CI passed on main",
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
