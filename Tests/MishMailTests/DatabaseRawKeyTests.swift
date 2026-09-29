import XCTest
import GRDB

/// The mail cache is keyed with SQLCipher's raw-key form (`x'<hex>'`), which
/// skips the 256k-iteration PBKDF2 the old passphrase form ran on every
/// connection. These cover the one-time conversion at open.
final class DatabaseRawKeyTests: XCTestCase {
    private let key = String(repeating: "ab", count: 32)
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("mail.sqlite").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mishmail-rawkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    private func configuration(keyString: String?) -> Configuration {
        var config = Configuration()
        if let keyString {
            config.prepareDatabase { db in try db.usePassphrase(keyString) }
        }
        return config
    }

    /// A migrated database with a few rows, written the way `keyString` says
    /// (nil = plaintext). Uses a pool so the file is in WAL mode like the app's,
    /// and leaves a non-empty WAL behind to exercise the checkpoint.
    private func makeDatabase(keyString: String?) throws {
        let pool = try DatabasePool(path: path, configuration: configuration(keyString: keyString))
        try AppDatabase.migrator.migrate(pool)
        try pool.write { db in
            // A private table keeps the fixture independent of later
            // migrations adding NOT NULL columns to the app's own tables.
            try db.execute(sql: "CREATE TABLE rekeyProbe (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
            for i in 0..<50 {
                try db.execute(sql: "INSERT INTO rekeyProbe (body) VALUES (?)",
                               arguments: [String(repeating: "mail \(i) ", count: 200)])
            }
        }
        try pool.close()
    }

    /// Opens with `keyString`, migrates (must be a no-op on converted files),
    /// and returns the fixture row count.
    private func threadCount(keyString: String?) throws -> Int {
        let queue = try DatabaseQueue(path: path, configuration: configuration(keyString: keyString))
        defer { try? queue.close() }
        try AppDatabase.migrator.migrate(queue)
        return try queue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM rekeyProbe") ?? 0 }
    }

    private func opens(keyString: String) -> Bool {
        (try? threadCount(keyString: keyString)) != nil
    }

    private var raw: String { AppDatabase.rawKeyLiteral(key) }

    // MARK: Tests

    func testMissingFileIsCreatedRawKeyed() throws {
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        try makeDatabase(keyString: raw)
        XCTAssertTrue(opens(keyString: raw))
        XCTAssertFalse(opens(keyString: key), "new files must not be passphrase-keyed")
    }

    func testPassphraseDatabaseIsConvertedAndKeepsData() throws {
        try makeDatabase(keyString: key)
        let before = try DatabaseQueue(path: path, configuration: configuration(keyString: key))
        let migrationsBefore = try before.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations") ?? 0
        }
        try before.close()
        XCTAssertGreaterThan(migrationsBefore, 0)

        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)

        XCTAssertFalse(opens(keyString: key), "old passphrase must no longer open the file")
        XCTAssertEqual(try threadCount(keyString: raw), 50)
        let queue = try DatabaseQueue(path: path, configuration: configuration(keyString: raw))
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"),
                           migrationsBefore, "export must carry GRDB's migration log")
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
        }
        try queue.close()
        for leftover in [".rekeying", ".rekeying-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path + leftover))
        }
    }

    func testRawKeyedDatabaseIsNotConverted() throws {
        try makeDatabase(keyString: raw)
        let before = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(16)
        var swapped = false
        let scheme = try AppDatabase.prepareDatabaseFile(path: path, key: key) { _ in swapped = true }
        XCTAssertEqual(scheme, .raw)
        XCTAssertFalse(swapped, "raw-keyed file must not be re-exported")
        // Same salt = same file, not a rewritten copy.
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)).prefix(16), before)
        XCTAssertEqual(try threadCount(keyString: raw), 50)
    }

    func testFailedConversionLeavesOriginalAndFallsBackToPassphrase() throws {
        try makeDatabase(keyString: key)
        struct Injected: Error {}
        let scheme = try AppDatabase.prepareDatabaseFile(path: path, key: key) { _ in
            throw Injected()
        }
        XCTAssertEqual(scheme, .passphrase)
        XCTAssertEqual(try threadCount(keyString: key), 50, "original must be intact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".rekeying"))

        // Next launch retries and succeeds.
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        XCTAssertEqual(try threadCount(keyString: raw), 50)
    }

    func testPlaintextDatabaseIsEncryptedWithRawKey() throws {
        try makeDatabase(keyString: nil)
        XCTAssertTrue(AppDatabase.isPlaintext(path))
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        XCTAssertFalse(AppDatabase.isPlaintext(path))
        XCTAssertFalse(opens(keyString: key))
        XCTAssertEqual(try threadCount(keyString: raw), 50)
    }

    func testUnknownKeyIsLeftForRecovery() throws {
        try makeDatabase(keyString: AppDatabase.rawKeyLiteral(String(repeating: "cd", count: 32)))
        var swapped = false
        let scheme = try AppDatabase.prepareDatabaseFile(path: path, key: key) { _ in swapped = true }
        XCTAssertEqual(scheme, .raw, "neither key works: let the caller's reset path run")
        XCTAssertFalse(swapped)
    }

    /// Raw-key open skips PBKDF2, so it must beat the passphrase open. Only a
    /// relative assertion; the absolute numbers are logged for the record.
    func testRawKeyOpenIsFasterThanPassphraseOpen() throws {
        let passPath = dir.appendingPathComponent("pass.sqlite").path
        let rawPath = dir.appendingPathComponent("raw.sqlite").path
        for (p, k) in [(passPath, key), (rawPath, raw)] {
            let q = try DatabaseQueue(path: p, configuration: configuration(keyString: k))
            try q.write { db in try db.execute(sql: "CREATE TABLE t(x)") }
            try q.close()
        }
        func openTime(_ p: String, _ k: String) throws -> TimeInterval {
            var best = TimeInterval.infinity
            for _ in 0..<3 {
                let start = Date()
                let q = try DatabaseQueue(path: p, configuration: configuration(keyString: k))
                _ = try q.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") }
                try q.close()
                best = min(best, Date().timeIntervalSince(start))
            }
            return best
        }
        let passphrase = try openTime(passPath, key)
        let rawKey = try openTime(rawPath, raw)
        NSLog("MishMail rawkey timing: passphrase open %.2f ms, raw-key open %.2f ms",
              passphrase * 1000, rawKey * 1000)
        XCTAssertLessThan(rawKey, passphrase)
    }

    func testConversionKeepsIncrementalAutoVacuum() throws {
        try makeDatabase(keyString: key)
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        let queue = try DatabaseQueue(path: path, configuration: configuration(keyString: raw))
        defer { try? queue.close() }
        // 2 = INCREMENTAL; anything else makes reclaimSpaceIfNeeded run a
        // second full VACUUM right after the conversion.
        XCTAssertEqual(try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") }, 2)
    }

    func testPlaintextEncryptionKeepsIncrementalAutoVacuum() throws {
        try makeDatabase(keyString: nil)
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        let queue = try DatabaseQueue(path: path, configuration: configuration(keyString: raw))
        defer { try? queue.close() }
        XCTAssertEqual(try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") }, 2)
    }

    func testConversionDeferredWhileAnotherInstanceRuns() throws {
        try makeDatabase(keyString: key)
        XCTAssertEqual(
            try AppDatabase.prepareDatabaseFile(path: path, key: key, allowConversion: false),
            .passphrase)
        XCTAssertTrue(opens(keyString: key), "file must be left passphrase-keyed")
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        XCTAssertTrue(opens(keyString: raw))
    }

    func testConversionAbortsWhileAnotherConnectionHoldsTheWAL() throws {
        try makeDatabase(keyString: key)
        // A second connection mid-read pins the WAL, so TRUNCATE reports busy.
        let other = try DatabasePool(path: path, configuration: configuration(keyString: key))
        defer { try? other.close() }
        try other.write { db in
            try db.execute(sql: "INSERT INTO rekeyProbe (body) VALUES ('late')")
        }
        let scheme = try other.read { _ in
            try AppDatabase.prepareDatabaseFile(path: path, key: key)
        }
        XCTAssertEqual(scheme, .passphrase)
        XCTAssertTrue(opens(keyString: key))
    }

    func testOnlyEnvironmentFailuresAreTransient() {
        for code: ResultCode in [.SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_FULL,
                                 .SQLITE_IOERR, .SQLITE_NOMEM, .SQLITE_CANTOPEN] {
            XCTAssertTrue(AppDatabase.isTransientOpenError(DatabaseError(resultCode: code)), "\(code)")
        }
        // Key, corruption and migration failures keep the reset path.
        for code: ResultCode in [.SQLITE_NOTADB, .SQLITE_CORRUPT, .SQLITE_CONSTRAINT, .SQLITE_ERROR] {
            XCTAssertFalse(AppDatabase.isTransientOpenError(DatabaseError(resultCode: code)), "\(code)")
        }
        struct NotSQLite: Error {}
        XCTAssertFalse(AppDatabase.isTransientOpenError(NotSQLite()))
    }

    func testPlaintextEncryptionDeferredWhileAnotherInstanceRuns() throws {
        try makeDatabase(keyString: nil)
        XCTAssertEqual(
            try AppDatabase.prepareDatabaseFile(path: path, key: key, allowConversion: false),
            .plaintext)
        XCTAssertTrue(AppDatabase.isPlaintext(path))
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        XCTAssertTrue(opens(keyString: raw))
    }
}
