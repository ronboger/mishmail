import Foundation

/// Gmail HTTP batch (`batch/gmail/v1`) request/response helpers.
/// Kept free of network so unit tests can parse fixtures.
enum GmailBatch {
    struct PartResult {
        let id: String
        let statusCode: Int
        let message: GMessage?
        let body: String

        var isSuccess: Bool { (200..<300).contains(statusCode) && message != nil }
    }

    /// Build a multipart/mixed body of GET message parts.
    static func buildRequestBody(ids: [String], format: String, boundary: String) -> Data {
        var s = ""
        for (i, id) in ids.enumerated() {
            s += "--\(boundary)\r\n"
            s += "Content-Type: application/http\r\n"
            s += "Content-ID: <item\(i)>\r\n"
            s += "\r\n"
            s += "GET /gmail/v1/users/me/messages/\(id)?format=\(format)\r\n"
            s += "\r\n"
        }
        s += "--\(boundary)--\r\n"
        return Data(s.utf8)
    }

    /// Parse every multipart response part, retaining non-2xx status and the
    /// request id from `Content-ID: <itemN>`. Gmail returns HTTP 200 for the
    /// outer batch even when an individual part is rate-limited.
    static func parseResults(data: Data, contentType: String,
                             ids: [String]) throws -> [PartResult] {
        guard let boundary = multipartBoundary(from: contentType) else {
            return []
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let parts = text.components(separatedBy: "--\(boundary)")
        var results: [PartResult] = []
        let decoder = JSONDecoder()
        for part in parts {
            // Skip preamble / epilogue / empty.
            guard part.contains("HTTP/") || part.contains("{") else { continue }
            // Status line: "HTTP/1.1 200 OK"
            let code: Int = {
                guard let statusRange = part.range(
                    of: #"HTTP/\d\.\d\s+(\d{3})"#, options: .regularExpression)
                else { return 0 }
                let statusLine = part[statusRange]
                return statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            }()
            let itemIndex = part.firstMatch(
                of: #"Content-ID:\s*<(?:(?:response-)?item)(\d+)>"#)
                .flatMap { Int($0) }
            let id = itemIndex.flatMap { ids.indices.contains($0) ? ids[$0] : nil } ?? ""
            let json: String
            let message: GMessage?
            if let jsonStart = part.range(of: "{"),
               let jsonEnd = part.range(of: "}", options: .backwards) {
                json = String(part[jsonStart.lowerBound...jsonEnd.upperBound])
                message = json.data(using: .utf8).flatMap {
                    try? decoder.decode(GMessage.self, from: $0)
                }
            } else {
                // Error parts are allowed to have an empty body. Retain the
                // status and Content-ID rather than losing the id entirely.
                json = ""
                message = nil
            }
            results.append(PartResult(id: id, statusCode: code, message: message, body: json))
        }
        return results
    }

    /// Compatibility helper for callers that only need successful messages.
    /// Failed parts are intentionally omitted here; network code uses
    /// `parseResults` so it cannot lose per-id quota failures.
    static func parseResponse(data: Data, contentType: String) throws -> [GMessage] {
        try parseResults(data: data, contentType: contentType, ids: [])
            .compactMap(\.message)
    }

    /// Extract boundary token from a Content-Type header value.
    static func multipartBoundary(from contentType: String) -> String? {
        // boundary=foo or boundary="foo"
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else {
            return nil
        }
        var rest = contentType[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"") {
            rest.removeFirst()
            if let end = rest.firstIndex(of: "\"") {
                return String(rest[..<end])
            }
        }
        // Trim trailing parameters (; charset=…)
        if let semi = rest.firstIndex(of: ";") {
            rest = String(rest[..<semi])
        }
        let token = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

private extension String {
    func firstMatch(of pattern: String) -> String? {
        guard let range = range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(self[range])
        guard let digits = match.range(of: #"\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(match[digits])
    }
}
