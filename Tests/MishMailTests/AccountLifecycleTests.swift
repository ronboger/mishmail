import XCTest
import GRDB

final class AccountLifecycleTests: XCTestCase {

    func testReauthRequiredForInvalidGrantAndMissingToken() {
        XCTAssertTrue(AccountLifecycle.isReauthRequired(OAuthError.invalidGrant))
        XCTAssertTrue(AccountLifecycle.isReauthRequired(GmailError.noRefreshToken("a@x.com")))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(OAuthError.cancelled))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(GmailError.historyExpired))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(GmailError.partialFetch(failedCount: 2)))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(URLError(.timedOut)))
    }

    func testDemoConnectBlockedOnlyForFixtureKey() {
        XCTAssertTrue(AccountLifecycle.blocksDemoConnect(usesFixtureDatabaseKey: true))
        XCTAssertFalse(AccountLifecycle.blocksDemoConnect(usesFixtureDatabaseKey: false))
        XCTAssertTrue(AccountLifecycle.demoConnectBlockedMessage.contains("DEMO=0"))
    }

    func testSignInInsertsNewAccount() {
        let account = AccountLifecycle.accountAfterSignIn(
            email: "a@x.com", name: "Ada", existing: nil)
        XCTAssertEqual(account.id, "a@x.com")
        XCTAssertEqual(account.displayName, "Ada")
        XCTAssertEqual(account.senderName, "Ada")
        XCTAssertNil(account.historyId)
        XCTAssertNil(account.lastSyncAt)
    }

    func testReauthPreservesHistoryAndFillsEmptySenderName() {
        var existing = Account(
            id: "a@x.com", displayName: "a@x.com",
            historyId: "99", lastSyncAt: Date(timeIntervalSince1970: 50),
            senderName: "")
        let updated = AccountLifecycle.accountAfterSignIn(
            email: "a@x.com", name: "Ada", existing: existing)
        XCTAssertEqual(updated.historyId, "99")
        XCTAssertEqual(updated.lastSyncAt, existing.lastSyncAt)
        XCTAssertEqual(updated.displayName, "Ada",
                       "email-as-display-name is replaced by the profile name")
        XCTAssertEqual(updated.senderName, "Ada")

        existing.displayName = "Personal"
        existing.senderName = "Kept"
        let nicknamed = AccountLifecycle.accountAfterSignIn(
            email: "a@x.com", name: "Ada", existing: existing)
        XCTAssertEqual(nicknamed.displayName, "Personal")
        XCTAssertEqual(nicknamed.senderName, "Kept")
    }

    // MARK: - Account removal

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    /// One row in every account-owned table that has no foreign key.
    private func seed(_ db: Database, account: String) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try Account(id: account, displayName: account, historyId: "7",
                    lastSyncAt: nil, senderName: "").insert(db)
        try MailThread(
            id: "\(account):t1", accountId: account, gmailThreadId: "t1",
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: now, isUnread: false, isStarred: false,
            inInbox: true, inTrash: false, labelIds: "INBOX",
            snoozeUntil: nil, participants: "F", messageCount: 1,
            hasAttachment: false, reminderAt: nil).insert(db)
        try ThreadAICategory(threadId: "\(account):t1", category: "fyi").insert(db)
        try PendingThreadOp.enqueue(db, accountId: account, gmailThreadId: "t1",
                                    change: .modify(add: ["STARRED"]))
        try LocalDraft(
            id: nil, accountId: account, fromEmail: "", toHeader: "j@y.com",
            ccHeader: "", bccHeader: "", subject: "Offline", body: "b",
            replyToMessageId: nil, forward: false, replacingDraftId: nil,
            attachmentsJSON: Data("[]".utf8), createdAt: now, updatedAt: now).insert(db)
        try ScheduledSend(
            id: nil, accountId: account, toHeader: "j@y.com",
            ccHeader: "", bccHeader: "", subject: "Later", body: "b",
            sendAt: now, replyToMessageId: nil, forward: false, replacingDraftId: nil,
            attachmentsJSON: Data("[]".utf8), createdAt: now).insert(db)
        var view = SavedView.empty()
        view.name = "View \(account)"
        view.accountId = account
        try view.insert(db)
    }

    private func counts(_ db: Database, account: String) throws -> [String: Int] {
        var out: [String: Int] = [:]
        for table in ["account", "thread", "pendingThreadOp", "localDraft",
                      "scheduledSend", "savedView"] {
            let column = table == "account" ? "id" : "accountId"
            out[table] = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) = ?",
                arguments: [account])
        }
        out["threadAI"] = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM threadAI WHERE threadId = ?",
            arguments: ["\(account):t1"])
        return out
    }

    func testPurgeAccountRemovesOnlyThatAccountsRows() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, account: "a@x.com")
            try self.seed(db, account: "b@x.com")
            try AccountLifecycle.purgeAccount(db, id: "a@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try self.counts(db, account: "a@x.com"), [
                "account": 0, "thread": 0, "threadAI": 0, "pendingThreadOp": 0,
                "localDraft": 0, "scheduledSend": 0,
                // Saved views are kept on purpose; see `purgeAccount`.
                "savedView": 1,
            ])
            XCTAssertEqual(try self.counts(db, account: "b@x.com"), [
                "account": 1, "thread": 1, "threadAI": 1, "pendingThreadOp": 1,
                "localDraft": 1, "scheduledSend": 1, "savedView": 1,
            ])
        }
    }

    /// `_` is a single-character wildcard in SQL LIKE. A prefix match on the
    /// thread id must not reach an account whose address differs only there.
    func testPurgeAccountTreatsUnderscoreInAddressLiterally() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, account: "a_b@x.com")
            try self.seed(db, account: "aXb@x.com")
            try AccountLifecycle.purgeAccount(db, id: "a_b@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try self.counts(db, account: "a_b@x.com")["threadAI"], 0)
            XCTAssertEqual(try self.counts(db, account: "aXb@x.com")["threadAI"], 1)
        }
    }

    func testPurgeAccountForUnknownAccountChangesNothing() throws {
        let q = try makeDB()
        try q.write { db in
            try self.seed(db, account: "b@x.com")
            try AccountLifecycle.purgeAccount(db, id: "gone@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try self.counts(db, account: "b@x.com")["scheduledSend"], 1)
            XCTAssertEqual(try self.counts(db, account: "b@x.com")["account"], 1)
        }
    }

    func testClearBackfillFlagsRemovesOnlyThatAccountsKeys() throws {
        let suite = "AccountLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for id in ["a@x.com", "b@x.com"] {
            defaults.set(30, forKey: "backfill.window.\(id)")
            defaults.set(true, forKey: "backfill.starred.\(id)")
            defaults.set(true, forKey: SyncEngine.attachmentRepairDefaultsKey(accountId: id))
        }
        defaults.set(30, forKey: "syncWindowDays.a@x.com")

        AccountLifecycle.clearBackfillFlags(accountId: "a@x.com", defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "backfill.window.a@x.com"))
        XCTAssertNil(defaults.object(forKey: "backfill.starred.a@x.com"))
        XCTAssertNil(defaults.object(forKey: "backfill.attachments.a@x.com"))
        XCTAssertEqual(defaults.integer(forKey: "syncWindowDays.a@x.com"), 30,
                       "the user's Keep-mail-from choice is a preference, not sync state")
        XCTAssertEqual(defaults.integer(forKey: "backfill.window.b@x.com"), 30)
        XCTAssertTrue(defaults.bool(forKey: "backfill.starred.b@x.com"))
        XCTAssertTrue(defaults.bool(forKey: "backfill.attachments.b@x.com"))
    }
}
