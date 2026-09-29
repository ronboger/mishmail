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

    // MARK: - TimerTolerance

    func testToleranceIsTenPercentUnderCap() {
        XCTAssertEqual(TimerTolerance.forInterval(60, cap: TimerTolerance.pollCap), 6)
        XCTAssertEqual(TimerTolerance.forInterval(180, cap: TimerTolerance.pollCap), 18)
    }

    func testToleranceIsCapped() {
        XCTAssertEqual(TimerTolerance.forInterval(300, cap: TimerTolerance.pollCap), 30)
        XCTAssertEqual(TimerTolerance.forInterval(3_600, cap: TimerTolerance.updateCheckCap), 300)
        // A scheduled send an hour out still fires within a second.
        XCTAssertEqual(TimerTolerance.forInterval(3_600, cap: TimerTolerance.scheduledSendCap), 1)
    }

    func testToleranceNonPositiveInputsAreZero() {
        XCTAssertEqual(TimerTolerance.forInterval(0, cap: 1), 0)
        XCTAssertEqual(TimerTolerance.forInterval(-5, cap: 1), 0)
        XCTAssertEqual(TimerTolerance.forInterval(10, cap: 0), 0)
    }
}

