import XCTest

final class ForwardComposerTests: XCTestCase {

    private let date = Date(timeIntervalSince1970: 1_760_000_000)
    private let older = Date(timeIntervalSince1970: 1_759_900_000)

    private func block(cc: String = "", bodyText: String = "Hello\nWorld") -> String {
        ForwardComposer.forwardBlock(
            fromHeader: "Jane Doe <jane@x.com>", date: date,
            subject: "Quarterly report", toHeader: "ron@x.com",
            ccHeader: cc, bodyText: bodyText)
    }

    private func part(from: String = "Jane Doe <jane@x.com>",
                      date: Date? = nil, subject: String = "Quarterly report",
                      to: String = "ron@x.com", cc: String = "",
                      body: String = "Hello\nWorld",
                      html: String? = nil) -> ForwardComposer.Part {
        ForwardComposer.Part(
            fromHeader: from, date: date ?? self.date, subject: subject,
            toHeader: to, ccHeader: cc, bodyText: body, bodyHTML: html)
    }

    func testForwardBlockContainsHeadersAndBody() {
        let b = block()
        XCTAssertTrue(b.contains(ForwardComposer.marker))
        XCTAssertTrue(b.contains("From: Jane Doe <jane@x.com>"))
        XCTAssertTrue(b.contains("Subject: Quarterly report"))
        XCTAssertTrue(b.contains("To: ron@x.com"))
        XCTAssertTrue(b.contains("Date: "))
        XCTAssertFalse(b.contains("Cc: "))
        XCTAssertTrue(b.hasSuffix("Hello\nWorld"))
    }

    func testForwardBlockIncludesCcWhenPresent() {
        XCTAssertTrue(block(cc: "bob@x.com").contains("Cc: bob@x.com"))
    }

    func testForwardBlockIsDeterministic() {
        // Send-time HTML upgrading depends on recomputing the identical block.
        XCTAssertEqual(block(), block())
    }

    func testUserTextExtractedWhenQuotedTailUntouched() {
        let b = block()
        let body = "Please see below.\n\n" + b
        XCTAssertEqual(ForwardComposer.userText(inBody: body, expectedBlock: b),
                       "Please see below.")
    }

    func testUserTextEmptyWhenNothingTyped() {
        let b = block()
        XCTAssertEqual(ForwardComposer.userText(inBody: "\n\n" + b, expectedBlock: b), "")
    }

    func testUserTextNilWhenQuotedTailEdited() {
        let b = block()
        let edited = ("note above\n\n" + b).replacingOccurrences(of: "World", with: "Wörld")
        XCTAssertNil(ForwardComposer.userText(inBody: edited, expectedBlock: b))
    }

    func testUserTextNilWhenBlockDeleted() {
        XCTAssertNil(ForwardComposer.userText(inBody: "just my own text",
                                              expectedBlock: block()))
    }

    func testHTMLBodyEscapesUserTextAndKeepsOriginalHTML() {
        let html = ForwardComposer.htmlBody(
            userText: "See <b>below</b> & enjoy\nsecond line",
            fromHeader: "Jane <jane@x.com>", date: date,
            subject: "A & B", toHeader: "ron@x.com", ccHeader: "",
            originalHTML: "<div style=\"color:red\">Rich <b>content</b></div>")
        // User text is escaped, not interpreted.
        XCTAssertTrue(html.contains("See &lt;b&gt;below&lt;/b&gt; &amp; enjoy<br>second line"))
        // Original markup survives verbatim.
        XCTAssertTrue(html.contains("<div style=\"color:red\">Rich <b>content</b></div>"))
        // Header block present and escaped.
        XCTAssertTrue(html.contains(ForwardComposer.marker))
        XCTAssertTrue(html.contains("Jane &lt;jane@x.com&gt;"))
        XCTAssertTrue(html.contains("A &amp; B"))
    }

    // MARK: - Forward all

    func testForwardAllJoinsMultipleBlocksOldestFirst() {
        let first = part(from: "Alice <a@x.com>", date: older, body: "First turn")
        let second = part(from: "Bob <b@x.com>", date: date, body: "Second turn")
        let package = ForwardComposer.forwardBlock(parts: [first, second])

        XCTAssertEqual(package.components(separatedBy: ForwardComposer.marker).count - 1, 2)
        // Chronological: first turn appears before second in the package.
        let firstIdx = package.range(of: "First turn")!.lowerBound
        let secondIdx = package.range(of: "Second turn")!.lowerBound
        XCTAssertLessThan(firstIdx, secondIdx)
        XCTAssertTrue(package.contains("From: Alice <a@x.com>"))
        XCTAssertTrue(package.contains("From: Bob <b@x.com>"))
    }

    func testForwardAllUserTextMatchWhenUntouched() {
        let parts = [
            part(from: "Alice <a@x.com>", date: older, body: "One"),
            part(from: "Bob <b@x.com>", date: date, body: "Two"),
        ]
        let package = ForwardComposer.forwardBlock(parts: parts)
        let body = "relevant to chat?\n\n" + package
        XCTAssertEqual(ForwardComposer.userText(inBody: body, expectedBlock: package),
                       "relevant to chat?")
    }

    func testForwardAllHTMLIncludesEachPartAndEscapesUserText() {
        let parts = [
            part(from: "Alice <a@x.com>", date: older, body: "One",
                 html: "<p>One <b>HTML</b></p>"),
            part(from: "Bob <b@x.com>", date: date, body: "Two",
                 html: "<p>Two</p>"),
        ]
        let html = ForwardComposer.htmlBody(userText: "See <x>", parts: parts)
        XCTAssertTrue(html.contains("See &lt;x&gt;"))
        XCTAssertTrue(html.contains("<p>One <b>HTML</b></p>"))
        XCTAssertTrue(html.contains("<p>Two</p>"))
        XCTAssertTrue(html.contains("Alice &lt;a@x.com&gt;"))
        XCTAssertTrue(html.contains("Bob &lt;b@x.com&gt;"))
        // Two gmail_quote wrappers.
        XCTAssertEqual(html.components(separatedBy: "gmail_quote").count - 1, 2)
    }

    func testForwardAllHTMLFallsBackToEscapedTextWhenNoHTML() {
        let parts = [part(body: "Plain only <tag>")]
        let html = ForwardComposer.htmlBody(userText: "", parts: parts)
        XCTAssertTrue(html.contains("Plain only &lt;tag&gt;"))
        XCTAssertFalse(html.contains("Plain only <tag>"))
    }

    func testPartFromMessagePrefersHTMLDerivedPlainText() {
        let msg = Message(
            id: "ron@x.com:m1", accountId: "ron@x.com", gmailId: "m1",
            threadId: "ron@x.com:t1", fromHeader: "Jane <jane@x.com>",
            toHeader: "ron@x.com", ccHeader: "", subject: "Hi",
            date: date, snippet: "", bodyText: "stale plain",
            bodyHTML: "<p>Fresh <b>HTML</b></p>",
            messageIdHeader: "", referencesHeader: "", labelIds: "INBOX",
            isUnread: false, hasAttachment: false)
        let p = ForwardComposer.Part(message: msg)
        // stripHTML leaves "Fresh HTML" (tags gone); not the stale bodyText.
        XCTAssertFalse(p.bodyText.contains("stale plain"))
        XCTAssertTrue(p.bodyText.contains("Fresh"))
        XCTAssertEqual(p.bodyHTML, "<p>Fresh <b>HTML</b></p>")
    }

    func testSingleBlockAPIMatchesPartsAPI() {
        let viaArgs = ForwardComposer.forwardBlock(
            fromHeader: "Jane <j@x.com>", date: date, subject: "S",
            toHeader: "r@x.com", ccHeader: "", bodyText: "Body")
        let viaParts = ForwardComposer.forwardBlock(parts: [
            part(from: "Jane <j@x.com>", subject: "S", to: "r@x.com", body: "Body")
        ])
        XCTAssertEqual(viaArgs, viaParts)
    }

    // MARK: - matchHTMLUpgrade (send-path disambiguation)

    private func message(id: String, from: String, body: String, html: String?,
                         date: Date, labels: String = "INBOX") -> Message {
        Message(
            id: "ron@x.com:\(id)", accountId: "ron@x.com", gmailId: id,
            threadId: "ron@x.com:t1", fromHeader: from,
            toHeader: "ron@x.com", ccHeader: "", subject: "Subj",
            date: date, snippet: "", bodyText: body, bodyHTML: html,
            messageIdHeader: "", referencesHeader: "", labelIds: labels,
            isUnread: false, hasAttachment: false)
    }

    func testMatchHTMLUpgradePrefersForwardAllOverSingleSuffix() {
        // The bug: an all-package always ends with the newest block, so
        // hasSuffix(single) would steal the match and HTML-escape older turns.
        let olderMsg = message(id: "m1", from: "Alice <a@x.com>",
                               body: "First turn", html: "<p>First</p>", date: older)
        let newerMsg = message(id: "m2", from: "Bob <b@x.com>",
                               body: "Second turn", html: "<p>Second</p>", date: date)
        let thread = [olderMsg, newerMsg]
        let parts = thread.map { ForwardComposer.Part(message: $0) }
        let package = ForwardComposer.forwardBlock(parts: parts)
        let body = "relevant to chat?\n\n" + package

        let match = ForwardComposer.matchHTMLUpgrade(
            body: body, original: newerMsg, threadMessages: thread)
        let unwrapped = try! XCTUnwrap(match)
        XCTAssertEqual(unwrapped.userText, "relevant to chat?")
        XCTAssertEqual(unwrapped.parts.count, 2)

        let html = ForwardComposer.htmlBody(userText: unwrapped.userText, parts: unwrapped.parts)
        XCTAssertEqual(html.components(separatedBy: "gmail_quote").count - 1, 2,
                       "Forward-all must produce one gmail_quote per message")
        XCTAssertTrue(html.contains("<p>First</p>"))
        XCTAssertTrue(html.contains("<p>Second</p>"))
        // Older plain markers must NOT appear as escaped "user text".
        XCTAssertFalse(html.contains("First turn<br>----------"))
    }

    func testMatchHTMLUpgradeStillMatchesSingleForward() {
        let olderMsg = message(id: "m1", from: "Alice <a@x.com>",
                               body: "First", html: "<p>First</p>", date: older)
        let newerMsg = message(id: "m2", from: "Bob <b@x.com>",
                               body: "Second", html: "<p>Second</p>", date: date)
        let single = ForwardComposer.forwardBlock(parts: [ForwardComposer.Part(message: newerMsg)])
        let body = "note\n\n" + single

        let match = ForwardComposer.matchHTMLUpgrade(
            body: body, original: newerMsg, threadMessages: [olderMsg, newerMsg])
        let unwrapped = try! XCTUnwrap(match)
        XCTAssertEqual(unwrapped.userText, "note")
        XCTAssertEqual(unwrapped.parts.count, 1)
        let html = ForwardComposer.htmlBody(userText: unwrapped.userText, parts: unwrapped.parts)
        XCTAssertEqual(html.components(separatedBy: "gmail_quote").count - 1, 1)
        XCTAssertTrue(html.contains("<p>Second</p>"))
        XCTAssertFalse(html.contains("<p>First</p>"))
    }

    func testForwardableMessagesExcludesDrafts() {
        let a = message(id: "m1", from: "a@x.com", body: "A", html: nil,
                        date: older, labels: "INBOX")
        let draft = message(id: "m2", from: "me@x.com", body: "secret draft",
                            html: nil, date: date, labels: "DRAFT")
        let b = message(id: "m3", from: "b@x.com", body: "B", html: nil,
                        date: date, labels: "INBOX SENT")
        let filtered = ForwardComposer.forwardableMessages([a, draft, b])
        XCTAssertEqual(filtered.map(\.gmailId), ["m1", "m3"])
        XCTAssertFalse(filtered.contains { $0.bodyText.contains("secret") })
    }

    func testMatchHTMLUpgradeExcludesDraftsFromForwardAllPackage() {
        let a = message(id: "m1", from: "Alice <a@x.com>", body: "One",
                        html: "<p>One</p>", date: older)
        let draft = message(id: "m2", from: "Ron <ron@x.com>", body: "unsent secret",
                            html: "<p>secret</p>", date: date, labels: "DRAFT")
        let b = message(id: "m3", from: "Bob <b@x.com>", body: "Two",
                        html: "<p>Two</p>", date: date)
        // Compose builds the package without the draft.
        let forwardable = ForwardComposer.forwardableMessages([a, draft, b])
        let package = ForwardComposer.forwardBlock(
            parts: forwardable.map { ForwardComposer.Part(message: $0) })
        let body = "intro\n\n" + package

        let match = ForwardComposer.matchHTMLUpgrade(
            body: body, original: b, threadMessages: [a, draft, b])
        let unwrapped = try! XCTUnwrap(match)
        XCTAssertEqual(unwrapped.parts.count, 2)
        let html = ForwardComposer.htmlBody(userText: unwrapped.userText, parts: unwrapped.parts)
        XCTAssertFalse(html.contains("secret"))
        XCTAssertEqual(html.components(separatedBy: "gmail_quote").count - 1, 2)
    }
}
