import GRDB
import XCTest

final class LLMUsageLogTests: XCTestCase {
    func testMigrationCreatesUsageTableAndRoundTrips() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let row = LLMUsageRow(id: "u1", task: "drafts", providerID: "p", model: "m",
                              promptTokens: 100, completionTokens: 20,
                              createdAt: Date(timeIntervalSince1970: 50))
        try q.write { db in try row.save(db) }
        try q.read { db in
            XCTAssertEqual(try LLMUsageRow.fetchCount(db), 1)
        }
    }

    func testSummarizeGroupsByTaskWithinWindowAndPrices() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-40 * 86_400)
        let rows = [
            LLMUsageLog.row(task: .drafts,
                            config: LLMProviderConfig(id: UUID(), kind: .openAICompatible,
                                                      label: "Grok", baseURL: "https://api.x.ai/v1",
                                                      defaultModel: "grok-4-0709", authMode: .apiKey),
                            model: "grok-4-0709",
                            usage: LLMUsage(promptTokens: 1_000_000, completionTokens: 0), now: now),
            LLMUsageLog.row(task: .drafts,
                            config: LLMProviderConfig(id: UUID(), kind: .ollama, label: "Ollama",
                                                      baseURL: "http://127.0.0.1:11434",
                                                      defaultModel: "llama3.2", authMode: .apiKey),
                            model: "llama3.2",
                            usage: LLMUsage(promptTokens: 500, completionTokens: 50), now: old),
        ]
        let spends = LLMUsageLog.summarize(
            rows: rows, since: now.addingTimeInterval(-30 * 86_400),
            overrides: ["grok-4-0709": LLMPrice(inputPerMTok: 3, outputPerMTok: 15)])
        XCTAssertEqual(spends.count, 1)                     // old row excluded
        XCTAssertEqual(spends[0].task, .drafts)
        XCTAssertEqual(spends[0].promptTokens, 1_000_000)
        XCTAssertEqual(spends[0].estimatedUSD ?? 0, 3.0, accuracy: 0.0001)
    }

    func testSummarizeNilUSDWhenAnyModelUnpriced() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let rows = [LLMUsageRow(id: "1", task: "triage", providerID: "p",
                                model: "mystery-model", promptTokens: 10,
                                completionTokens: 1, createdAt: now)]
        let spends = LLMUsageLog.summarize(rows: rows, since: now.addingTimeInterval(-60),
                                           overrides: [:])
        XCTAssertEqual(spends.count, 1)
        XCTAssertNil(spends[0].estimatedUSD)
    }


    func testMigrationAddsCacheColumnsAndRoundTripsThem() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            let usageCols = try db.columns(in: "llmUsage").map(\.name)
            XCTAssertTrue(usageCols.contains("cacheCreationTokens"), "v41 must add cacheCreationTokens")
            XCTAssertTrue(usageCols.contains("cacheReadTokens"), "v41 must add cacheReadTokens")
            let chatCols = try db.columns(in: "chatMessage").map(\.name)
            XCTAssertTrue(chatCols.contains("cacheCreationTokens"))
            XCTAssertTrue(chatCols.contains("cacheReadTokens"))
        }
        let row = LLMUsageRow(id: "u1", task: "askMish", providerID: "p", model: "m",
                              promptTokens: 10, completionTokens: 2,
                              cacheCreationTokens: 300, cacheReadTokens: 4_000,
                              createdAt: Date(timeIntervalSince1970: 50))
        try q.write { db in try row.insert(db) }
        let fetched = try q.read { db in try LLMUsageRow.fetchOne(db, key: "u1") }
        XCTAssertEqual(fetched?.cacheCreationTokens, 300)
        XCTAssertEqual(fetched?.cacheReadTokens, 4_000)
    }

    func testV40DefaultsOldUsageRowsToZeroCacheTokens() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v39")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO llmUsage (id, task, providerID, model, promptTokens,
                                      completionTokens, createdAt)
                VALUES ('old', 'drafts', 'p', 'm', 5, 1, '2026-01-01 00:00:00.000')
                """)
        }
        try AppDatabase.migrator.migrate(q)
        let fetched = try q.read { db in try LLMUsageRow.fetchOne(db, key: "old") }
        XCTAssertEqual(fetched?.cacheCreationTokens, 0)
        XCTAssertEqual(fetched?.cacheReadTokens, 0)
    }

    func testRowAndSummarizeCarryCacheTokensIntoTotalsAndCost() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let config = LLMProviderConfig(id: UUID(), kind: .anthropic, label: "Claude",
                                       baseURL: "https://api.anthropic.com",
                                       defaultModel: "priced", authMode: .apiKey)
        let row = LLMUsageLog.row(
            task: .askMish, config: config, model: "priced",
            usage: LLMUsage(promptTokens: 0, completionTokens: 0,
                            cacheCreationInputTokens: 1_000_000,
                            cacheReadInputTokens: 1_000_000),
            now: now)
        XCTAssertEqual(row.cacheCreationTokens, 1_000_000)
        XCTAssertEqual(row.cacheReadTokens, 1_000_000)
        let spends = LLMUsageLog.summarize(
            rows: [row, row], since: now.addingTimeInterval(-60),
            overrides: ["priced": LLMPrice(inputPerMTok: 10, outputPerMTok: 0)])
        XCTAssertEqual(spends.count, 1)
        XCTAssertEqual(spends[0].cacheCreationTokens, 2_000_000)
        XCTAssertEqual(spends[0].cacheReadTokens, 2_000_000)
        // Per row: 1M writes at 1.25x + 1M reads at 0.1x of $10 = $13.50.
        XCTAssertEqual(spends[0].estimatedUSD ?? 0, 27.0, accuracy: 0.0001)
    }
}
