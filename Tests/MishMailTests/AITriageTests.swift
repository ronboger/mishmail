import XCTest

final class AITriageTests: XCTestCase {

    func testAutoClassifyDefaultsOn() {
        let d = UserDefaults(suiteName: "AITriageTests.\(UUID().uuidString)")!
        d.removeObject(forKey: AITriage.autoClassifyKey)
        XCTAssertTrue(AITriage.isAutoClassifyEnabled(d))
        d.set(false, forKey: AITriage.autoClassifyKey)
        XCTAssertFalse(AITriage.isAutoClassifyEnabled(d))
        d.set(true, forKey: AITriage.autoClassifyKey)
        XCTAssertTrue(AITriage.isAutoClassifyEnabled(d))
    }

    func testSilentAutoSortSkipsHostedAndAllowsLocal() {
        func config(kind: LLMProviderKind, url: String) -> LLMProviderConfig {
            LLMProviderConfig(
                id: UUID(), kind: kind, label: "t",
                baseURL: url, defaultModel: "m", authMode: .apiKey)
        }
        XCTAssertFalse(AITriage.shouldSkipSilentAutoSort(
            config: config(kind: .ollama, url: "http://127.0.0.1:11434")))
        XCTAssertTrue(AITriage.shouldSkipSilentAutoSort(
            config: config(kind: .openAICompatible, url: "https://api.x.ai/v1")))
        XCTAssertFalse(AITriage.shouldSkipSilentAutoSort(
            config: config(kind: .ollama, url: "http://192.168.1.10:11434")))
        XCTAssertFalse(AITriage.shouldSkipSilentAutoSort(config: nil))
    }

    func testFailurePauseWindow() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(AITriage.isFailurePauseActive(pausedUntil: nil, now: now))
        XCTAssertTrue(AITriage.isFailurePauseActive(
            pausedUntil: now.addingTimeInterval(1), now: now))
        XCTAssertFalse(AITriage.isFailurePauseActive(
            pausedUntil: now.addingTimeInterval(-1), now: now))
        XCTAssertEqual(AITriage.failurePause, 600)
    }
}
