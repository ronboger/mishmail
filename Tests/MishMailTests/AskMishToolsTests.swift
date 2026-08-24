import XCTest

final class AskMishToolsTests: XCTestCase {
    func testSpecsIncludeCatalogAndSendDraft() throws {
        let specs = AskMishTools.llmToolSpecs()
        let names = specs.map(\.name)
        XCTAssertTrue(names.contains("search_threads"))
        XCTAssertTrue(names.contains("create_draft"))
        XCTAssertTrue(names.contains("send_draft"))
        XCTAssertEqual(names.count, MCPTools.catalog.count + 1)
        // Schemas are valid JSON objects.
        for spec in specs {
            let object = try JSONSerialization.jsonObject(with: Data(spec.inputSchemaJSON.utf8))
            XCTAssertNotNil(object as? [String: Any], spec.name)
        }
    }

    /// send_draft is Ask Mish-only: external MCP clients must not see it.
    func testSendDraftIsNotInMCPCatalog() {
        XCTAssertFalse(MCPTools.catalog.map(\.name).contains(AskMishTools.sendDraftToolName))
    }

    func testSendDraftSchemaRequiresDraftId() throws {
        let specs = AskMishTools.llmToolSpecs()
        guard let spec = specs.first(where: { $0.name == "send_draft" }) else {
            return XCTFail("send_draft missing")
        }
        let object = try JSONSerialization.jsonObject(
            with: Data(spec.inputSchemaJSON.utf8)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "object")
        XCTAssertEqual(object?["required"] as? [String], ["draft_id"])
        let properties = object?["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["draft_id"])
        XCTAssertFalse(spec.description.isEmpty)
    }

    func testWriteToolClassification() {
        XCTAssertTrue(AskMishTools.isWriteTool("create_draft"))
        XCTAssertTrue(AskMishTools.isWriteTool("send_draft"))
        XCTAssertTrue(AskMishTools.isWriteTool("remove_vip"))
        XCTAssertTrue(AskMishTools.isWriteTool("set_thread_summary"))
        XCTAssertTrue(AskMishTools.isWriteTool("clear_thread_summary"))
        XCTAssertTrue(AskMishTools.isWriteTool("add_vip"))
        XCTAssertTrue(AskMishTools.isWriteTool("add_vips"))
        XCTAssertTrue(AskMishTools.isWriteTool("set_vip_groups"))
        XCTAssertFalse(AskMishTools.isWriteTool("search_threads"))
        XCTAssertFalse(AskMishTools.isWriteTool("get_thread"))
        XCTAssertFalse(AskMishTools.isWriteTool("list_accounts"))
        XCTAssertFalse(AskMishTools.isWriteTool("list_threads"))
        XCTAssertFalse(AskMishTools.isWriteTool("list_drafts"))
        XCTAssertFalse(AskMishTools.isWriteTool("list_vips"))
        XCTAssertTrue(AskMishTools.isWriteTool("invented_mutating_tool"),
                      "unknown tools must confirm, not run as reads")
    }

    /// Every offered tool is classified read or write on purpose — a new
    /// mutating tool must be added to the write set, not default to read.
    func testEveryOfferedToolIsClassified() {
        let names = Set(AskMishTools.llmToolSpecs().map(\.name))
        XCTAssertTrue(AskMishTools.writeToolNames.isDisjoint(with: AskMishTools.readToolNames))
        XCTAssertEqual(names, AskMishTools.writeToolNames.union(AskMishTools.readToolNames),
                       "A new tool must be added to readToolNames or writeToolNames")
    }

    func testCreateAndSendRequireExplicitClick() {
        XCTAssertTrue(AskMishTools.requiresExplicitClick("create_draft"))
        XCTAssertTrue(AskMishTools.requiresExplicitClick("send_draft"))
        XCTAssertTrue(AskMishTools.requiresExplicitClick("invented_mutating_tool"))
        XCTAssertFalse(AskMishTools.requiresExplicitClick("add_vip"))
        XCTAssertFalse(AskMishTools.requiresExplicitClick("search_threads"))
    }

    func testCreateDraftConfirmIncludesBodyPreview() {
        let content = AskMishTools.confirmContent(
            toolName: "create_draft",
            argumentsJSON: #"{"account":"a@b.com","to":["c@d.com"],"subject":"Hello","body":"Please send the files."}"#)
        XCTAssertTrue(content.summary.contains("c@d.com"))
        XCTAssertEqual(content.bodyPreview, "Please send the files.")
        XCTAssertTrue(content.requiresExplicitClick)
    }

    func testSendFingerprintChangesWhenBodyChanges() {
        let a = AskMishTools.sendFingerprint(
            accountId: "acct", from: "me@x.com",
            to: "a@b.com", cc: "", bcc: "", subject: "Hi", body: "one")
        let b = AskMishTools.sendFingerprint(
            accountId: "acct", from: "me@x.com",
            to: "a@b.com", cc: "", bcc: "", subject: "Hi", body: "two")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, AskMishTools.sendFingerprint(
            accountId: "acct", from: "me@x.com",
            to: "a@b.com", cc: "", bcc: "", subject: "Hi", body: "one"))
        let otherFrom = AskMishTools.sendFingerprint(
            accountId: "acct", from: "other@x.com",
            to: "a@b.com", cc: "", bcc: "", subject: "Hi", body: "one")
        XCTAssertNotEqual(a, otherFrom)
    }

    func testSendDraftSummaryNamesFrom() {
        let line = AskMishTools.sendDraftSummary(
            recipients: ["a@b.com"], subject: "Hi", from: "me@x.com")
        XCTAssertTrue(line.contains("me@x.com"), line)
        XCTAssertTrue(line.contains("a@b.com"), line)
    }

    func testOffThreadRecipientsIgnoresPeopleAlreadyOnTheThread() {
        let off = AskMishTools.offThreadRecipients(
            sending: ["Eve@x.com", "a@b.com", "eve@x.com"],
            threadAddresses: ["a@b.com", "c@d.com"])
        XCTAssertEqual(off, ["Eve@x.com"])
    }

    func testPreviewTruncatesLongBodies() {
        XCTAssertNil(AskMishTools.preview("   "))
        XCTAssertEqual(AskMishTools.preview("short"), "short")
        let long = String(repeating: "x", count: 600)
        let preview = AskMishTools.preview(long, limit: 500)
        XCTAssertEqual(preview?.count, 501) // 500 + ellipsis
        XCTAssertTrue(preview?.hasSuffix("…") == true)
    }

    func testDecodeArgumentsRejectsNonObject() {
        XCTAssertNoThrow(try AskMishTools.decodeArguments(#"{"query":"acme"}"#))
        XCTAssertThrowsError(try AskMishTools.decodeArguments(#"["not","object"]"#))
        XCTAssertThrowsError(try AskMishTools.decodeArguments("not json"))
        XCTAssertThrowsError(try AskMishTools.decodeArguments("42"))
    }

    func testDecodeArgumentsProducesDispatcherValues() throws {
        let args = try AskMishTools.decodeArguments(
            #"{"query":"acme","limit":10,"unread_only":true,"to":["a@b.com"]}"#)
        XCTAssertEqual(args["query"], .string("acme"))
        XCTAssertEqual(args["limit"], .int(10))
        XCTAssertEqual(args["unread_only"], .bool(true))
        XCTAssertEqual(args["to"], .array([.string("a@b.com")]))
    }

    /// No-arg tools (list_accounts) arrive with an empty or missing argument
    /// blob from some providers; that means "no arguments", not a parse error.
    func testDecodeArgumentsAcceptsEmptyInput() throws {
        XCTAssertEqual(try AskMishTools.decodeArguments(""), [:])
        XCTAssertEqual(try AskMishTools.decodeArguments("   "), [:])
        XCTAssertEqual(try AskMishTools.decodeArguments("{}"), [:])
    }

    func testConfirmSummaryNamesTheAction() {
        let summary = AskMishTools.confirmSummary(
            toolName: "create_draft",
            argumentsJSON: #"{"account":"a@b.com","to":["c@d.com"],"subject":"Hello","body":"x"}"#)
        XCTAssertTrue(summary.contains("c@d.com"))
        XCTAssertTrue(summary.contains("Hello"))
    }

    func testConfirmSummaryCoversEveryWriteTool() {
        let cases: [(String, String, [String])] = [
            ("send_draft", #"{"draft_id":"acct:1234"}"#, ["Send", "acct:1234"]),
            ("set_thread_summary",
             #"{"thread_id":"a:t1","summary":"s","model":"m"}"#, ["a:t1"]),
            ("clear_thread_summary", #"{"thread_id":"a:t1"}"#, ["a:t1"]),
            ("add_vip", #"{"email":"v@x.com"}"#, ["v@x.com"]),
            ("add_vips", #"{"emails":["v@x.com","w@x.com"]}"#, ["v@x.com"]),
            ("set_vip_groups",
             #"{"email":"v@x.com","groups":["Team"]}"#, ["v@x.com", "Team"]),
            ("remove_vip", #"{"email":"v@x.com"}"#, ["v@x.com"]),
        ]
        for (name, json, needles) in cases {
            let summary = AskMishTools.confirmSummary(toolName: name, argumentsJSON: json)
            XCTAssertFalse(summary.isEmpty, name)
            for needle in needles {
                XCTAssertTrue(summary.contains(needle), "\(name) missing \(needle): \(summary)")
            }
        }
    }

    /// The resolved send line names the recipients and the subject — the
    /// confirm card is the last barrier before mail leaves.
    func testSendDraftSummaryNamesRecipientsAndSubject() {
        let line = AskMishTools.sendDraftSummary(
            recipients: ["a@b.com", "c@d.com"], subject: "Q3 numbers")
        XCTAssertTrue(line.contains("a@b.com"), line)
        XCTAssertTrue(line.contains("c@d.com"), line)
        XCTAssertTrue(line.contains("Q3 numbers"), line)
        XCTAssertFalse(line.contains("draft_id"), line)
    }

    func testSendDraftSummaryHandlesMissingParts() {
        let noSubject = AskMishTools.sendDraftSummary(
            recipients: ["a@b.com"], subject: "   ")
        XCTAssertEqual(noSubject, "Send the draft to a@b.com.")
        let noRecipient = AskMishTools.sendDraftSummary(recipients: [], subject: "Hi")
        XCTAssertTrue(noRecipient.hasPrefix("Send the draft"), noRecipient)
        XCTAssertTrue(noRecipient.contains("Hi"), noRecipient)
        XCTAssertFalse(
            AskMishTools.sendDraftSummary(recipients: [], subject: "").isEmpty)
    }

    /// Bcc recipients are counted on the card, never named.
    func testSendDraftSummaryCountsHiddenRecipients() {
        let none = AskMishTools.sendDraftSummary(
            recipients: ["a@b.com"], subject: "Hi", hiddenCount: 0)
        XCTAssertEqual(none, "Send the draft to a@b.com — “Hi”.")

        let one = AskMishTools.sendDraftSummary(
            recipients: ["a@b.com"], subject: "Hi", hiddenCount: 1)
        XCTAssertEqual(one, "Send the draft to a@b.com and 1 hidden recipient — “Hi”.")

        let two = AskMishTools.sendDraftSummary(
            recipients: ["a@b.com"], subject: "Hi", hiddenCount: 2)
        XCTAssertEqual(two, "Send the draft to a@b.com and 2 hidden recipients — “Hi”.")
    }

    /// A Bcc-only draft still names a destination count, not a bare "the draft".
    func testSendDraftSummaryBccOnlyDraft() {
        let line = AskMishTools.sendDraftSummary(
            recipients: [], subject: "Subj", hiddenCount: 1)
        XCTAssertEqual(line, "Send the draft to 1 hidden recipient — “Subj”.")
    }

    /// Long recipient lists and long subjects stay card-sized.
    func testSendDraftSummaryTrimsLongValues() {
        let many = (1...9).map { "user\($0)@example.com" }
        let line = AskMishTools.sendDraftSummary(
            recipients: many, subject: String(repeating: "x", count: 200))
        XCTAssertTrue(line.contains("6 more"), line)
        XCTAssertTrue(line.contains("…"), line)
        XCTAssertLessThan(line.count, 160, line)
    }

    /// Bad JSON must still produce a card line — never an empty confirm.
    func testConfirmSummaryToleratesBadArguments() {
        let summary = AskMishTools.confirmSummary(toolName: "add_vip", argumentsJSON: "not json")
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains("add_vip"))
    }

    /// The Ask Mish executor reuses the MCP dispatcher, so it must be callable.
    func testDispatchIsReachableFromAskMish() async throws {
        let tools = StubToolProvider()
        let text = try await MCPRouter.dispatch(
            name: "search_threads", args: ["query": .string("acme")], tools: tools)
        XCTAssertEqual(text, "searched:acme")
    }

    func testDispatchRejectsUnknownTool() async {
        do {
            _ = try await MCPRouter.dispatch(name: "nope", args: [:], tools: StubToolProvider())
            XCTFail("expected throw")
        } catch let error as MCPRouter.ToolDispatchError {
            guard case .unknownTool = error else {
                return XCTFail("expected unknownTool, got \(error)")
            }
        } catch {
            XCTFail("expected ToolDispatchError, got \(error)")
        }
    }
}

/// Minimal provider for the dispatch-visibility check.
private struct StubToolProvider: MCPToolProvider {
    func listAccounts() async throws -> String { "[]" }
    func listThreads(mailbox: String, unreadOnly: Bool?, limit: Int, offset: Int,
                     account: String?) async throws -> String { "[]" }
    func searchThreads(query: String, limit: Int, offset: Int) async throws -> String {
        "searched:\(query)"
    }
    func getThread(threadId: String) async throws -> String { "" }
    func listDrafts(account: String?) async throws -> String { "[]" }
    func createDraft(account: String, to: [String], cc: [String]?, bcc: [String]?,
                     subject: String, body: String,
                     replyToThreadId: String?) async throws -> String { "{}" }
    func setThreadSummary(threadId: String, summary: String,
                          model: String) async throws -> String { "{}" }
    func clearThreadSummary(threadId: String) async throws -> String { "{}" }
    func listVIPs() async throws -> String { "[]" }
    func addVIP(email: String, group: String?, groups: [String]?) async throws -> String { "{}" }
    func addVIPs(emails: [String], group: String?, groups: [String]?) async throws -> String { "{}" }
    func setVIPGroups(email: String, groups: [String]) async throws -> String { "{}" }
    func removeVIP(email: String) async throws -> String { "{}" }
}
