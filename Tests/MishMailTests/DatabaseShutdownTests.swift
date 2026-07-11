import XCTest
import GRDB

/// Regression: process teardown must not race live GRDB readers (SQLCipher
/// EXC_BAD_ACCESS in sqlcipher_page_hmac when atexit runs while a reader
/// is still decrypting pages — the contacts-rebuild crash path).
final class DatabaseShutdownTests: XCTestCase {

    /// `DatabaseLifecycle.shutDown` runs cancel → interrupt → await → close.
    func testShutDownOrderIsCancelInterruptAwaitClose() async {
        final class Order: @unchecked Sendable {
            private let lock = NSLock()
            private var steps: [String] = []
            func append(_ s: String) {
                lock.lock(); steps.append(s); lock.unlock()
            }
            var snapshot: [String] {
                lock.lock(); defer { lock.unlock() }
                return steps
            }
        }
        let order = Order()

        let path = NSTemporaryDirectory() + "mishmail-shutdown-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let pool = try! DatabasePool(path: path)
        try! await pool.write { db in
            try db.execute(sql: "CREATE TABLE t(x TEXT)")
            try db.execute(sql: "INSERT INTO t(x) VALUES ('hello')")
        }

        let task = Task {
            // Cooperative cancel checkpoint before the read, matching
            // MailStore tasks that guard `Task.isCancelled` at entry.
            if Task.isCancelled {
                order.append("task-done")
                return
            }
            _ = try? await pool.read { db in
                try String.fetchOne(db, sql: "SELECT x FROM t")
            }
            order.append("task-done")
        }

        await DatabaseLifecycle.shutDown(
            tasks: [task],
            interrupt: {
                order.append("interrupt")
                pool.interrupt()
            },
            close: {
                order.append("close")
                try? pool.close()
            }
        )

        let steps = order.snapshot
        XCTAssertTrue(steps.contains("interrupt"), "got \(steps)")
        XCTAssertTrue(steps.contains("task-done"), "got \(steps)")
        XCTAssertEqual(steps.last, "close", "close must be last; got \(steps)")
        // Await of the task must finish before close (the actual crash guard).
        XCTAssertLessThan(
            steps.firstIndex(of: "task-done")!,
            steps.firstIndex(of: "close")!)

        // Post-close access must not crash the process (throws / fails).
        do {
            _ = try await pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t")
            }
            XCTFail("read after close should throw")
        } catch {
            // Expected — pool is closed.
        }
    }

    /// Idempotent close: second call is a no-op (mirrors AppDatabase.close).
    func testCloseIsIdempotent() throws {
        let path = NSTemporaryDirectory() + "mishmail-close-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let pool = try DatabasePool(path: path)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE t(x INTEGER)")
        }
        try pool.close()
        try pool.close() // must not crash
    }

    /// Cancelling a reader Task and awaiting it before close avoids leaving
    /// work on GRDB.DatabasePool.reader queues across pool deallocation —
    /// the same lifecycle as MailStore.rebuildContacts + prepareForTermination.
    func testCancelAndAwaitContactsStyleReaderBeforeClose() async throws {
        let path = NSTemporaryDirectory() + "mishmail-cancel-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let pool = try DatabasePool(path: path)
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TABLE message(
                    fromHeader TEXT, toHeader TEXT, ccHeader TEXT, labelIds TEXT)
                """)
            for _ in 0..<500 {
                try db.execute(
                    sql: "INSERT INTO message VALUES (?,?,?,?)",
                    arguments: [
                        "Alice <a@example.com>",
                        "Bob <b@example.com>",
                        "",
                        "INBOX",
                    ])
            }
        }

        // Same shape as MailStore.rebuildContacts's full-table scan.
        let task = Task {
            _ = try? await pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT rowid, fromHeader, toHeader, ccHeader, labelIds FROM message
                    ORDER BY rowid
                    """).map { row -> (Int64, String) in
                        (row["rowid"], row["fromHeader"])
                    }
            }
        }

        // Yield so the read can start, then ordered shutdown.
        try await Task.sleep(nanoseconds: 5_000_000)
        await DatabaseLifecycle.shutDown(
            tasks: [task],
            interrupt: { pool.interrupt() },
            close: { try? pool.close() }
        )
        // Reaching here without EXC_BAD_ACCESS is the assertion.
    }

    /// Empty task list still closes cleanly (quit with no background work).
    func testShutDownWithNoTasksStillCloses() async throws {
        let path = NSTemporaryDirectory() + "mishmail-empty-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let pool = try DatabasePool(path: path)
        var closed = false
        await DatabaseLifecycle.shutDown(
            tasks: [],
            interrupt: { pool.interrupt() },
            close: {
                try? pool.close()
                closed = true
            }
        )
        XCTAssertTrue(closed)
    }

    /// Double-quit re-entry: concurrent callers share one in-flight shutdown
    /// and all return only after close — mirrors prepareForTermination so a
    /// second Cmd-Q cannot reply(true) while the first close is mid-flight.
    ///
    /// Fires both callers without a multi-ms stagger so the MainActor
    /// check/set serialization is what prevents double-start (not timing).
    @MainActor
    func testSingleFlightAwaitsOneSharedShutdown() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _starts = 0
            private var _closes = 0
            private var _finishers = Set<Int>()
            func start() {
                lock.lock(); _starts += 1; lock.unlock()
            }
            func close() {
                lock.lock(); _closes += 1; lock.unlock()
            }
            func finished(_ id: Int) {
                lock.lock(); _finishers.insert(id); lock.unlock()
            }
            var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }
            var closes: Int { lock.lock(); defer { lock.unlock() }; return _closes }
            var finishers: Set<Int> { lock.lock(); defer { lock.unlock() }; return _finishers }
        }
        let counter = Counter()
        let slot = DatabaseLifecycle.FlightSlot()
        // Controllable hold: work suspends until both callers are in flight.
        let gate = AsyncStream<Void>.makeStream()
        var gateContinuation: AsyncStream<Void>.Continuation? = gate.continuation

        let first = Task { @MainActor in
            await DatabaseLifecycle.singleFlight(slot: slot) {
                counter.start()
                for await _ in gate.stream { break }
                counter.close()
            }
            counter.finished(1)
        }
        // Yield once so first can install slot.task and suspend in work.
        await Task.yield()

        let second = Task { @MainActor in
            await DatabaseLifecycle.singleFlight(slot: slot) {
                counter.start() // must not run
                counter.close()
            }
            counter.finished(2)
        }
        // Immediately release — no 20ms buffer papering over a check/set race.
        await Task.yield()
        gateContinuation?.yield(())
        gateContinuation?.finish()
        gateContinuation = nil
        await first.value
        await second.value

        XCTAssertEqual(counter.starts, 1, "work body must run once")
        XCTAssertEqual(counter.closes, 1, "close must run once")
        XCTAssertEqual(counter.finishers, [1, 2],
                       "both callers return only after shared work finishes")
    }

    /// Successful close is idempotent via isClosed; failed close must leave
    /// the pool open for interrupt/retry (isClosed only set on success).
    func testCloseOnlyMarksClosedAfterSuccess() throws {
        let path = NSTemporaryDirectory() + "mishmail-closed-flag-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let pool = try DatabasePool(path: path)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE t(x INTEGER)")
        }

        var isClosed = false
        func closeLikeAppDatabase() {
            guard !isClosed else { return }
            do {
                try pool.close()
                isClosed = true
            } catch {
                // leave isClosed false — same as AppDatabase.close
            }
        }

        closeLikeAppDatabase()
        XCTAssertTrue(isClosed)
        closeLikeAppDatabase() // second call no-ops on flag
        XCTAssertTrue(isClosed)
        // Do not call pool.interrupt() after a successful close — that can
        // crash. AppDatabase.interrupt() guards on isClosed for that reason,
        // while still allowing interrupt after a failed close (isClosed false).
    }
}
