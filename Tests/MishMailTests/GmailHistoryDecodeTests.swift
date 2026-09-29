import XCTest

final class GmailHistoryDecodeTests: XCTestCase {
    /// Each history record carries its own id, which is a valid
    /// `startHistoryId` for the next call. Slice commits depend on it.
    func testHistoryRecordIdIsDecoded() throws {
        let json = """
        {"history":[{"id":"2142492","messagesAdded":[{"message":{"id":"m1","threadId":"t1"}}]},
                    {"id":"2142500","labelsAdded":[{"message":{"id":"m2","threadId":"t2"},"labelIds":["UNREAD"]}]}],
         "historyId":"2142600"}
        """
        let list = try JSONDecoder().decode(GHistoryList.self, from: Data(json.utf8))
        XCTAssertEqual(list.history?.map(\.id), ["2142492", "2142500"])
        XCTAssertEqual(list.historyId, "2142600")
    }
}
