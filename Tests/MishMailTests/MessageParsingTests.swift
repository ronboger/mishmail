import XCTest

final class MessageParsingTests: XCTestCase {

    func testRiskyAttachmentExtensionsIncludeLaunchersAndMacroFiles() {
        let risky = [
            "terminal", "fileloc", "webloc", "inetloc", "mobileconfig", "shortcut",
            "scpt", "applescript", "scptd", "workflow", "action", "iso", "img", "dmg",
            "html", "htm", "svg", "docm", "xlsm", "pptm", "prefpane", "saver", "kext",
            "jar", "command", "tool", "sh", "zsh", "py",
        ]
        for ext in risky {
            XCTAssertTrue(
                MessageParser.isRiskyAttachmentFilename("report.\(ext)"),
                "expected .\(ext) to prompt")
        }
        XCTAssertTrue(MessageParser.isRiskyAttachmentFilename("invoice.pdf.app"))
        XCTAssertFalse(MessageParser.isRiskyAttachmentFilename("photo.jpg"))
    }

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

    func testDecodeDeclaredLegacyCharsets() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xe9]).base64URLEncoded()
        XCTAssertEqual(
            MessageParser.decodeBase64URL(latin1, contentType: "text/plain; charset=iso-8859-1"),
            "café")

        let windows = Data([0x80]).base64URLEncoded()
        XCTAssertEqual(
            MessageParser.decodeBase64URL(windows, contentType: "text/plain; charset=windows-1252"),
            "€")

        let shiftJIS = Data([0x82, 0xa0]).base64URLEncoded()
        XCTAssertEqual(
            MessageParser.decodeBase64URL(shiftJIS, contentType: "text/plain; charset=shift_jis"),
            "あ")
    }

    /// ISO-2022-JP is 7-bit, so its bytes are also valid UTF-8. The declared
    /// charset must win, or the body shows raw escape sequences.
    func testDecodeDeclaredISO2022JPBeforeUTF8() {
        // ESC $ B 0x24 0x22 ESC ( B  ==  "あ"
        let bytes = Data([0x1b, 0x24, 0x42, 0x24, 0x22, 0x1b, 0x28, 0x42]).base64URLEncoded()
        XCTAssertEqual(
            MessageParser.decodeBase64URL(bytes, contentType: "text/plain; charset=\"ISO-2022-JP\""),
            "あ")
        // Declared UTF-8 / US-ASCII and undeclared bodies still decode as UTF-8.
        let utf8 = Data("café".utf8).base64URLEncoded()
        XCTAssertEqual(MessageParser.decodeBase64URL(utf8, contentType: "text/plain; charset=utf-8"), "café")
        XCTAssertEqual(MessageParser.decodeBase64URL(utf8, contentType: "text/plain; charset=us-ascii"), "café")
        XCTAssertEqual(MessageParser.decodeBase64URL(utf8, contentType: nil), "café")
        // An unknown charset name falls back to UTF-8, then Windows-1252.
        XCTAssertEqual(MessageParser.decodeBase64URL(utf8, contentType: "text/plain; charset=x-bogus"), "café")
        let cp1252 = Data([0x80]).base64URLEncoded()
        XCTAssertEqual(MessageParser.decodeBase64URL(cp1252, contentType: "text/plain; charset=x-bogus"), "€")
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

    /// A quoted display name (or a comment) can carry a decoy `<address>`.
    /// The mailbox is the angle-addr that ends the header, outside quotes
    /// and comments (RFC 5322 name-addr); block, VIP, reply and the
    /// remote-image gate all key on it.
    func testEmailAddressIgnoresDecoyInQuotedDisplayName() {
        let spoof = "\"Boss <boss@trusted.com>\" <attacker@evil.example>"
        XCTAssertEqual(MessageParser.emailAddress(spoof), "attacker@evil.example")
        XCTAssertEqual(MessageParser.displayName(fromHeader: spoof), "Boss <boss@trusted.com>")
        // Unquoted decoy: the last angle pair is the mailbox.
        let unquoted = "Boss <boss@trusted.com> <attacker@evil.example>"
        XCTAssertEqual(MessageParser.emailAddress(unquoted), "attacker@evil.example")
        XCTAssertEqual(MessageParser.displayName(fromHeader: unquoted), "Boss <boss@trusted.com>")
        // Escaped quote inside the quoted name does not end the quoted run.
        XCTAssertEqual(
            MessageParser.emailAddress(#""Boss \" <boss@trusted.com>" <attacker@evil.example>"#),
            "attacker@evil.example")
        // Decoy in a trailing comment must not win over the real mailbox.
        let comment = "Boss <attacker@evil.example> (<boss@trusted.com>)"
        XCTAssertEqual(MessageParser.emailAddress(comment), "attacker@evil.example")
        XCTAssertEqual(MessageParser.displayName(fromHeader: comment), "Boss")
        XCTAssertEqual(
            MessageParser.emailAddress(#"Boss <attacker@evil.example> (a \) (nested <boss@trusted.com>))"#),
            "attacker@evil.example")
        // Quoted local part that contains brackets.
        XCTAssertEqual(MessageParser.emailAddress(#"Odd <"a<b>c"@x.com>"#), #""a<b>c"@x.com"#)
        // Unbalanced quote: no unquoted pair exists, so use the last pair.
        XCTAssertEqual(
            MessageParser.emailAddress("\"Boss <boss@trusted.com> <attacker@evil.example>"),
            "attacker@evil.example")
        // A stray quote must not make the real mailbox "quoted" and leave
        // the comment decoy as the only pair.
        XCTAssertEqual(
            MessageParser.emailAddress("Boss\" <attacker@evil.example> (<boss@trusted.com>)"),
            "attacker@evil.example")
        // Unbalanced comment in a display name still finds the mailbox.
        XCTAssertEqual(MessageParser.emailAddress("Jane :-( <jane@x.com>"), "jane@x.com")
        XCTAssertEqual(MessageParser.emailAddress("Jane Doe (Acme) <jane@x.com>"), "jane@x.com")
        // Apostrophes are not quotes.
        XCTAssertEqual(MessageParser.emailAddress("O'Brien <ob@x.com>"), "ob@x.com")
        XCTAssertEqual(MessageParser.displayName(fromHeader: "O'Brien <ob@x.com>"), "O'Brien")
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

    /// HTML-only mail: `bodyText` (reply quote, plain alternative, export,
    /// MCP and AI context) must carry real characters, not entity names, and
    /// never C1 control characters.
    func testStripHTMLDecodesNamedEntitiesAndWindows1252Numerics() {
        let html = "<p>Don&rsquo;t miss it &mdash; caf&eacute; &#146;</p>"
        XCTAssertEqual(MessageParser.stripHTML(html),
                       "Don\u{2019}t miss it \u{2014} caf\u{00E9} \u{2019}")
        XCTAssertEqual(
            MessageParser.stripHTML("<p>&Uuml;ber &ntilde; &szlig; &Aring;&aring; &frac12; &iquest;&hearts;</p>"),
            "\u{00DC}ber \u{00F1} \u{00DF} \u{00C5}\u{00E5} \u{00BD} \u{00BF}\u{2665}")
        // Single pass: an escaped entity stays escaped once.
        XCTAssertEqual(MessageParser.stripHTML("<p>&amp;eacute; &amp;#146;</p>"), "&eacute; &#146;")
        // Unknown names stay literal.
        XCTAssertEqual(MessageParser.stripHTML("<p>AT&T &bogus; R&D</p>"), "AT&T &bogus; R&D")
    }

    func testNumericC1ReferencesMapThroughWindows1252() {
        XCTAssertEqual("&#128;&#x80;".decodingHTMLEntities(), "\u{20AC}\u{20AC}")
        XCTAssertEqual("&#145;a&#146; &#147;b&#148;".decodingHTMLEntities(),
                       "\u{2018}a\u{2019} \u{201C}b\u{201D}")
        XCTAssertEqual("&#150;&#151;&#133;&#153;&#x99;".decodingHTMLEntities(),
                       "\u{2013}\u{2014}\u{2026}\u{2122}\u{2122}")
        // No reference in 0x80...0x9F may yield a C1 control character,
        // including the five code points Windows-1252 leaves undefined.
        for value in 0x80...0x9F {
            for form in ["&#\(value);", "&#x\(String(value, radix: 16));"] {
                let decoded = form.decodingHTMLEntities()
                XCTAssertFalse(
                    decoded.unicodeScalars.contains { (0x80...0x9F).contains($0.value) },
                    "\(form) decoded to a control character")
                XCTAssertFalse(decoded.contains("&"), "\(form) was not decoded")
            }
        }
        XCTAssertEqual("a&#0;b".decodingHTMLEntities(), "a\u{FFFD}b")
        XCTAssertEqual("&#x0001F600;&#0000039;".decodingHTMLEntities(), "😀'")
        // Latin-1 above the C1 block is unchanged.
        XCTAssertEqual("&#160;&#233;".decodingHTMLEntities(), "\u{00A0}\u{00E9}")
    }

    /// The HTML 4 set is 252 names; spot-check each block and the case pairs.
    func testDecodesHTML4NamedEntitySet() {
        XCTAssertEqual("&Agrave;&agrave;&Eacute;&eacute;&Ccedil;&ccedil;&Oslash;&oslash;&yuml;&Yuml;"
            .decodingHTMLEntities(), "ÀàÉéÇçØøÿŸ")
        XCTAssertEqual("&OElig;&oelig;&Scaron;&scaron;&AElig;&aelig;&ETH;&eth;&THORN;&thorn;"
            .decodingHTMLEntities(), "ŒœŠšÆæÐðÞþ")
        XCTAssertEqual("&Alpha;&alpha;&Omega;&omega;&thetasym;&piv;".decodingHTMLEntities(), "ΑαΩωϑϖ")
        XCTAssertEqual("&iexcl;&curren;&brvbar;&uml;&ordf;&not;&macr;&sup2;&acute;&micro;&cedil;&frac34;"
            .decodingHTMLEntities(), "¡¤¦¨ª¬¯²´µ¸¾")
        XCTAssertEqual("&sbquo;&bdquo;&lsaquo;&rsaquo;&circ;&tilde;&oline;&spades;&clubs;&diams;"
            .decodingHTMLEntities(), "‚„‹›ˆ˜‾♠♣♦")
        XCTAssertEqual("&forall;&part;&exist;&nabla;&isin;&radic;&cap;&cup;&int;&there4;&equiv;&sube;"
            .decodingHTMLEntities(), "∀∂∃∇∈√∩∪∫∴≡⊆")
        XCTAssertEqual("&lArr;&rArr;&hArr;&crarr;&lceil;&rfloor;&lang;&rang;&loz;"
            .decodingHTMLEntities(), "⇐⇒⇔↵⌈⌋〈〉◊")
        // Spaces stay plain spaces; invisible joiners are dropped (previews
        // and plain text gain nothing from them).
        XCTAssertEqual("a&nbsp;b&ensp;c&emsp;d&thinsp;e&shy;f&zwnj;g&zwj;h".decodingHTMLEntities(),
                       "a b c d efgh")
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

    // MARK: - Authentication-Results verdict (VIP remote-image gate)

    private func authMessage(_ headers: [(String, String)]) throws -> GMessage {
        let headerJSON = headers
            .map { #"{"name": "\#($0.0)", "value": "\#($0.1)"}"# }
            .joined(separator: ", ")
        return try decodeGMessage("""
        {"id": "m1", "threadId": "t1", "payload": {"mimeType": "text/plain",
         "headers": [\(headerJSON)], "body": {"data": ""}}}
        """)
    }

    func testSenderAuthenticatedVerdicts() throws {
        // An aligned DMARC pass authenticates the visible sender.
        let pass = try authMessage([("Authentication-Results",
            "mx.google.com; spf=pass smtp.mailfrom=x.com; dkim=pass; dmarc=pass")])
        XCTAssertEqual(MessageParser.senderAuthenticated(pass), true)
        XCTAssertEqual(MessageParser.parse(pass, accountId: "a@x.com").0.senderAuth, true)

        // SPF/DKIM passing for an attacker-controlled domain does NOT
        // authenticate the visible From: — only DMARC alignment does.
        let unaligned = try authMessage([("Authentication-Results",
            "mx.google.com; spf=pass smtp.mailfrom=evil.example; dkim=pass header.i=@evil.example; dmarc=fail")])
        XCTAssertEqual(MessageParser.senderAuthenticated(unaligned), false)
        XCTAssertEqual(MessageParser.parse(unaligned, accountId: "a@x.com").0.senderAuth, false)

        // Everything failing → explicit failure.
        let fail = try authMessage([("Authentication-Results",
            "mx.google.com; spf=fail smtp.mailfrom=evil.com; dkim=fail; dmarc=fail")])
        XCTAssertEqual(MessageParser.senderAuthenticated(fail), false)

        // No header at all → unknown, not a failure.
        let absent = try authMessage([("From", "jane@x.com")])
        XCTAssertNil(MessageParser.senderAuthenticated(absent))
        XCTAssertNil(MessageParser.parse(absent, accountId: "a@x.com").0.senderAuth)
    }

    func testParseStoresListUnsubscribeHeaders() throws {
        let both = try authMessage([
            ("From", "News <news@example.com>"),
            ("List-Unsubscribe",
             "<mailto:unsub@news.example>, <https://news.example/u>"),
            ("List-Unsubscribe-Post", "List-Unsubscribe=One-Click"),
        ])
        let parsed = MessageParser.parse(both, accountId: "a@x.com").0
        XCTAssertEqual(
            parsed.listUnsubscribe,
            "<mailto:unsub@news.example>, <https://news.example/u>")
        XCTAssertEqual(parsed.listUnsubscribePost, "List-Unsubscribe=One-Click")

        let absent = try authMessage([("From", "jane@x.com")])
        let noHeader = MessageParser.parse(absent, accountId: "a@x.com").0
        XCTAssertEqual(noHeader.listUnsubscribe, "")
        XCTAssertEqual(noHeader.listUnsubscribePost, "")
    }

    func testParseStoresReplyToHeader() throws {
        let form = try authMessage([
            ("From", "Acme Forms <noreply@forms.example>"),
            ("Reply-To", "Customer <customer@client.example>"),
        ])
        XCTAssertEqual(MessageParser.parse(form, accountId: "a@x.com").0.replyToHeader,
                       "Customer <customer@client.example>")

        // Empty (not nil) marks "parsed, no header", so the open-time
        // metadata fill does not fetch the message again.
        let absent = try authMessage([("From", "jane@x.com")])
        XCTAssertEqual(MessageParser.parse(absent, accountId: "a@x.com").0.replyToHeader, "")
    }

    /// Google echoes attacker-controlled bytes verbatim in the header value
    /// (envelope sender, free-text comments), so a bare substring match on
    /// "dmarc=pass" would pass on a forged local part or comment text. The
    /// verdict must be a boundary-checked method token, comments stripped.
    func testSenderAuthenticatedRejectsEmbeddedTokens() throws {
        // Forged envelope sender: literal "dmarc=pass" in the local part,
        // real verdict is dmarc=fail.
        let forgedLocalPart = try authMessage([("Authentication-Results",
            #"mx.google.com; spf=pass smtp.mailfrom=\"dmarc=pass\"@evil.example; dmarc=fail"#)])
        XCTAssertEqual(MessageParser.senderAuthenticated(forgedLocalPart), false)

        // A `;` inside the quoted local part must not act as a method
        // separator: the only real verdict here is dmarc=fail.
        let quotedSemicolon = try authMessage([("Authentication-Results",
            #"mx.google.com; spf=pass smtp.mailfrom=\"x;dmarc=pass\"@evil.example; dmarc=fail header.from=trusted.com"#)])
        XCTAssertEqual(MessageParser.senderAuthenticated(quotedSemicolon), false)
        XCTAssertEqual(
            MessageParser.parse(quotedSemicolon, accountId: "a@x.com").0.senderAuth, false)

        // An escaped quote does not end the quoted string.
        let escapedQuote = try authMessage([("Authentication-Results",
            #"mx.google.com; spf=pass smtp.mailfrom=\"a\\\";dmarc=pass; b\"@evil.example; dmarc=fail"#)])
        XCTAssertEqual(MessageParser.senderAuthenticated(escapedQuote), false)

        // Unterminated quote: everything after it is sender text. Fail closed.
        let openQuote = try authMessage([("Authentication-Results",
            #"mx.google.com; spf=pass smtp.mailfrom=\"x;dmarc=pass header.from=trusted.com"#)])
        XCTAssertEqual(MessageParser.senderAuthenticated(openQuote), false)

        // A quote character inside a comment is comment text, not a string
        // start: the real verdict after it still counts.
        let quoteInComment = try authMessage([("Authentication-Results",
            #"mx.google.com; spf=pass (5\" rule) smtp.mailfrom=x.com; dmarc=pass (p=none \"x) header.from=x.com"#)])
        XCTAssertEqual(MessageParser.senderAuthenticated(quoteInComment), true)

        // Token smuggled in a parenthesized comment.
        let commentToken = try authMessage([("Authentication-Results",
            "mx.google.com; dmarc=fail (google.com: dmarc=pass text) header.from=evil.example")])
        XCTAssertEqual(MessageParser.senderAuthenticated(commentToken), false)

        // bestguesspass (Google's no-record value) is NOT a pass.
        let bestGuess = try authMessage([("Authentication-Results",
            "mx.google.com; spf=pass; dmarc=bestguesspass header.from=x.com")])
        XCTAssertEqual(MessageParser.senderAuthenticated(bestGuess), false)

        // dmarc=p=pass (policy record echo) is not the method verdict.
        let policyEcho = try authMessage([("Authentication-Results",
            "mx.google.com; dmarc=fail; dmarc=p=pass header.from=x.com")])
        XCTAssertEqual(MessageParser.senderAuthenticated(policyEcho), false)

        // Whitespace variants of a real pass still qualify.
        let spaced = try authMessage([("Authentication-Results",
            "mx.google.com; spf=pass;  dmarc = pass  header.from=x.com")])
        XCTAssertEqual(MessageParser.senderAuthenticated(spaced), true)
    }

    /// Google prepends its own verdict at delivery, so only the FIRST
    /// Authentication-Results header counts — a forwarded message's inner
    /// "spf=pass" must not launder a failing outer verdict, and an inner
    /// failure must not condemn a passing one.
    func testSenderAuthenticatedUsesFirstHeaderOnly() throws {
        let forgedInner = try authMessage([
            ("Authentication-Results", "mx.google.com; spf=fail; dkim=fail; dmarc=fail"),
            ("Authentication-Results", "inner.example; spf=pass dkim=pass"),
        ])
        XCTAssertEqual(MessageParser.senderAuthenticated(forgedInner), false)

        let failingInner = try authMessage([
            ("Authentication-Results", "mx.google.com; spf=pass; dmarc=pass"),
            ("Authentication-Results", "inner.example; spf=fail"),
        ])
        XCTAssertEqual(MessageParser.senderAuthenticated(failingInner), true)
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
        XCTAssertNil(attachments[0].contentId)
    }

    /// Inline image parts with Content-ID (and empty filename) must become
    /// attachment rows so the reading pane can resolve `cid:` at display time.
    func testParseInlineImageWithContentID() throws {
        // 1×1 PNG
        let png: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
            0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC,
            0x59, 0xE7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
            0x60, 0x82
        ]
        let pngB64 = Data(png).base64URLEncoded()
        let htmlB64 = b64url(#"<p>Hi</p><img src="cid:piece1@usps" alt="Mailpiece Image">"#)
        let json = """
        {
          "id": "m-cid", "threadId": "t-cid",
          "internalDate": "1751500000000",
          "payload": {
            "mimeType": "multipart/related",
            "headers": [{"name": "From", "value": "USPS <usps@email.informeddelivery.usps.com>"}],
            "parts": [
              {"mimeType": "text/html", "body": {"data": "\(htmlB64)"}},
              {
                "mimeType": "image/png",
                "filename": "",
                "headers": [
                  {"name": "Content-ID", "value": "<piece1@usps>"},
                  {"name": "Content-Disposition", "value": "inline"}
                ],
                "body": {"attachmentId": "att-cid-1", "size": \(png.count), "data": "\(pngB64)"}
              }
            ]
          }
        }
        """
        let (message, attachments) = MessageParser.parse(try decodeGMessage(json), accountId: "ron@x.com")
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].contentId, "piece1@usps")
        XCTAssertEqual(attachments[0].gmailAttachmentId, "att-cid-1")
        XCTAssertTrue(attachments[0].filename.hasPrefix("inline-"))
        XCTAssertEqual(attachments[0].mimeType, "image/png")
        // attachmentId parts are NOT inlined at parse time: they resolve at
        // render time (session-only) instead of persisting data: URIs.
        let html = try XCTUnwrap(message.bodyHTML)
        XCTAssertFalse(html.contains("data:image/png;base64,"), html)
        XCTAssertTrue(html.contains("cid:piece1@usps"), html)
        XCTAssertTrue(html.contains("Mailpiece Image"))
    }

    func testParseInlineImageDataOnlyIsInlinedAtParseTime() throws {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let pngB64 = Data(png).base64URLEncoded()
        let htmlB64 = b64url(#"<p>Hi</p><img src="cid:logo@x">"#)
        let json = """
        {
          "id": "m-cid2", "threadId": "t-cid2",
          "internalDate": "1751500000000",
          "payload": {
            "mimeType": "multipart/related",
            "headers": [{"name": "From", "value": "a@b.com"}],
            "parts": [
              {"mimeType": "text/html", "body": {"data": "\(htmlB64)"}},
              {
                "mimeType": "image/png",
                "filename": "",
                "headers": [{"name": "Content-ID", "value": "<logo@x>"}],
                "body": {"size": \(png.count), "data": "\(pngB64)"}
              }
            ]
          }
        }
        """
        let (message, attachments) = MessageParser.parse(try decodeGMessage(json), accountId: "ron@x.com")
        // No attachmentId → no row, but the wire-borne bytes are the only copy,
        // so parse-time rewrite inlines them.
        XCTAssertTrue(attachments.isEmpty)
        let html = try XCTUnwrap(message.bodyHTML)
        XCTAssertTrue(html.contains("data:image/png;base64,"), html)
        XCTAssertFalse(html.contains("cid:logo@x"), html)
    }

    func testParseOversizedDataOnlyBlobIsNotInlined() throws {
        let big = Data(repeating: 0xAB, count: CIDImageInliner.maxPersistedBlobBytes + 1)
        let htmlB64 = b64url(#"<img src="cid:big@x">"#)
        let json = """
        {
          "id": "m-cid3", "threadId": "t-cid3",
          "internalDate": "1751500000000",
          "payload": {
            "mimeType": "multipart/related",
            "headers": [{"name": "From", "value": "a@b.com"}],
            "parts": [
              {"mimeType": "text/html", "body": {"data": "\(htmlB64)"}},
              {
                "mimeType": "image/png",
                "filename": "",
                "headers": [{"name": "Content-ID", "value": "<big@x>"}],
                "body": {"size": \(big.count), "data": "\(big.base64URLEncoded())"}
              }
            ]
          }
        }
        """
        let (message, attachments) = MessageParser.parse(try decodeGMessage(json), accountId: "ron@x.com")
        XCTAssertTrue(attachments.isEmpty)
        let html = try XCTUnwrap(message.bodyHTML)
        XCTAssertTrue(html.contains("cid:big@x"), "oversized blob must stay a cid: reference")
        XCTAssertFalse(html.contains("data:image/png"), html)
    }

    func testParsePlainInlineImageWithoutFilenameOrCIDIsNotAnAttachment() throws {
        // Marketing-mail logo: image/* + attachmentId, no filename, no
        // Content-ID. Must not create a row (paperclip pollution).
        let json = """
        {
          "id": "m-logo", "threadId": "t-logo",
          "internalDate": "1751500000000",
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "From", "value": "a@b.com"}],
            "parts": [
              {"mimeType": "text/html", "body": {"data": "\(b64url("<p>Buy now</p>"))"}},
              {
                "mimeType": "image/gif",
                "filename": "",
                "body": {"attachmentId": "att-logo", "size": 120}
              }
            ]
          }
        }
        """
        let (message, attachments) = MessageParser.parse(try decodeGMessage(json), accountId: "ron@x.com")
        XCTAssertTrue(attachments.isEmpty)
        XCTAssertFalse(message.hasAttachment)
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

    // MARK: - Calendar invite double-card (Google dual MIME)

    /// Google Calendar emails ship the same invite twice: a text/calendar
    /// part inside multipart/alternative (often inline body.data) and a
    /// downloadable application/ics attachment. Parser must keep one row.
    func testParseGoogleCalendarInviteDoesNotDoubleCard() throws {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            BEGIN:VEVENT
            UID:meet@google.com
            SUMMARY:Ron and Eric
            DTSTART:20260805T183000Z
            DTEND:20260805T190000Z
            ORGANIZER:mailto:eric@example.com
            END:VEVENT
            END:VCALENDAR
            """
        let icsB64 = b64url(ics)
        let json = """
        {
          "id": "m-cal", "threadId": "t-cal",
          "internalDate": "1751500000000",
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "From", "value": "Eric <eric@example.com>"}],
            "parts": [
              {
                "mimeType": "multipart/alternative",
                "parts": [
                  {"mimeType": "text/plain", "body": {"data": "\(b64url("When: Wed"))"}},
                  {"mimeType": "text/html", "body": {"data": "\(b64url("<p>When</p>"))"}},
                  {
                    "mimeType": "text/calendar; charset=UTF-8; method=REQUEST",
                    "filename": "invite.ics",
                    "body": {"size": \(ics.utf8.count), "data": "\(icsB64)"}
                  }
                ]
              },
              {
                "mimeType": "application/ics",
                "filename": "invite.ics",
                "body": {"attachmentId": "att-invite", "size": \(ics.utf8.count)}
              }
            ]
          }
        }
        """
        let (message, attachments) = MessageParser.parse(
            try decodeGMessage(json), accountId: "ron@x.com")
        let calendar = attachments.filter {
            CalendarInvite.isCalendarAttachment(
                mimeType: $0.mimeType, filename: $0.filename)
        }
        XCTAssertEqual(calendar.count, 1,
                       "expected one calendar row, got \(calendar.map { "\($0.mimeType):\($0.gmailAttachmentId)" })")
        XCTAssertEqual(calendar.first?.gmailAttachmentId, "att-invite",
                       "prefer downloadable application/ics over inline text/calendar")
        XCTAssertTrue(message.hasAttachment)
        // UI helper must also collapse already-synced duplicates.
        XCTAssertEqual(
            CalendarInvite.uniqueCalendarAttachments(attachments).count, 1)
    }

    /// Both parts have attachmentIds (larger ICS payloads in Gmail API).
    func testParseGoogleCalendarBothAttachmentIdsDoesNotDoubleCard() throws {
        let json = """
        {
          "id": "m-cal2", "threadId": "t-cal2",
          "internalDate": "1751500000000",
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "From", "value": "a@b.com"}],
            "parts": [
              {
                "mimeType": "multipart/alternative",
                "parts": [
                  {"mimeType": "text/html", "body": {"data": "\(b64url("<p>x</p>"))"}},
                  {
                    "mimeType": "text/calendar; method=REQUEST",
                    "filename": "invite.ics",
                    "body": {"attachmentId": "att-alt", "size": 500}
                  }
                ]
              },
              {
                "mimeType": "application/ics",
                "filename": "invite.ics",
                "body": {"attachmentId": "att-file", "size": 500}
              }
            ]
          }
        }
        """
        let (_, attachments) = MessageParser.parse(
            try decodeGMessage(json), accountId: "ron@x.com")
        let calendar = attachments.filter {
            CalendarInvite.isCalendarAttachment(
                mimeType: $0.mimeType, filename: $0.filename)
        }
        XCTAssertEqual(calendar.count, 1, "dual attachmentId calendar parts → one row")
        XCTAssertEqual(calendar.first?.gmailAttachmentId, "att-alt",
                       "first downloadable wins when both have attachmentIds")
    }

    /// Two different .ics files on one message still produce two rows.
    func testParseTwoDistinctCalendarAttachmentsKept() throws {
        let json = """
        {
          "id": "m-cal3", "threadId": "t-cal3",
          "internalDate": "0",
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "From", "value": "a@b.com"}],
            "parts": [
              {
                "mimeType": "text/calendar",
                "filename": "standup.ics",
                "body": {"attachmentId": "a1", "size": 100}
              },
              {
                "mimeType": "text/calendar",
                "filename": "retro.ics",
                "body": {"attachmentId": "a2", "size": 100}
              }
            ]
          }
        }
        """
        let (_, attachments) = MessageParser.parse(
            try decodeGMessage(json), accountId: "ron@x.com")
        XCTAssertEqual(attachments.count, 2)
        XCTAssertEqual(Set(attachments.map(\.filename)),
                       Set(["standup.ics", "retro.ics"]))
    }

    /// Inline + downloadable with *different* filenames must both survive
    /// (Fable finding: removeAll / skip must be key-scoped, not all-calendars).
    func testParseMixedInlineAndDownloadableDistinctFilenamesKept() throws {
        let standup = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            BEGIN:VEVENT
            UID:standup@x.com
            SUMMARY:Standup
            ORGANIZER:mailto:a@x.com
            END:VEVENT
            END:VCALENDAR
            """
        let json = """
        {
          "id": "m-cal4", "threadId": "t-cal4",
          "internalDate": "0",
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "From", "value": "a@b.com"}],
            "parts": [
              {
                "mimeType": "text/calendar; method=REQUEST",
                "filename": "standup.ics",
                "body": {"size": \(standup.utf8.count), "data": "\(b64url(standup))"}
              },
              {
                "mimeType": "application/ics",
                "filename": "retro.ics",
                "body": {"attachmentId": "att-retro", "size": 200}
              }
            ]
          }
        }
        """
        let (_, attachments) = MessageParser.parse(
            try decodeGMessage(json), accountId: "ron@x.com")
        XCTAssertEqual(attachments.count, 2,
                       "distinct filenames must not collapse: \(attachments.map(\.filename))")
        XCTAssertEqual(Set(attachments.map(\.filename)),
                       Set(["standup.ics", "retro.ics"]))
        let standupRow = attachments.first { $0.filename == "standup.ics" }
        XCTAssertTrue(
            AttachmentRow.isInlineCalendarId(standupRow?.gmailAttachmentId ?? ""),
            "standup stays inline when no same-key downloadable exists")
        XCTAssertEqual(
            attachments.first { $0.filename == "retro.ics" }?.gmailAttachmentId,
            "att-retro")
    }

    func testUTF8MislabeledAsLatin1StillDecodesAsUTF8() {
        let data = Data("café — naïve".utf8)
        let b64 = data.base64URLEncoded()
        XCTAssertEqual(
            MessageParser.decodeBase64URL(b64, contentType: "text/plain; charset=iso-8859-1"),
            "café — naïve")
    }
}
