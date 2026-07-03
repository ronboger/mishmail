import XCTest

final class MIMEBuilderTests: XCTestCase {

    private func lines(of data: Data) -> [String] {
        String(data: data, encoding: .utf8)!.components(separatedBy: "\r\n")
    }

    /// Extracts and decodes the base64 body that follows the first blank line.
    private func decodedBody(of data: Data) -> String? {
        let all = lines(of: data)
        guard let blank = all.firstIndex(of: "") else { return nil }
        let b64 = all[(blank + 1)...].prefix { !$0.hasPrefix("--") }.joined()
        // The encoder wraps at 76 chars with LF; ignore those when decoding.
        return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    func testSimpleMessageHeadersAndBody() {
        let raw = MIMEBuilder.build(from: "Ron Boger <ron@x.com>", to: "jane@y.com",
                                    subject: "Hello", bodyText: "The body.\nLine two.")
        let all = lines(of: raw)
        XCTAssertTrue(all.contains("From: Ron Boger <ron@x.com>"))
        XCTAssertTrue(all.contains("To: jane@y.com"))
        XCTAssertTrue(all.contains("Subject: Hello"))
        XCTAssertTrue(all.contains("MIME-Version: 1.0"))
        XCTAssertTrue(all.contains("Content-Type: text/plain; charset=UTF-8"))
        XCTAssertFalse(all.contains { $0.hasPrefix("Cc:") })
        XCTAssertFalse(all.contains { $0.hasPrefix("Bcc:") })
        XCTAssertFalse(all.contains { $0.hasPrefix("In-Reply-To:") })
        XCTAssertEqual(decodedBody(of: raw), "The body.\nLine two.")
    }

    func testCcAndBccHeaders() {
        let raw = MIMEBuilder.build(from: "ron@x.com", to: "jane@y.com",
                                    cc: "cc@y.com", bcc: "secret@z.com, two@z.com",
                                    subject: "s", bodyText: "b")
        let all = lines(of: raw)
        XCTAssertTrue(all.contains("Cc: cc@y.com"))
        XCTAssertTrue(all.contains("Bcc: secret@z.com, two@z.com"))
    }

    func testReplyThreadingHeaders() {
        let raw = MIMEBuilder.build(from: "ron@x.com", to: "jane@y.com",
                                    subject: "Re: s", bodyText: "b",
                                    inReplyTo: "<msg1@mail>", references: "<msg0@mail>")
        let all = lines(of: raw)
        XCTAssertTrue(all.contains("In-Reply-To: <msg1@mail>"))
        XCTAssertTrue(all.contains("References: <msg0@mail> <msg1@mail>"))
    }

    func testReplyWithoutPriorReferences() {
        let raw = MIMEBuilder.build(from: "ron@x.com", to: "jane@y.com",
                                    subject: "Re: s", bodyText: "b",
                                    inReplyTo: "<msg1@mail>")
        XCTAssertTrue(lines(of: raw).contains("References: <msg1@mail>"))
    }

    func testAttachmentsProduceMultipartMixed() {
        let payload = Data("PDFBYTES".utf8)
        let raw = MIMEBuilder.build(
            from: "ron@x.com", to: "jane@y.com", subject: "s", bodyText: "b",
            attachments: [.init(filename: "report.pdf", mimeType: "application/pdf", data: payload)])
        let text = String(data: raw, encoding: .utf8)!
        let all = lines(of: raw)

        guard let ctLine = all.first(where: { $0.hasPrefix("Content-Type: multipart/mixed; boundary=\"") })
        else { return XCTFail("missing multipart content type") }
        let boundary = ctLine.components(separatedBy: "\"")[1]

        // Two opening boundary markers (text part + attachment) and one closer.
        XCTAssertEqual(all.filter { $0 == "--\(boundary)" }.count, 2)
        XCTAssertEqual(all.filter { $0 == "--\(boundary)--" }.count, 1)
        XCTAssertTrue(text.contains("Content-Type: application/pdf; name=\"report.pdf\""))
        XCTAssertTrue(text.contains("Content-Disposition: attachment; filename=\"report.pdf\""))
        XCTAssertTrue(text.contains(payload.base64EncodedString()))
    }

    func testNonASCIISubjectIsRFC2047Encoded() {
        let subject = "Résumé — für Sie"
        let raw = MIMEBuilder.build(from: "a@b.com", to: "c@d.com",
                                    subject: subject, bodyText: "b")
        guard let line = lines(of: raw).first(where: { $0.hasPrefix("Subject: ") })
        else { return XCTFail("missing subject") }
        XCTAssertTrue(line.hasPrefix("Subject: =?UTF-8?B?"))
        XCTAssertTrue(line.hasSuffix("?="))
        let b64 = line.replacingOccurrences(of: "Subject: =?UTF-8?B?", with: "")
            .replacingOccurrences(of: "?=", with: "")
        XCTAssertEqual(Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }, subject)
    }

    func testASCIISubjectStaysPlain() {
        let raw = MIMEBuilder.build(from: "a@b.com", to: "c@d.com",
                                    subject: "Plain subject", bodyText: "b")
        XCTAssertTrue(lines(of: raw).contains("Subject: Plain subject"))
    }

    func testUnicodeBodySurvivesRoundTrip() {
        let body = "Emoji-frei, aber Ümlaute und — Gedankenstriche.\n中文也可以。"
        let raw = MIMEBuilder.build(from: "a@b.com", to: "c@d.com", subject: "s", bodyText: body)
        XCTAssertEqual(decodedBody(of: raw), body)
    }

    // MARK: - Header injection (CRLF) hardening

    func testCRLFInHeaderValuesCannotInjectHeaders() {
        // Threading headers come verbatim from received mail; a hostile
        // Message-ID/References (or a pasted subject) must not add headers.
        let raw = MIMEBuilder.build(
            from: "a@b.com", to: "c@d.com",
            subject: "Hi\r\nBcc: evil@attacker.com",
            bodyText: "b",
            inReplyTo: "<msg1@mail>\r\nX-Injected: 1",
            references: "<msg0@mail>\nX-Also-Injected: 2")
        let all = lines(of: raw)
        XCTAssertFalse(all.contains { $0.hasPrefix("Bcc:") })
        XCTAssertFalse(all.contains { $0.hasPrefix("X-Injected:") })
        XCTAssertFalse(all.contains { $0.hasPrefix("X-Also-Injected:") })
        // Values survive, folded onto their own single line.
        XCTAssertTrue(all.contains { $0.hasPrefix("Subject: Hi ") })
        XCTAssertTrue(all.contains { $0.hasPrefix("In-Reply-To: <msg1@mail>") })
        XCTAssertTrue(all.contains { $0.hasPrefix("References: <msg0@mail>") })
    }

    func testCRLFInRecipientsCannotInjectHeaders() {
        let raw = MIMEBuilder.build(
            from: "Ron\r\nX-From-Inject: 1 <a@b.com>",
            to: "c@d.com\r\nX-To-Inject: 1",
            subject: "s", bodyText: "b")
        let all = lines(of: raw)
        XCTAssertFalse(all.contains { $0.hasPrefix("X-From-Inject:") })
        XCTAssertFalse(all.contains { $0.hasPrefix("X-To-Inject:") })
    }

    func testAttachmentFilenameCannotEscapeQuotingOrInjectHeaders() {
        let raw = MIMEBuilder.build(
            from: "a@b.com", to: "c@d.com", subject: "s", bodyText: "b",
            attachments: [.init(filename: "evil\"\r\nX-Bad: 1.pdf",
                                mimeType: "application/pdf", data: Data("x".utf8))])
        let text = String(data: raw, encoding: .utf8)!
        let all = lines(of: raw)
        XCTAssertFalse(all.contains { $0.hasPrefix("X-Bad:") })
        XCTAssertFalse(text.contains("filename=\"evil\"\""))
        // Still one quoted, newline-free parameter on the disposition line.
        XCTAssertTrue(all.contains { $0.hasPrefix("Content-Disposition: attachment; filename=\"")
                                     && $0.hasSuffix("\"") })
    }
}
