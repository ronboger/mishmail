import XCTest

final class ThreadSummaryPolicyTests: XCTestCase {
    private func message(_ id: String, body: String = "An update", labels: String = "INBOX") -> Message {
        Message(id: id, accountId: "me@example.com", gmailId: id, threadId: "thread",
                fromHeader: "Jane <jane@example.com>", toHeader: "me@example.com", ccHeader: "",
                subject: "Project", date: Date(timeIntervalSince1970: Double(id) ?? 0),
                snippet: "An update", bodyText: body, bodyHTML: nil, messageIdHeader: "",
                referencesHeader: "", labelIds: labels, isUnread: false, hasAttachment: false)
    }

    private func fingerprint(_ messages: [Message]) -> String {
        ThreadSummaryPolicy.fingerprint(subject: "Project", messages: messages)
    }

    func testNewOrRemovedRepliesMakeSummaryStale() {
        let first = [message("1"), message("2")]
        let row = ThreadSummaryRow(threadId: "thread", summary: "Summary", model: "m", updatedAt: Date(),
                                   contentFingerprint: fingerprint(first))
        XCTAssertTrue(ThreadSummaryPolicy.isCurrent(row, fingerprint: fingerprint(first)))
        XCTAssertFalse(ThreadSummaryPolicy.isCurrent(row, fingerprint: fingerprint(first + [message("3")])))
        XCTAssertFalse(ThreadSummaryPolicy.isCurrent(row, fingerprint: fingerprint([first[0]])))
    }

    func testReadLabelsHydrationAndDraftsDoNotExpireSummary() {
        let original = message("1")
        var hydrated = original
        hydrated.isUnread = true
        hydrated.labelIds = "INBOX UNREAD IMPORTANT"
        hydrated.bodyText = String(repeating: "Full body ", count: 100)
        hydrated.bodyHTML = "<p>Full body</p>"
        XCTAssertEqual(fingerprint([original]), fingerprint([hydrated, message("draft", labels: "DRAFT")]))
        XCTAssertEqual(fingerprint([message("2"), original]), fingerprint([original, message("2")]))
    }

    func testSubjectChangesAndUnknownLegacyCoverageRequireRefresh() {
        let messages = [message("1")]
        XCTAssertNotEqual(fingerprint(messages), ThreadSummaryPolicy.fingerprint(subject: "Changed", messages: messages))
        let legacy = ThreadSummaryRow(threadId: "thread", summary: "Old", model: "m", updatedAt: Date())
        XCTAssertFalse(ThreadSummaryPolicy.isCurrent(legacy, fingerprint: fingerprint(messages)))
        XCTAssertEqual(fingerprint([message("draft", labels: "DRAFT")]), "")
    }

    func testSummaryEligibilityIncludesLongHTMLButExcludesDrafts() {
        XCTAssertFalse(ThreadSummaryPolicy.isWorthSummarizing([message("1")]))
        XCTAssertTrue(ThreadSummaryPolicy.isWorthSummarizing([message("1"), message("2")]))
        XCTAssertTrue(ThreadSummaryPolicy.isWorthSummarizing([message("1", body: String(repeating: "x", count: 801))]))
        var html = message("1", body: "")
        html.bodyHTML = String(repeating: "x", count: 2_001)
        XCTAssertTrue(ThreadSummaryPolicy.isWorthSummarizing([html]))
        XCTAssertFalse(ThreadSummaryPolicy.isWorthSummarizing([message("1"), message("2", labels: "DRAFT")]))
    }

    func testAutomaticSummariesRequireOptInLongMailAndLoopbackOllama() {
        let local = LLMProviderConfig(id: UUID(), kind: .ollama, label: "Local",
                                      baseURL: "http://127.0.0.1:11434", defaultModel: "m", authMode: .apiKey)
        let long = [message("1"), message("2"), message("3")]
        XCTAssertTrue(ThreadSummaryPolicy.shouldAutoSummarize(messages: long, config: local, enabled: true))
        for model in ["minimax-m3:cloud", "gpt-oss:120b-cloud", "vendor/gpt-oss:120b-CLOUD"] {
            XCTAssertFalse(ThreadSummaryPolicy.shouldAutoSummarize(messages: long, config: local,
                                                                   model: model, enabled: true))
        }
        XCTAssertFalse(LLMRemotePolicy.isOllamaCloudModel("cloudberry:7b"))
        XCTAssertFalse(ThreadSummaryPolicy.shouldAutoSummarize(messages: long, config: local, enabled: false))
        XCTAssertFalse(ThreadSummaryPolicy.shouldAutoSummarize(messages: [message("1")], config: local, enabled: true))
        XCTAssertFalse(ThreadSummaryPolicy.shouldAutoSummarize(messages: long, config: nil, enabled: true))
        var remote = local
        remote.baseURL = "http://192.168.1.10:11434"
        XCTAssertFalse(ThreadSummaryPolicy.shouldAutoSummarize(messages: long, config: remote, enabled: true))
        remote.baseURL = "https://api.example.com"
        XCTAssertFalse(ThreadSummaryPolicy.shouldAutoSummarize(messages: long, config: remote, enabled: true))
        remote.baseURL = "not a URL"
        XCTAssertFalse(ThreadSummaryPolicy.shouldAutoSummarize(messages: long, config: remote, enabled: true))
    }
}
