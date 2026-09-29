import XCTest

/// Sync single-flight used to hand a caller that arrived mid-pass the result
/// of a pass that started before its change. `CoalescingRunner` queues one
/// shared follow-up pass instead.
final class CoalescingRunnerTests: XCTestCase {
    /// Counts runs and lets a test hold a run open until released. A held
    /// run also ends when its task is cancelled.
    private actor Probe {
        private(set) var started = 0
        private var released = Set<Int>()

        func begin() -> Int {
            started += 1
            return started
        }

        func isReleased(_ run: Int) -> Bool { released.contains(run) }

        func release(run: Int) { released.insert(run) }
    }

    private func operation(_ probe: Probe, gated: Bool = true) -> @Sendable () async throws -> Int {
        {
            let run = await probe.begin()
            if gated {
                while !Task.isCancelled, !(await probe.isReleased(run)) {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            try Task.checkCancellation()
            return run
        }
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition never became true")
    }

    func testSingleCallerRunsOnce() async throws {
        let runner = CoalescingRunner<Int>()
        let probe = Probe()
        let value = try await runner.run(operation(probe, gated: false))
        XCTAssertEqual(value, 1)
        let started = await probe.started
        XCTAssertEqual(started, 1)
        let idle = await runner.isIdle
        XCTAssertTrue(idle)
    }

    /// Three callers arrive while pass 1 runs: they all get pass 2, which
    /// starts only after pass 1 ends, and no third pass runs.
    func testCallersDuringAPassShareOneFollowUp() async throws {
        let runner = CoalescingRunner<Int>()
        let probe = Probe()
        let owner = Task { try await runner.run(self.operation(probe)) }
        await waitUntil { await probe.started == 1 }

        let joiners = (0..<3).map { _ in
            Task { try await runner.run(self.operation(probe)) }
        }
        // Give joiners time to enqueue; the follow-up must not start yet.
        try await Task.sleep(nanoseconds: 50_000_000)
        let startedWhileRunning = await probe.started
        XCTAssertEqual(startedWhileRunning, 1)

        await probe.release(run: 1)
        let ownerValue = try await owner.value
        XCTAssertEqual(ownerValue, 1)
        await waitUntil { await probe.started == 2 }
        await probe.release(run: 2)
        for joiner in joiners {
            let value = try await joiner.value
            XCTAssertEqual(value, 2)
        }
        let started = await probe.started
        XCTAssertEqual(started, 2)
        let idle = await runner.isIdle
        XCTAssertTrue(idle)
    }

    /// The owner's cancellation stops its own pass but not the follow-up
    /// that joiners wait for.
    func testOwnerCancellationDoesNotReachJoiners() async throws {
        let runner = CoalescingRunner<Int>()
        let probe = Probe()
        let owner = Task { try await runner.run(self.operation(probe)) }
        await waitUntil { await probe.started == 1 }
        let joiner = Task { try await runner.run(self.operation(probe)) }
        try await Task.sleep(nanoseconds: 50_000_000)

        owner.cancel()
        do {
            _ = try await owner.value
            XCTFail("owner pass should be cancelled")
        } catch is CancellationError {}

        await waitUntil { await probe.started == 2 }
        await probe.release(run: 2)
        let value = try await joiner.value
        XCTAssertEqual(value, 2)
    }

    /// A joiner's cancellation must not cancel the shared follow-up.
    func testJoinerCancellationDoesNotCancelTheSharedPass() async throws {
        let runner = CoalescingRunner<Int>()
        let probe = Probe()
        let owner = Task { try await runner.run(self.operation(probe)) }
        await waitUntil { await probe.started == 1 }
        let cancelled = Task { try await runner.run(self.operation(probe)) }
        let kept = Task { try await runner.run(self.operation(probe)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelled.cancel()

        await probe.release(run: 1)
        _ = try await owner.value
        await waitUntil { await probe.started == 2 }
        await probe.release(run: 2)
        let value = try await kept.value
        XCTAssertEqual(value, 2)
    }

    func testCancelAllStopsRunningAndQueuedPasses() async throws {
        let runner = CoalescingRunner<Int>()
        let probe = Probe()
        let owner = Task { try await runner.run(self.operation(probe)) }
        await waitUntil { await probe.started == 1 }
        let joiner = Task { try await runner.run(self.operation(probe)) }
        try await Task.sleep(nanoseconds: 50_000_000)

        await runner.cancelAll()
        do {
            _ = try await owner.value
            XCTFail("running pass should be cancelled")
        } catch is CancellationError {}
        do {
            _ = try await joiner.value
            XCTFail("queued pass should be cancelled")
        } catch is CancellationError {}
        let started = await probe.started
        XCTAssertEqual(started, 1)
        let idle = await runner.isIdle
        XCTAssertTrue(idle)
    }

    /// Once a pass ends, the next caller starts a fresh pass right away.
    func testCallAfterCompletionStartsANewPass() async throws {
        let runner = CoalescingRunner<Int>()
        let probe = Probe()
        let first = try await runner.run(operation(probe, gated: false))
        let second = try await runner.run(operation(probe, gated: false))
        XCTAssertEqual([first, second], [1, 2])
    }
}
