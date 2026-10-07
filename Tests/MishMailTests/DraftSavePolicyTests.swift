import XCTest

/// Closing compose (Esc / ✕) while Gmail rejects the draft save — account
/// needs re-authorization, 429, 5xx — used to close the card with the text
/// stored nowhere. Only connectivity failures were kept in the Outbox.
final class DraftSavePolicyTests: XCTestCase {
    private let rejections: [Error] = [
        GmailError.http(429, "rate limit"),
        GmailError.http(503, "backend error"),
        GmailError.http(401, "invalid credentials"),
        GmailError.http(400, "Invalid To header"),
        GmailError.noRefreshToken("a@x.com"),
    ]

    func testClosingKeepsARejectedDraftLocally() {
        for error in rejections {
            XCTAssertTrue(DraftSavePolicy.keepsDraftLocally(error: error, closing: true),
                          "\(error) on close must not lose the text")
        }
    }

    /// Autosave: the card is still open and holds the text. The footer shows
    /// "Draft not saved"; an Outbox row per failed autosave would be noise.
    func testAutosaveDoesNotKeepARejectedDraftLocally() {
        for error in rejections {
            XCTAssertFalse(DraftSavePolicy.keepsDraftLocally(error: error, closing: false),
                           "\(error) during autosave stays a plain failure")
        }
    }

    func testConnectivityFailureIsKeptLocallyOnBothPaths() {
        for code: URLError.Code in [.notConnectedToInternet, .timedOut, .networkConnectionLost] {
            let error = URLError(code)
            XCTAssertTrue(DraftSavePolicy.keepsDraftLocally(error: error, closing: true))
            XCTAssertTrue(DraftSavePolicy.keepsDraftLocally(error: error, closing: false))
        }
    }

    /// Only a connectivity failure means the app is offline. A rejection
    /// while Gmail is reachable must not flip the offline state.
    func testOnlyConnectivityFailuresMarkOffline() {
        XCTAssertTrue(DraftSavePolicy.marksOffline(URLError(.notConnectedToInternet)))
        for error in rejections {
            XCTAssertFalse(DraftSavePolicy.marksOffline(error), "\(error)")
        }
    }

    /// The banner must say where the text went, and keep the cause.
    func testRejectedMessageNamesTheOutboxAndTheCause() {
        let message = DraftSavePolicy.keptAfterRejectionMessage(GmailError.http(429, "rate limit"))
        XCTAssertTrue(message.contains("Outbox"))
        XCTAssertTrue(message.contains("429"))
        XCTAssertFalse(message.hasPrefix("Draft not saved"))
    }
}
