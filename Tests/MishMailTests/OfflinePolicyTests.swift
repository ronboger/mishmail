import XCTest

final class OfflinePolicyTests: XCTestCase {

    func testConnectivityFailuresAreDeferredNotSurfaced() {
        for code: URLError.Code in [.notConnectedToInternet, .networkConnectionLost,
                                    .timedOut, .dnsLookupFailed] {
            let error = URLError(code)
            XCTAssertTrue(OfflinePolicy.shouldDefer(error), "\(code) should queue")
            XCTAssertFalse(OfflinePolicy.surfacesSyncFailure(error), "\(code) must not banner")
        }
    }

    func testGmailRejectionsAreSurfacedNotDeferred() {
        let rejected = GmailError.http(400, "bad request")
        XCTAssertFalse(OfflinePolicy.shouldDefer(rejected))
        XCTAssertTrue(OfflinePolicy.surfacesSyncFailure(rejected))

        let auth = GmailError.noRefreshToken("a@x.com")
        XCTAssertFalse(OfflinePolicy.shouldDefer(auth))
        XCTAssertTrue(OfflinePolicy.surfacesSyncFailure(auth))
    }

    func testWrappedConnectivityFailureIsDeferred() {
        let wrapped = NSError(domain: "MishMail", code: 1, userInfo: [
            NSUnderlyingErrorKey: URLError(.notConnectedToInternet)
        ])
        XCTAssertTrue(OfflinePolicy.shouldDefer(wrapped))
    }

    func testOfflineStatusLabelCountsQueuedWork() {
        XCTAssertEqual(
            OfflinePolicy.offlineStatusLabel(queuedSends: 0, localDrafts: 0, pendingEdits: 0),
            "Offline")
        XCTAssertEqual(
            OfflinePolicy.offlineStatusLabel(queuedSends: 1, localDrafts: 0, pendingEdits: 0),
            "Offline · 1 message to send")
        XCTAssertEqual(
            OfflinePolicy.offlineStatusLabel(queuedSends: 2, localDrafts: 1, pendingEdits: 3),
            "Offline · 2 messages to send, 1 draft to upload, 3 changes to sync")
    }

    func testDueScheduledSendIsWaitingForConnection() {
        let now = Date()
        XCTAssertTrue(OfflinePolicy.isWaitingForConnection(sendAt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(OfflinePolicy.isWaitingForConnection(sendAt: now, now: now))
        XCTAssertFalse(OfflinePolicy.isWaitingForConnection(sendAt: now.addingTimeInterval(60), now: now))
    }
}
