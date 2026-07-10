import XCTest

final class HistoryFetchFormatTests: XCTestCase {
    func testMessagesAddedAlwaysFull() {
        let d = HistoryFetchFormat.decide(
            isMessagesAdded: true, localExists: false,
            historyHasLabelIds: true, needBody: false)
        XCTAssertEqual(d, .full(.messagesAdded))
        XCTAssertEqual(HistoryFetchFormat.formatString(d), "full")
    }

    func testLocalMissingFull() {
        let d = HistoryFetchFormat.decide(
            isMessagesAdded: false, localExists: false,
            historyHasLabelIds: false, needBody: false)
        XCTAssertEqual(d, .full(.localMissing))
    }

    func testLabelOnlyLocalSkip() {
        let d = HistoryFetchFormat.decide(
            isMessagesAdded: false, localExists: true,
            historyHasLabelIds: true, needBody: false)
        XCTAssertEqual(d, .skip)
        XCTAssertNil(HistoryFetchFormat.formatString(d))
    }

    func testLocalExistsNoLabelsMetadata() {
        let d = HistoryFetchFormat.decide(
            isMessagesAdded: false, localExists: true,
            historyHasLabelIds: false, needBody: false)
        XCTAssertEqual(d, .metadata(.labelOnlyNeedsMetadata))
        XCTAssertEqual(HistoryFetchFormat.formatString(d), "metadata")
    }

    func testNeedBodyForcesFull() {
        let d = HistoryFetchFormat.decide(
            isMessagesAdded: false, localExists: true,
            historyHasLabelIds: true, needBody: true)
        XCTAssertEqual(d, .full(.needsFullBody))
    }
}
