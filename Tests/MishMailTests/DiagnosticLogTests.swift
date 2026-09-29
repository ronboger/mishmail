import XCTest

final class DiagnosticLogTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString)/diagnostics.log")
    }

    func testFormatKeepsStatusPathAndFullReason() {
        let body = #"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}]}}"#
        let line = DiagnosticLog.format(account: "a@b.com", method: "GET",
                                        path: "/history", code: 403, body: body)
        XCTAssertTrue(line.contains("a@b.com"))
        XCTAssertTrue(line.contains("GET /history status=403"))
        XCTAssertTrue(line.contains("accessNotConfigured"))
    }

    func testBodyIsFlattenedAndClipped() {
        let long = String(repeating: "x", count: DiagnosticLog.maxBodyChars + 50)
        XCTAssertTrue(DiagnosticLog.clip(long).hasSuffix("…"))
        XCTAssertFalse(DiagnosticLog.clip("a\nb\r\nc").contains("\n"))
    }

    func testDescribeKeepsWholeGmailBody() {
        let body = String(repeating: "r", count: 900)
        let text = DiagnosticLog.describe(GmailError.http(403, body))
        XCTAssertTrue(text.contains("http=403"))
        XCTAssertTrue(text.contains(body))
    }

    func testAppendCreatesDirectoryAndRotates() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        DiagnosticLog.append("first", to: url, now: Date())
        DiagnosticLog.append("second", to: url, now: Date())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)

        let big = String(repeating: "y", count: DiagnosticLog.maxBytes + 10)
        try big.write(to: url, atomically: true, encoding: .utf8)
        DiagnosticLog.append("after-rotate", to: url, now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("after-rotate"))
    }
}
