import Foundation

/// Parsed HTTP/1.1 request. Header keys are lowercased for case-insensitive lookup.
struct MCPHTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

/// Minimal HTTP/1.1 request/response helpers for the in-process MCP server.
///
/// Deliberately tiny and pure: no Network.framework, no streaming, no
/// keep-alive. The server uses `Connection: close` and parses only enough to
/// extract method/path/headers/body for JSON-RPC over Streamable HTTP.
enum MCPHTTP {

    /// Parse a complete HTTP/1.1 request from accumulated bytes.
    ///
    /// Returns `nil` while the request is incomplete (headers not finished, or
    /// body shorter than `Content-Length`) or when the framing is invalid.
    /// Callers should keep accumulating until this returns a value, subject to
    /// their own size cap.
    static func parse(_ data: Data) -> MCPHTTPRequest? {
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerEnd = data.range(of: crlfcrlf) else { return nil }

        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        // Path may include query; strip it for routing.
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines {
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            headers[name] = value
        }

        let bodyStart = headerEnd.upperBound
        let contentLength: Int
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return nil }
            contentLength = n
        } else {
            contentLength = 0
        }

        let available = data.count - bodyStart
        guard available >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))

        return MCPHTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    /// Build a complete HTTP/1.1 response. Always closes the connection.
    static func response(
        status: Int,
        reason: String,
        contentType: String? = nil,
        body: Data = Data()
    ) -> Data {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        if let contentType {
            header += "Content-Type: \(contentType)\r\n"
        }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    /// Extract the Bearer token from an `Authorization` header value map.
    static func bearerToken(from headers: [String: String]) -> String? {
        guard let value = headers["authorization"] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let prefix = "Bearer "
        guard trimmed.count > prefix.count,
              trimmed.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else {
            return nil
        }
        let token = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
