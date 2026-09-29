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

    func testParseResultsRetainsPerPartRateLimitStatus() throws {
        let boundary = "batch_rate"
        let multipart = """
            --\(boundary)
            Content-Type: application/http
            Content-ID: <item0>

            HTTP/1.1 200 OK
            Content-Type: application/json

            {"id":"m1","threadId":"t1"}
            --\(boundary)
            Content-Type: application/http
            Content-ID: <item1>

            HTTP/1.1 403 Forbidden
            Content-Type: application/json

            {"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}
            --\(boundary)--
            """
        let results = try GmailBatch.parseResults(
            data: Data(multipart.utf8),
            contentType: "multipart/mixed; boundary=\(boundary)",
            ids: ["m1", "m2"])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, "m1")
        XCTAssertEqual(results[0].statusCode, 200)
        XCTAssertEqual(results[1].id, "m2")
        XCTAssertEqual(results[1].statusCode, 403)
        XCTAssertTrue(results[1].body.contains("userRateLimitExceeded"))
    }

    func testParseResultsRetainsEmptyErrorPart() throws {
        let boundary = "batch_empty_error"
        let multipart = """
            --\(boundary)
            Content-Type: application/http
            Content-ID: <item0>

            HTTP/1.1 403 Forbidden

            --\(boundary)--
            """
        let results = try GmailBatch.parseResults(
            data: Data(multipart.utf8),
            contentType: "multipart/mixed; boundary=\(boundary)",
            ids: ["m1"])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "m1")
        XCTAssertEqual(results[0].statusCode, 403)
        XCTAssertNil(results[0].message)
    }
}
