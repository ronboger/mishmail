import XCTest

/// Folding rules for thread edits queued while offline: one row per thread,
/// replayed as a single Gmail call that lands the user's final intent.
final class RemoteThreadChangeTests: XCTestCase {

    func testLaterAddCancelsEarlierRemove() {
        // Archive (remove INBOX) then undo (add INBOX) → nothing to send.
        let merged = RemoteThreadChange.modify(remove: ["INBOX", "UNREAD"])
            .merged(with: .modify(add: ["INBOX"]))
        XCTAssertEqual(merged, .modify(add: [], remove: ["UNREAD"]))
    }

    func testStarThenArchiveFoldsIntoOneModify() {
        let merged = RemoteThreadChange.modify(add: ["STARRED"])
            .merged(with: .modify(remove: ["INBOX", "UNREAD"]))
        XCTAssertEqual(merged, .modify(add: ["STARRED"], remove: ["INBOX", "UNREAD"]))
    }

    func testStarThenUnstarIsEmpty() {
        let merged = RemoteThreadChange.modify(add: ["STARRED"])
            .merged(with: .modify(remove: ["STARRED"]))
        XCTAssertTrue(merged.isEmpty)
    }

    func testTrashWinsOverLabelEdits() {
        XCTAssertEqual(RemoteThreadChange.modify(add: ["STARRED"]).merged(with: .trash), .trash)
        XCTAssertEqual(RemoteThreadChange.trash.merged(with: .modify(add: ["STARRED"])), .trash)
    }

    func testUntrashFoldsBackIntoModify() {
        let merged = RemoteThreadChange.trash
            .merged(with: .modify(add: ["INBOX"], remove: ["TRASH"]))
        XCTAssertEqual(merged, .modify(add: ["INBOX"], remove: ["TRASH"]))
        XCTAssertFalse(merged.isEmpty)
    }

    func testDuplicateLabelsAreNotRepeated() {
        let merged = RemoteThreadChange.modify(add: ["INBOX"])
            .merged(with: .modify(add: ["INBOX"]))
        XCTAssertEqual(merged, .modify(add: ["INBOX"], remove: []))
    }

    func testCodableRoundTrip() throws {
        for change: RemoteThreadChange in [
            .modify(add: ["STARRED"], remove: ["INBOX"]),
            .modify(),
            .trash,
        ] {
            let data = try JSONEncoder().encode(change)
            XCTAssertEqual(try JSONDecoder().decode(RemoteThreadChange.self, from: data), change)
        }
    }
}
