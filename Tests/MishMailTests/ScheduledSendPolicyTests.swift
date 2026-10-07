import XCTest

final class ScheduledSendPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Failed send

    func testNoNetworkStopsTheSweep() {
        XCTAssertEqual(
            ScheduledSendPolicy.action(afterSendFailure: URLError(.notConnectedToInternet),
                                       composeIsOpen: false, failingSince: nil, now: now),
            .stopSweep)
    }

    func testReauthKeepsTheRowWaitingForSignIn() {
        for error: Error in [OAuthError.invalidGrant, GmailError.noRefreshToken("a@x.com")] {
            XCTAssertEqual(
                ScheduledSendPolicy.action(afterSendFailure: error, composeIsOpen: false,
                                           failingSince: nil, now: now),
                .hold(.signIn))
        }
    }

    func testRateLimitAndServerErrorKeepTheRowForRetry() {
        for code in [429, 500, 503] {
            XCTAssertEqual(
                ScheduledSendPolicy.action(afterSendFailure: GmailError.http(code, ""),
                                           composeIsOpen: false, failingSince: nil, now: now),
                .hold(.retry), "\(code)")
        }
    }

    func testPermanentRejectionGoesBackToCompose() {
        XCTAssertEqual(
            ScheduledSendPolicy.action(afterSendFailure: GmailError.http(400, "Invalid To header"),
                                       composeIsOpen: false, failingSince: nil, now: now),
            .restoreToCompose)
    }

    /// The compose card holds one message. A second rejected row in the same
    /// sweep (or one that fails while the user is writing something else)
    /// must stay in the schedule instead of replacing the open card.
    func testPermanentRejectionNeverReplacesAnOpenComposeCard() {
        XCTAssertEqual(
            ScheduledSendPolicy.action(afterSendFailure: GmailError.http(400, ""),
                                       composeIsOpen: true, failingSince: nil, now: now),
            .hold(.rejected))
    }

    func testRetryableFailureIsHandedToTheUserAfterTheGiveUpWindow() {
        let justUnder = now.addingTimeInterval(-ScheduledSendPolicy.retryGiveUp + 1)
        let over = now.addingTimeInterval(-ScheduledSendPolicy.retryGiveUp)
        XCTAssertEqual(
            ScheduledSendPolicy.action(afterSendFailure: GmailError.http(503, ""),
                                       composeIsOpen: false, failingSince: justUnder, now: now),
            .hold(.retry))
        XCTAssertEqual(
            ScheduledSendPolicy.action(afterSendFailure: GmailError.http(503, ""),
                                       composeIsOpen: false, failingSince: over, now: now),
            .restoreToCompose)
        XCTAssertEqual(
            ScheduledSendPolicy.action(afterSendFailure: GmailError.http(503, ""),
                                       composeIsOpen: true, failingSince: over, now: now),
            .hold(.rejected))
        // A dead sign-in is the user's to fix; it never times out into compose.
        XCTAssertEqual(
            ScheduledSendPolicy.action(afterSendFailure: OAuthError.invalidGrant,
                                       composeIsOpen: false, failingSince: over, now: now),
            .hold(.signIn))
    }

    // MARK: Failed already-sent check

    /// A replay after an ambiguous failure must not go out while the
    /// "did Gmail already take it?" lookup itself cannot answer.
    func testUnansweredSentCheckBlocksTheResend() {
        XCTAssertEqual(
            ScheduledSendPolicy.action(afterSentCheckFailure: URLError(.timedOut),
                                       failingSince: nil, now: now),
            .stopSweep)
        XCTAssertEqual(
            ScheduledSendPolicy.action(afterSentCheckFailure: GmailError.http(429, ""),
                                       failingSince: nil, now: now),
            .hold(.retry))
        XCTAssertEqual(
            ScheduledSendPolicy.action(afterSentCheckFailure: GmailError.noRefreshToken("a@x.com"),
                                       failingSince: nil, now: now),
            .hold(.signIn))
    }

    /// A lookup Gmail rejects outright will never answer; the send proceeds
    /// (nil) so the row cannot be stuck forever behind it.
    func testRejectedSentCheckLetsTheSendProceed() {
        XCTAssertNil(
            ScheduledSendPolicy.action(afterSentCheckFailure: GmailError.http(400, ""),
                                       failingSince: nil, now: now))
        XCTAssertNil(
            ScheduledSendPolicy.action(
                afterSentCheckFailure: GmailError.http(503, ""),
                failingSince: now.addingTimeInterval(-ScheduledSendPolicy.retryGiveUp), now: now))
    }

    func testHoldSkipsTheRestOfTheAccountExceptForARejectedMessage() {
        XCTAssertTrue(ScheduledSendPolicy.Hold.signIn.blocksAccount)
        XCTAssertTrue(ScheduledSendPolicy.Hold.retry.blocksAccount)
        XCTAssertFalse(ScheduledSendPolicy.Hold.rejected.blocksAccount)
    }

    // MARK: Timer

    func testHeldDueRowBacksOffInsteadOfTheOneSecondFloor() {
        let delay = ScheduledSendPolicy.timerDelay(
            rows: [(sendAt: now.addingTimeInterval(-30), held: true)],
            isOffline: false, now: now)
        XCTAssertEqual(delay, ScheduledSendPolicy.heldRetry)
    }

    func testDueRowThatIsNotHeldKeepsTheFloor() {
        let delay = ScheduledSendPolicy.timerDelay(
            rows: [(sendAt: now.addingTimeInterval(-30), held: true),
                   (sendAt: now, held: false)],
            isOffline: false, now: now)
        XCTAssertEqual(delay, OfflinePolicy.sendRetryFloor)
    }

    func testFutureRowIsNotDelayedByAHeldOne() {
        let delay = ScheduledSendPolicy.timerDelay(
            rows: [(sendAt: now.addingTimeInterval(-30), held: true),
                   (sendAt: now.addingTimeInterval(10), held: false)],
            isOffline: false, now: now)
        XCTAssertEqual(delay ?? 0, 10, accuracy: 0.001)
    }

    func testOfflineDueRowBacksOff() {
        let delay = ScheduledSendPolicy.timerDelay(
            rows: [(sendAt: now.addingTimeInterval(-30), held: false)],
            isOffline: true, now: now)
        XCTAssertEqual(delay, OfflinePolicy.offlineSendRetry)
    }

    func testNoRowsNoTimer() {
        XCTAssertNil(ScheduledSendPolicy.timerDelay(rows: [], isOffline: false, now: now))
    }

    // MARK: Hold bookkeeping

    func testHoldKeepsItsFirstFailureTime() {
        let first = now.addingTimeInterval(-120)
        let previous = ScheduledSendPolicy.HoldState(hold: .retry, since: first)
        XCTAssertEqual(
            ScheduledSendPolicy.HoldState.next(.retry, previous: previous, now: now).since, first)
        XCTAssertEqual(
            ScheduledSendPolicy.HoldState.next(.retry, previous: nil, now: now).since, now)
    }

    func testPruneDropsHoldsForRowsThatAreGone() {
        let state = ScheduledSendPolicy.HoldState(hold: .signIn, since: now)
        XCTAssertEqual(
            ScheduledSendPolicy.prune([1: state, 2: state], keeping: [2, 3]),
            [2: state])
    }

    // MARK: Scheduled list label

    func testStatusLabel() {
        let past = now.addingTimeInterval(-60)
        XCTAssertNil(ScheduledSendPolicy.waitingStatus(
            sendAt: now.addingTimeInterval(60), hold: nil, now: now))
        XCTAssertEqual(
            ScheduledSendPolicy.waitingStatus(sendAt: past, hold: nil, now: now)?.text,
            OfflinePolicy.waitingForConnectionLabel)
        XCTAssertEqual(
            ScheduledSendPolicy.waitingStatus(sendAt: past, hold: .signIn, now: now)?.text,
            "Waiting for sign-in")
        XCTAssertEqual(
            ScheduledSendPolicy.waitingStatus(sendAt: past, hold: .retry, now: now)?.text,
            "Gmail is busy — retrying")
        XCTAssertEqual(
            ScheduledSendPolicy.waitingStatus(sendAt: past, hold: .rejected, now: now)?.text,
            "Not sent — edit to fix")
    }
}
