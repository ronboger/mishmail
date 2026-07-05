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
        XCTAssertEqual(MessageParser.stripHTML(html), "Hello world & more spaces")
    }

    // MARK: - HTML entity decoding

    func testDecodesNumericEntities() {
        XCTAssertEqual("won&#39;t be able".decodingHTMLEntities(), "won't be able")
        XCTAssertEqual("caf&#233;".decodingHTMLEntities(), "café")
        XCTAssertEqual("it&#x2019;s".decodingHTMLEntities(), "it\u{2019}s")
        XCTAssertEqual("&#x1F600;".decodingHTMLEntities(), "😀")
    }

    func testDecodesNamedEntities() {
        XCTAssertEqual("Tom &amp; Jerry".decodingHTMLEntities(), "Tom & Jerry")
        XCTAssertEqual("&ldquo;hi&rdquo; &ndash; ok&hellip;".decodingHTMLEntities(),
                       "\u{201C}hi\u{201D} \u{2013} ok\u{2026}")
        XCTAssertEqual("a&nbsp;b".decodingHTMLEntities(), "a b")
        XCTAssertEqual("&lt;tag&gt; &quot;q&quot; &apos;a&apos;".decodingHTMLEntities(),
                       "<tag> \"q\" 'a'")
    }

    func testLeavesInvalidReferencesAlone() {
        XCTAssertEqual("AT&T and R&D".decodingHTMLEntities(), "AT&T and R&D")
        XCTAssertEqual("5 &".decodingHTMLEntities(), "5 &")
        XCTAssertEqual("&notarealentityname;".decodingHTMLEntities(), "&notarealentityname;")
        XCTAssertEqual("&#xZZ;".decodingHTMLEntities(), "&#xZZ;")
        XCTAssertEqual("&#1114112;".decodingHTMLEntities(), "&#1114112;")  // > U+10FFFF
        XCTAssertEqual("&#xD800;".decodingHTMLEntities(), "&#xD800;")      // surrogate
    }

    func testDecodesConsecutiveAndTrailingEntities() {
        XCTAssertEqual("&amp;&amp;&#33;".decodingHTMLEntities(), "&&!")
        XCTAssertEqual("end&hellip;".decodingHTMLEntities(), "end\u{2026}")
        XCTAssertEqual("plain text".decodingHTMLEntities(), "plain text")
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
