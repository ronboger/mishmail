import XCTest

/// Pins the sync-CPU optimizations (single-pass base64url, precompiled
/// stripHTML regexes, concurrent page parse) to the exact behavior of the
/// implementations they replaced. The `legacy*` functions below are verbatim
/// copies of the pre-optimization code.
final class SyncCPUEquivalenceTests: XCTestCase {

    // MARK: - Legacy reference implementations (verbatim)

    private static func legacyDecodeBase64URLData(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }

    private static func legacyStripHTML(_ html: String) -> String {
        var s = html
        for tag in ["style", "script", "head", "title"] {
            s = s.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>",
                with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?\\s*>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(
            of: "</(p|div|li|ul|ol|h[1-6]|tr|table|blockquote|pre|section|article|header|footer)\\s*>",
            with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = MessageParser.decodeEntities(s)
        var lines: [String] = []
        for raw in s.components(separatedBy: "\n") {
            let line = raw
                .replacingOccurrences(of: "[ \\t\\r\u{00A0}]+", with: " ",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty && (lines.last?.isEmpty ?? true) { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - base64url

    func testBase64URLMatchesLegacyAcrossPaddingLengths() {
        // Every payload length 0...40 covers encoded lengths ≡ 0, 2, 3 (mod 4),
        // with bytes chosen so both `-` and `_` appear in the encoding.
        for n in 0...40 {
            let bytes = Data((0..<n).map { UInt8(truncatingIfNeeded: 0xFB &+ $0 &* 37) })
            let encoded = bytes.base64URLEncoded()
            let new = MessageParser.decodeBase64URLData(encoded)
            XCTAssertEqual(new, Self.legacyDecodeBase64URLData(encoded), "n=\(n)")
            XCTAssertEqual(new, bytes, "n=\(n)")
        }
    }

    func testBase64URLDashAndUnderscoreMapping() {
        // 0xFB 0xFF 0xBF → "-_-_" in base64url ("+/+/" in standard).
        let encoded = Data([0xFB, 0xFF, 0xBF]).base64URLEncoded()
        XCTAssertEqual(encoded, "-_-_")
        XCTAssertEqual(MessageParser.decodeBase64URLData(encoded), Data([0xFB, 0xFF, 0xBF]))
    }

    func testBase64URLEdgeAndInvalidInputsMatchLegacy() {
        let inputs = [
            "", "a", "ab", "abc", "abcd", "abcde",       // length mod 4 = 0,1,2,3
            "YQ", "YQ=", "YQ==", "YWI", "YWI=",          // already-padded variants
            "Y Q", "YQ\n", "YQ\r\n", "!!not base64!!",   // bytes outside alphabet
            "=", "==", "===", "====", "a===",
            "-", "_", "--", "__", "-_-", "+/+/",
            "é", "YQé", "e\u{301}", "👍", "YWJj👍",      // non-ASCII (Character ≠ byte count)
        ]
        for input in inputs {
            XCTAssertEqual(MessageParser.decodeBase64URLData(input),
                           Self.legacyDecodeBase64URLData(input), "input=\(input.debugDescription)")
        }
    }

    // MARK: - stripHTML

    func testStripHTMLMatchesLegacyByteForByte() {
        let corpus = [
            "",
            "plain text, no tags",
            "<p>Hello <b>world</b></p><p>&amp; more&nbsp;&nbsp;spaces</p>",
            "<html><head><title>T</title><style>p{color:red}</style></head>"
                + "<body><div>One</div><div>Two &#8212; dash</div><br><br/>"
                + "<p>A &amp;lt; B &#x41;</p></body></html>",
            "<STYLE type=\"text/css\">\n.a { x }\n</STYLE >After<SCRIPT>alert(1)</script>",
            "<!-- hidden\ncomment -->Visible<!---->",
            "<ul><li>a</li><li>b</li></ul><ol><li>c</li></ol><h1>H</h1><h6>h6</h6>",
            "<table><tr><td>x</td><td>y</td></tr></table><blockquote>q</blockquote>",
            "<pre>  keep\t\ttabs  </pre><section>s</section><article>a</article>",
            "<header>h</header><footer>f</footer>",
            "line\r\nwith crlf\r\n\r\n\r\nand\u{00A0}\u{00A0}nbsp",
            "   \n\n\n  leading and trailing blank lines \n\n\n",
            "unterminated <b tag and < lone angle > here",
            "emoji 👍🏽 and e\u{301} combining <br>next",
            "&#128512; &#xZZ; &#; &bogus; &#39;&apos;&quot;&lt;&gt;",
            "<BR><Br /><bR/ >caps",
            "<div><div><div>nested</div></div></div>\n\n\n\n<p>gap</p>",
            String(repeating: "<p>para \t with   spaces</p>\n", count: 200),
        ]
        for html in corpus {
            XCTAssertEqual(MessageParser.stripHTML(html), Self.legacyStripHTML(html),
                           "html=\(html.prefix(60).debugDescription)")
        }
    }

    // MARK: - concurrent page parse

    private static func fixture(_ i: Int) throws -> GMessage {
        // Mix of plain-only, HTML-only (exercises stripHTML), multipart with an
        // attachment, and metadata-only (no payload body) messages.
        let html = Data("<html><style>x{}</style><p>Hi #\(i) &amp; co</p><br>bye</html>".utf8)
            .base64URLEncoded()
        let text = Data("Plain body \(i)".utf8).base64URLEncoded()
        let payload: String
        switch i % 4 {
        case 0:
            payload = #"{"mimeType":"text/plain","body":{"data":"\#(text)"}}"#
        case 1:
            payload = #"{"mimeType":"text/html","body":{"data":"\#(html)"}}"#
        case 2:
            payload = #"""
            {"mimeType":"multipart/mixed","parts":[
              {"mimeType":"text/html","body":{"data":"\#(html)"}},
              {"mimeType":"application/pdf","filename":"f\#(i).pdf",
               "body":{"attachmentId":"att\#(i)","size":1234}}]}
            """#
        default:
            payload = #"{"mimeType":"text/plain"}"#
        }
        let json = #"""
        {"id":"m\#(i)","threadId":"t\#(i / 3)","labelIds":["INBOX","UNREAD"],
         "snippet":"snip &amp; \#(i)","internalDate":"\#(1_700_000_000_000 + i)",
         "payload":{"mimeType":"multipart/alternative","headers":[
            {"name":"From","value":"A <a\#(i)@x.com>"},{"name":"Subject","value":"S\#(i)"}],
          "parts":[\#(payload)]}}
        """#
        return try JSONDecoder().decode(GMessage.self, from: Data(json.utf8))
    }

    func testParseConcurrentlyPreservesOrderAndMatchesSerial() async throws {
        // Sizes straddle the inline threshold and uneven chunk splits.
        for count in [0, 1, MessageParser.concurrentParseThreshold - 1,
                      MessageParser.concurrentParseThreshold, 7, 25, 101] {
            let messages = try (0..<count).map(Self.fixture)
            let serial = messages.map { MessageParser.parse($0, accountId: "acct") }
            let concurrent = await MessageParser.parseConcurrently(messages, accountId: "acct")
            XCTAssertEqual(concurrent.count, serial.count, "count=\(count)")
            for (a, b) in zip(concurrent, serial) {
                XCTAssertEqual(a.0, b.0)
                XCTAssertEqual(a.1, b.1)
            }
            XCTAssertEqual(concurrent.map(\.0.gmailId), messages.map(\.id))
        }
    }

    /// Informational timing only (no assertion, so never flaky): serial vs
    /// concurrent parse of a synthetic page. Look for the log line in test
    /// output when tuning `concurrentParseThreshold`.
    func testParseConcurrentlyTiming() async throws {
        let messages = try (0..<400).map(Self.fixture)
        let clock = ContinuousClock()
        let serial = clock.measure {
            _ = messages.map { MessageParser.parse($0, accountId: "acct") }
        }
        let start = clock.now
        _ = await MessageParser.parseConcurrently(messages, accountId: "acct")
        let concurrent = clock.now - start
        print("parse 400 msgs: serial=\(serial) concurrent=\(concurrent) "
              + "cores=\(ProcessInfo.processInfo.activeProcessorCount)")
    }
}
