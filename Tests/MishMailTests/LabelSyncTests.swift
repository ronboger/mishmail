import XCTest
import GRDB

/// SyncEngine.applyLabels — the local label table follows Gmail's label
/// list, including labels deleted in Gmail.
final class LabelSyncTests: XCTestCase {
    private let account = "a@x.com"
    private let other = "b@x.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            for id in [account, other] {
                try Account(id: id, displayName: "P", historyId: nil,
                            lastSyncAt: nil, senderName: "").save(db)
            }
        }
        return q
    }

    private func label(_ id: String, _ name: String, type: String? = "user",
                       color: String? = nil) -> GLabel {
        GLabel(id: id, name: name, type: type,
               color: color.map { GLabel.GColor(backgroundColor: $0, textColor: nil) })
    }

    private func names(_ q: DatabaseQueue, account: String) throws -> Set<String> {
        try q.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM label WHERE accountId = ?",
                                arguments: [account])
        }
    }

    func testLabelDeletedInGmailIsRemovedLocally() throws {
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("INBOX", "INBOX", type: "system"),
                label("Label_1", "Old project"),
                label("Label_2", "Receipts"),
            ])
        }
        XCTAssertEqual(try names(q, account: account), ["INBOX", "Old project", "Receipts"])

        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("INBOX", "INBOX", type: "system"),
                label("Label_2", "Receipts"),
            ])
        }
        XCTAssertEqual(try names(q, account: account), ["INBOX", "Receipts"])
    }

    func testSurvivingLabelsKeepLocalColorAndOrder() throws {
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_1", "Old project"),
                label("Label_2", "Receipts", color: "#111111"),
            ])
            try db.execute(
                sql: "UPDATE label SET color = '#ABCDEF', sortOrder = 3 WHERE gmailLabelId = 'Label_2'")
        }
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_2", "Receipts renamed", color: "#222222"),
            ])
        }
        let rows = try q.read { db in try LabelRow.fetchAll(db) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "Receipts renamed")
        XCTAssertEqual(rows.first?.color, "#ABCDEF")
        XCTAssertEqual(rows.first?.sortOrder, 3)
    }

    func testOtherAccountIsNotTouched() throws {
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: other, labels: [
                label("Label_1", "Theirs"),
                label("Label_9", "Also theirs"),
            ])
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_1", "Mine"),
            ])
        }
        // Same Gmail label id on both accounts; account A drops everything
        // but Label_2.
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_2", "New"),
            ])
        }
        XCTAssertEqual(try names(q, account: account), ["New"])
        XCTAssertEqual(try names(q, account: other), ["Theirs", "Also theirs"])
    }

    /// An empty list is never a real Gmail answer (system labels always
    /// exist); it must not wipe the table.
    func testEmptyListDeletesNothing() throws {
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_1", "Old project"),
            ])
            try SyncEngine.applyLabels(db, accountId: account, labels: [])
        }
        XCTAssertEqual(try names(q, account: account), ["Old project"])
    }

    /// More labels than one statement binds: the delete is not an
    /// `id NOT IN (…)` over the fetched list.
    func testManyLabelsSurviveAndOnlyTheMissingOneGoes() throws {
        let q = try makeDB()
        let many = (0..<1_200).map { label("Label_\($0)", "L\($0)") }
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: many)
            try SyncEngine.applyLabels(db, accountId: account,
                                       labels: many.filter { $0.id != "Label_700" })
        }
        let ids = try q.read { db in
            try String.fetchSet(db, sql: "SELECT gmailLabelId FROM label")
        }
        XCTAssertEqual(ids.count, 1_199)
        XCTAssertFalse(ids.contains("Label_700"))
    }
}
