import Foundation

/// Gmail HTTP batch (`batch/gmail/v1`) request/response helpers.
/// Kept free of network so unit tests can parse fixtures.
enum GmailBatch {
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

    /// Parse a multipart batch response into successful `GMessage`s.
    /// Failed parts (non-2xx) are skipped.
    static func parseResponse(data: Data, contentType: String) throws -> [GMessage] {
        guard let boundary = multipartBoundary(from: contentType) else {
            // Some gateways return a single JSON error — treat as empty so
            // the caller can fall back to concurrent gets.
            return []
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let parts = text.components(separatedBy: "--\(boundary)")
        var messages: [GMessage] = []
        let decoder = JSONDecoder()
        for part in parts {
            // Skip preamble / epilogue / empty.
            guard part.contains("HTTP/") || part.contains("{") else { continue }
            // Status line: "HTTP/1.1 200 OK"
            if let statusRange = part.range(of: #"HTTP/\d\.\d\s+(\d{3})"#, options: .regularExpression) {
                let statusLine = part[statusRange]
                let code = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
                guard (200..<300).contains(code) else { continue }
            }
            guard let jsonStart = part.range(of: "{"),
                  let jsonEnd = part.range(of: "}", options: .backwards) else { continue }
            let json = String(part[jsonStart.lowerBound...jsonEnd.upperBound])
            guard let jsonData = json.data(using: .utf8) else { continue }
            if let msg = try? decoder.decode(GMessage.self, from: jsonData) {
                messages.append(msg)
            }
        }
        return messages
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
