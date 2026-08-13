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
}
