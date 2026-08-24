import XCTest

final class AskMishTraceTests: XCTestCase {

    func testStatusLabelPresentAndPast() {
        let running = AskMishTrace.Tool(
            id: "1", name: "search_threads", status: .running,
            argumentsJSON: "{}", resultPreview: nil, threads: [], canUndoSend: false)
        XCTAssertEqual(AskMishTrace.statusLabel(running), "Searching mail…")
        var done = running
        done.status = .done
        XCTAssertEqual(AskMishTrace.statusLabel(done), "Searched mail")
        done.status = .failed
        XCTAssertTrue(AskMishTrace.statusLabel(done).contains("failed"))
    }

    func testArgumentSummaryReadsQueryAndMailbox() {
        XCTAssertEqual(
            AskMishTrace.argumentSummary(
                name: "search_threads", argumentsJSON: #"{"query":"acme"}"#),
            "acme")
        XCTAssertEqual(
            AskMishTrace.argumentSummary(
                name: "list_threads", argumentsJSON: #"{"mailbox":"inbox"}"#),
            "inbox")
        XCTAssertNil(AskMishTrace.argumentSummary(name: "list_accounts", argumentsJSON: "{}"))
    }

    func testThreadsFromSearchJSON() {
        let json = #"[{"id":"a:1","subject":"Hello"},{"id":"a:2","subject":"Bye"}]"#
        let refs = AskMishTrace.threads(
            name: "search_threads", argumentsJSON: "{}", result: json)
        XCTAssertEqual(refs.map(\.id), ["a:1", "a:2"])
        XCTAssertEqual(refs.first?.subject, "Hello")
    }

    func testGetThreadUsesArgumentIdAndMarkdownTitle() {
        let refs = AskMishTrace.threads(
            name: "get_thread",
            argumentsJSON: #"{"thread_id":"acct:t1"}"#,
            result: "# Invoice due\n\nPlease pay.")
        XCTAssertEqual(refs, [AskMishTrace.ThreadRef(id: "acct:t1", subject: "Invoice due")])
    }

    func testFinishedMarksQueuedSendUndoable() {
        let running = AskMishTrace.running(LLMToolCall(
            id: "c1", name: "send_draft", argumentsJSON: #"{"draft_id":"d"}"#))
        let done = AskMishTrace.finished(
            from: running,
            result: LLMToolResult(callID: "c1",
                                  content: #"{"status":"queued","undoSeconds":10}"#,
                                  isError: false))
        XCTAssertEqual(done.status, .done)
        XCTAssertTrue(done.canUndoSend)
        let failed = AskMishTrace.finished(
            from: running,
            result: LLMToolResult(callID: "c1", content: "nope", isError: true))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertFalse(failed.canUndoSend)
    }

    func testAuditLineCountsThreadsDraftsAndSends() {
        let tools = [
            AskMishTrace.Tool(
                id: "1", name: "search_threads", status: .done, argumentsJSON: "{}",
                resultPreview: nil,
                threads: [AskMishTrace.ThreadRef(id: "t1", subject: "A"),
                          AskMishTrace.ThreadRef(id: "t2", subject: "B")],
                canUndoSend: false),
            AskMishTrace.Tool(
                id: "2", name: "create_draft", status: .done, argumentsJSON: "{}",
                resultPreview: nil, threads: [], canUndoSend: false),
        ]
        XCTAssertEqual(AskMishTrace.auditLine(tools: tools),
                       "Read 2 threads. Created 1 draft. Sent nothing.")
    }

    func testAuditLineNilWhenNoTools() {
        XCTAssertNil(AskMishTrace.auditLine(tools: []))
    }

    func testEmptyPromptsDependOnOpenThread() {
        let open = AskMishTrace.emptyPrompts(hasSelectedThread: true)
        XCTAssertEqual(open.map(\.title), ["Summarize this", "Draft a yes", "Find related mail"])
        XCTAssertTrue(open[0].prompt.contains("thread"))
        let none = AskMishTrace.emptyPrompts(hasSelectedThread: false)
        XCTAssertEqual(none.count, 3)
        XCTAssertFalse(none.map(\.title).contains("Summarize this"))
    }

    func testTracesPairCallsWithResults() {
        let calls = [LLMToolCall(id: "c1", name: "get_thread",
                                 argumentsJSON: #"{"thread_id":"t1"}"#)]
        let results = [LLMToolResult(callID: "c1", content: "# Hello\n", isError: false)]
        let traces = AskMishTrace.traces(calls: calls, results: results)
        XCTAssertEqual(traces.count, 1)
        XCTAssertEqual(traces[0].status, .done)
        XCTAssertEqual(traces[0].threads.first?.id, "t1")
    }

    func testFollowUpsDedupeAndCap() {
        let chips = AskMishTrace.followUps(
            toolNames: ["search_threads", "get_thread", "create_draft"],
            hasSelectedThread: true)
        XCTAssertLessThanOrEqual(chips.count, 3)
        XCTAssertEqual(Set(chips.map(\.title)).count, chips.count)
        XCTAssertTrue(chips.contains { $0.title == "Send it" })
    }
}
