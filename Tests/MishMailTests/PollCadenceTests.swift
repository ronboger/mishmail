import XCTest

final class PollCadenceTests: XCTestCase {
    func testFrontmostAppPollsAtTheActiveInterval() {
        XCTAssertEqual(PollCadence.interval(appActive: true, lowPowerMode: false),
                       PollCadence.active)
    }

    func testBackgroundedAppBacksOff() {
        XCTAssertEqual(PollCadence.interval(appActive: false, lowPowerMode: false),
                       PollCadence.background)
        XCTAssertGreaterThan(PollCadence.background, PollCadence.active)
    }

    func testLowPowerModeWinsOverFocus() {
        XCTAssertEqual(PollCadence.interval(appActive: true, lowPowerMode: true),
                       PollCadence.lowPower)
        XCTAssertEqual(PollCadence.interval(appActive: false, lowPowerMode: true),
                       PollCadence.lowPower)
    }

    /// The backoff exists to save wake-ups, not to strand mail. Notifications
    /// only arrive on a poll, so the backgrounded interval has to stay within
    /// a few minutes — this is the guardrail on tuning it later.
    func testBackgroundBackoffStaysWithinNotificationTolerance() {
        XCTAssertLessThanOrEqual(PollCadence.background, 300)
        XCTAssertLessThanOrEqual(PollCadence.lowPower, 600)
    }
}
