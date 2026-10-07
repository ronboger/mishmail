import XCTest
import GRDB

final class ThreadDerivationPerformanceTests: XCTestCase {
    private let account = "sync@example.com"

    private func makeDB(count: Int) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: "A", historyId: nil,
                        lastSyncAt: nil).insert(db)
            for i in 0..<count {
                for j in 0..<2 {
                    let gmailId = "m\(i)-\(j)"
                    try Message(
                        id: "\(self.account):\(gmailId)", accountId: self.account,
                        gmailId: gmailId, threadId: "\(self.account):t\(i)",
                        fromHeader: j == 0 ? "alice@example.com" : "bob@example.com",
                        toHeader: self.account, ccHeader: "", subject: "Subject \(j)",
                        // Include equal-date messages; their ordering must not change.
                        date: Date(timeIntervalSince1970: Double(i * 10 + (i % 2 == 0 ? 0 : j))),
                        snippet: "Snippet \(gmailId)", bodyText: "", bodyHTML: nil,
                        messageIdHeader: "<\(gmailId)@example.com>", referencesHeader: "",
                        labelIds: j == 0 ? "INBOX Label_1" : "INBOX Label_2",
                        isUnread: i % 3 == 0, hasAttachment: j == 1).insert(db)
                }
            }
            try self.legacyDerive(db, keys: self.keys(count: count))
        }
        return q
    }

    private func keys(count: Int) -> Set<String> {
        Set((0..<count).map { "\(account):t\($0)" })
    }

    /// Previous production algorithm retained as the comparison for batching.
    private func legacyDerive(_ db: Database, keys: Set<String>) throws {
        for key in keys {
            let messages = try Message.filter(Column("threadId") == key)
                .order(Column("date").desc).fetchAll(db)
            let existing = try MailThread.fetchOne(db, key: key)
            guard let thread = SyncEngine.deriveThread(
                threadKey: key, gmailThreadId: String(key.split(separator: ":").last ?? ""),
                accountId: account, messages: messages, existing: existing) else { continue }
            if thread != existing { try thread.save(db) }
            try ThreadLabels.rewrite(db, threadId: thread.id, labelIds: thread.labelIds)
        }
    }

    func testBatchMatchesLegacyRowsAndRepairsJunctionsAcrossChunks() throws {
        let count = SyncEngine.deriveChunkSize + 3
        let q = try makeDB(count: count + 1)
        var touched = keys(count: count)
        touched.insert("\(account):missing-messages")
        try q.write { db in
            for i in 0..<count {
                let key = "\(self.account):t\(i)"
                if i % 7 == 0 {
                    // A message may exist before its thread is first derived.
                    try MailThread.deleteOne(db, key: key)
                } else {
                    try db.execute(sql: """
                        UPDATE thread SET snoozeUntil = ?, reminderAt = ?, reminderSetAt = ?
                        WHERE id = ?
                        """, arguments: [Date(timeIntervalSince1970: 3_000_000_000),
                                          Date(timeIntervalSince1970: 3_000_001_000),
                                          Date(timeIntervalSince1970: 1), key])
                }
                if i % 3 == 0 {
                    try db.execute(sql: "UPDATE message SET labelIds = 'INBOX STARRED Label_3' WHERE id = ?",
                                   arguments: ["\(self.account):m\(i)-1"])
                }
                if i % 5 == 0 && i % 7 != 0 {
                    try ThreadLabels.rewrite(db, threadId: key, labelIds: "Label_stale")
                }
            }
            // An empty-message existing row is left alone, just as before.
            var empty = try XCTUnwrap(MailThread.fetchOne(db, key: "\(self.account):t\(count)"))
            empty.id = "\(self.account):missing-messages"
            empty.gmailThreadId = "missing-messages"
            try empty.insert(db)

            var expectedThreads: [MailThread] = []
            var expectedLabels: [ThreadLabel] = []
            try db.inSavepoint {
                try self.legacyDerive(db, keys: touched)
                expectedThreads = try MailThread.order(Column("id")).fetchAll(db)
                expectedLabels = try ThreadLabel.order(Column("threadId"), Column("labelId")).fetchAll(db)
                return .rollback
            }
            var derivations = 0
            try SyncEngine.deriveThreads(db, for: touched, accountId: self.account,
                                        derivationCount: { derivations += 1 })
            XCTAssertEqual(derivations, touched.count)
            XCTAssertEqual(try MailThread.order(Column("id")).fetchAll(db), expectedThreads)
            XCTAssertEqual(try ThreadLabel.order(Column("threadId"), Column("labelId")).fetchAll(db),
                           expectedLabels)
        }
    }

    func testEmptyBatchDoesNotReadOrDerive() throws {
        let q = try makeDB(count: 0)
        try q.write { db in
            var statements = 0
            db.trace { if case .statement = $0 { statements += 1 } }
            defer { db.trace(nil) }
            var derivations = 0
            try SyncEngine.deriveThreads(db, for: [], accountId: self.account,
                                        derivationCount: { derivations += 1 })
            XCTAssertEqual(statements, 0)
            XCTAssertEqual(derivations, 0)
        }
    }

    func testMetadataReadReductionAtMailboxScale() throws {
        for count in [500, 5_000] {
            let q = try makeDB(count: count)
            let touched = keys(count: count)
            try q.write { db in
                var selects = 0
                db.trace {
                    if case .statement(let statement) = $0,
                       statement.sql.hasPrefix("SELECT") { selects += 1 }
                }
                defer { db.trace(nil) }
                let beforeLegacy = Date()
                try self.legacyDerive(db, keys: touched)
                let legacySeconds = Date().timeIntervalSince(beforeLegacy)
                let legacySelects = selects
                selects = 0
                let beforeBatch = Date()
                try SyncEngine.deriveThreads(db, for: touched, accountId: self.account)
                let batchSeconds = Date().timeIntervalSince(beforeBatch)
                let chunks = SyncEngine.deriveChunks(touched).count
                XCTAssertEqual(legacySelects, count * 3)
                XCTAssertEqual(selects, count + 2 * chunks)
                print("PERF derive \(count): legacy=\(legacySelects) SELECTs, \(legacySeconds)s; batch=\(selects) SELECTs, \(batchSeconds)s")
            }
        }
    }
}
