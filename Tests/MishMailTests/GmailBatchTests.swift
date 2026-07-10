import XCTest

final class GmailBatchTests: XCTestCase {
    func testBuildRequestBodyContainsIds() {
        let body = GmailBatch.buildRequestBody(
            ids: ["abc", "def"], format: "full", boundary: "b1")
        let s = String(data: body, encoding: .utf8)!
        XCTAssertTrue(s.contains("GET /gmail/v1/users/me/messages/abc?format=full"))
        XCTAssertTrue(s.contains("GET /gmail/v1/users/me/messages/def?format=full"))
        XCTAssertTrue(s.contains("--b1--"))
    }

    func testMultipartBoundaryParsing() {
        XCTAssertEqual(
            GmailBatch.multipartBoundary(from: "multipart/mixed; boundary=abc123"),
            "abc123")
        XCTAssertEqual(
            GmailBatch.multipartBoundary(from: #"multipart/mixed; boundary="xyz""#),
            "xyz")
        XCTAssertNil(GmailBatch.multipartBoundary(from: "application/json"))
    }

    func testParseResponseMixedSuccess() throws {
        let boundary = "batch_x"
        let okJSON = #"{"id":"m1","threadId":"t1","snippet":"hi","labelIds":["INBOX"]}"#
        let multipart = """
            --\(boundary)
            Content-Type: application/http

            HTTP/1.1 200 OK
            Content-Type: application/json

            \(okJSON)
            --\(boundary)
            Content-Type: application/http

            HTTP/1.1 404 Not Found

            {"error":{"code":404}}
            --\(boundary)--
            """
        let msgs = try GmailBatch.parseResponse(
            data: Data(multipart.utf8),
            contentType: "multipart/mixed; boundary=\(boundary)")
        XCTAssertEqual(msgs.map(\.id), ["m1"])
    }
}
