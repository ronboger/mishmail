import XCTest

final class MessageParsingTests: XCTestCase {

    // MARK: - base64url

    func testBase64URLRoundTrip() throws {
        let original = "héllo, wörld — ünicode & emoji-free ✓"
        let encoded = Data(original.utf8).base64URLEncoded()
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(MessageParser.decodeBase64URL(encoded), original)
    }

    func testDecodeBase64URLPadding() {
        // Lengths that need 0, 1 and 2 padding chars.
        for s in ["a", "ab", "abc", "abcd", "abcde"] {
            let encoded = Data(s.utf8).base64URLEncoded()
            XCTAssertEqual(MessageParser.decodeBase64URL(encoded), s)
        }
    }

    func testDecodeBase64URLGarbage() {
        XCTAssertNil(MessageParser.decodeBase64URLData("!!not base64!!"))
    }

    // MARK: - Header helpers

    func testDisplayName() {
        XCTAssertEqual(MessageParser.displayName(fromHeader: "Jane Doe <jane@x.com>"), "Jane Doe")
        XCTAssertEqual(MessageParser.displayName(fromHeader: "\"Doe, Jane\" <jane@x.com>"), "Doe, Jane")
        XCTAssertEqual(MessageParser.displayName(fromHeader: "jane@x.com"), "jane@x.com")
        XCTAssertEqual(MessageParser.displayName(fromHeader: "<jane@x.com>"), "jane@x.com")
    }

    func testEmailAddress() {
        XCTAssertEqual(MessageParser.emailAddress("Jane Doe <jane@x.com>"), "jane@x.com")
        XCTAssertEqual(MessageParser.emailAddress("jane@x.com"), "jane@x.com")
        XCTAssertEqual(MessageParser.emailAddress("<jane@x.com>"), "jane@x.com")
    }

    /// Regression: malformed headers with out-of-order or unmatched angle
    /// brackets used to crash (String index out of bounds).
    func testEmailAddressMalformedHeaders() {
        XCTAssertEqual(MessageParser.emailAddress(">jane@x.com<"), "jane@x.com")
        XCTAssertEqual(MessageParser.emailAddress("jane@x.com>"), "jane@x.com")
        XCTAssertEqual(MessageParser.emailAddress("<"), "")
        XCTAssertEqual(MessageParser.emailAddress(""), "")
    }

    func testSplitAddressesRespectsQuotedCommas() {
        let header = "\"Boger, Ron\" <ron@x.com>, Jane Doe <jane@y.com>, bare@z.com"
        let parts = MessageParser.splitAddresses(header)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(MessageParser.emailAddress(parts[0]), "ron@x.com")
        XCTAssertEqual(MessageParser.emailAddress(parts[1]), "jane@y.com")
        XCTAssertEqual(MessageParser.emailAddress(parts[2].trimmingCharacters(in: .whitespaces)), "bare@z.com")
    }

    func testSplitAddressesEmpty() {
        XCTAssertTrue(MessageParser.splitAddresses("").isEmpty)
        XCTAssertTrue(MessageParser.splitAddresses("  ").isEmpty)
    }

    func testStripHTML() {
        let html = "<div><p>Hello&nbsp;<b>world</b></p>&amp; more   spaces</div>"
        XCTAssertEqual(MessageParser.stripHTML(html), "Hello world\n& more spaces")
    }

    func testStripHTMLDropsStyleAndScriptContents() {
        // Notion Mail regression: its HTML carries a large <style> block whose
        // CSS used to leak into the extracted text (and quoted replies).
        let html = """
        <html><head><title>ignore</title>
        <style type="text/css">code { font-family: SFMono-Regular, Menlo; } \
        p { border-radius: 0px; margin: 0px; }</style></head>
        <body><script>alert("no")</script><!-- comment -->
        <p>Sounds good, see you Friday.</p><p>Best,<br/>Ron</p></body></html>
        """
        let text = MessageParser.stripHTML(html)
        XCTAssertEqual(text, "Sounds good, see you Friday.\nBest,\nRon")
        XCTAssertFalse(text.contains("font-family"))
        XCTAssertFalse(text.contains("ignore"))
        XCTAssertFalse(text.contains("alert"))
    }

    func testStripHTMLStructureAndEntities() {
        let html = "<ul><li>One</li><li>Two &#8212; dash</li></ul><p>A &amp;lt; B &#x41;</p>"
        // List end + new paragraph is a paragraph break (one blank line).
        XCTAssertEqual(MessageParser.stripHTML(html), "One\nTwo \u{2014} dash\n\nA &lt; B A")
    }

    func testStripHTMLCollapsesBlankRuns() {
        let html = "<p>First</p><br><br><br><div></div><p>Second</p>"
        XCTAssertEqual(MessageParser.stripHTML(html), "First\n\nSecond")
    }

    func testReplyQuotableTextPrefersHTML() {
        // Legacy rows derived bodyText from HTML with the old stripper,
        // so CSS junk may be stored; quoting must re-derive from the HTML.
        let junk = "code { font-family: Menlo; } p { margin: 0px; } Hi there"
        let html = "<style>code { font-family: Menlo; }</style><p>Hi there</p>"
        XCTAssertEqual(MessageParser.replyQuotableText(text: junk, html: html), "Hi there")
        // No HTML part: the plain text is authoritative.
        XCTAssertEqual(MessageParser.replyQuotableText(text: "plain", html: nil), "plain")
        // Empty/image-only HTML falls back to the plain part.
        XCTAssertEqual(MessageParser.replyQuotableText(text: "plain", html: "<img src='x'>"), "plain")
    }

    // MARK: - Full message parsing (from real API-shaped JSON)

    private func decodeGMessage(_ json: String) throws -> GMessage {
        try JSONDecoder().decode(GMessage.self, from: Data(json.utf8))
    }

    private func b64url(_ s: String) -> String { Data(s.utf8).base64URLEncoded() }

    func testParseMultipartMessageWithAttachment() throws {
        let json = """
        {
          "id": "m1", "threadId": "t1",
          "labelIds": ["INBOX", "UNREAD", "IMPORTANT"],
          "snippet": "Hi there",
          "internalDate": "1751500000000",
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [
              {"name": "From", "value": "Jane Doe <jane@x.com>"},
              {"name": "To", "value": "ron@x.com"},
              {"name": "Cc", "value": "cc@x.com"},
              {"name": "Bcc", "value": "hidden@x.com"},
              {"name": "subject", "value": "Quarterly numbers"},
              {"name": "Message-ID", "value": "<abc@mail.gmail.com>"},
              {"name": "References", "value": "<earlier@mail.gmail.com>"}
            ],
            "parts": [
              {"mimeType": "text/plain", "body": {"data": "\(b64url("plain body"))"}},
              {"mimeType": "text/html", "body": {"data": "\(b64url("<p>html body</p>"))"}},
              {"mimeType": "application/pdf", "filename": "report.pdf",
               "body": {"attachmentId": "att-1", "size": 12345}}
            ]
          }
        }
        """
        let (message, attachments) = MessageParser.parse(try decodeGMessage(json), accountId: "ron@x.com")

        XCTAssertEqual(message.id, "ron@x.com:m1")
        XCTAssertEqual(message.threadId, "ron@x.com:t1")
        XCTAssertEqual(message.gmailId, "m1")
        XCTAssertEqual(message.fromHeader, "Jane Doe <jane@x.com>")
        XCTAssertEqual(message.toHeader, "ron@x.com")
        XCTAssertEqual(message.ccHeader, "cc@x.com")
        XCTAssertEqual(message.bccHeader, "hidden@x.com")
        XCTAssertEqual(message.subject, "Quarterly numbers", "headers must match case-insensitively")
        XCTAssertEqual(message.bodyText, "plain body")
        XCTAssertEqual(message.bodyHTML, "<p>html body</p>")
        XCTAssertEqual(message.messageIdHeader, "<abc@mail.gmail.com>")
        XCTAssertEqual(message.referencesHeader, "<earlier@mail.gmail.com>")
        XCTAssertTrue(message.isUnread)
        XCTAssertTrue(message.hasAttachment)
        XCTAssertEqual(message.labelIds, "INBOX UNREAD IMPORTANT")
        XCTAssertEqual(message.date.timeIntervalSince1970, 1_751_500_000, accuracy: 0.001)

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].gmailAttachmentId, "att-1")
        XCTAssertEqual(attachments[0].filename, "report.pdf")
        XCTAssertEqual(attachments[0].mimeType, "application/pdf")
        XCTAssertEqual(attachments[0].size, 12345)
        XCTAssertEqual(attachments[0].messageId, message.id)
    }

    func testParseHTMLOnlyMessageFallsBackToStrippedText() throws {
        let json = """
        {
          "id": "m2", "threadId": "t2",
          "labelIds": [],
          "internalDate": "1751500000000",
          "payload": {
            "mimeType": "text/html",
            "headers": [{"name": "From", "value": "a@b.com"}],
            "body": {"data": "\(b64url("<p>Only <b>html</b> here</p>"))"}
          }
        }
        """
        let (message, _) = MessageParser.parse(try decodeGMessage(json), accountId: "ron@x.com")
        XCTAssertEqual(message.bodyText, "Only html here")
        XCTAssertEqual(message.bodyHTML, "<p>Only <b>html</b> here</p>")
        XCTAssertFalse(message.isUnread)
        XCTAssertFalse(message.hasAttachment)
    }

    func testParseNestedMultipartFindsBodyInChildren() throws {
        let json = """
        {
          "id": "m3", "threadId": "t3",
          "internalDate": "0",
          "payload": {
            "mimeType": "multipart/mixed",
            "parts": [
              {"mimeType": "multipart/alternative", "parts": [
                {"mimeType": "text/plain", "body": {"data": "\(b64url("nested plain"))"}}
              ]}
            ]
          }
        }
        """
        let (message, _) = MessageParser.parse(try decodeGMessage(json), accountId: "a@b.com")
        XCTAssertEqual(message.bodyText, "nested plain")
    }

    func testParseMissingHeadersProducesEmptyStrings() throws {
        let json = """
        {"id": "m4", "threadId": "t4", "payload": {"mimeType": "text/plain"}}
        """
        let (message, _) = MessageParser.parse(try decodeGMessage(json), accountId: "a@b.com")
        XCTAssertEqual(message.fromHeader, "")
        XCTAssertEqual(message.subject, "")
        XCTAssertEqual(message.bodyText, "")
    }
}
