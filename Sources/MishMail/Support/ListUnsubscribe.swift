import Foundation

/// RFC 2369 `List-Unsubscribe` + RFC 8058 one-click (`List-Unsubscribe-Post`).
///
/// Gmail shows Unsubscribe when this header is present. We do the same:
/// one-click HTTPS POST when advertised, otherwise a mailto send or an
/// HTTPS page in the browser. User confirmation is the caller's job.
enum ListUnsubscribe {

    struct Mailto: Equatable {
        var address: String
        var subject: String
        var body: String
    }

    enum Action: Equatable {
        /// RFC 8058 POST to an HTTPS URI. Body is `List-Unsubscribe=One-Click`.
        case oneClick(URL)
        /// RFC 2369 mailto: send an unsubscribe email through Gmail.
        case mailto(Mailto)
        /// HTTPS (or HTTP) landing page — open in the default browser.
        case open(URL)
    }

    struct Offer: Equatable {
        var httpURLs: [URL]
        var mailto: Mailto?
        var allowsOneClick: Bool

        var preferredAction: Action? {
            if allowsOneClick,
               let url = httpURLs.first(where: { isSafeOneClickURL($0) }) {
                return .oneClick(url)
            }
            if let mailto { return .mailto(mailto) }
            if let https = httpURLs.first(where: {
                $0.scheme?.lowercased() == "https" && isSafeBrowserURL($0)
            }) {
                return .open(https)
            }
            if let http = httpURLs.first(where: { isSafeBrowserURL($0) }) {
                return .open(http)
            }
            return nil
        }
    }

    enum PerformError: LocalizedError, Equatable {
        case unsafeURL
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .unsafeURL:
                return "The unsubscribe link is not a valid HTTPS address."
            case .httpStatus(let code):
                return "The mailing list returned an error (\(code))."
            }
        }
    }

    /// Parsed offer from stored header values. Empty / missing header →
    /// an offer with no action (caller treats as "no Unsubscribe button").
    static func parse(listUnsubscribe: String,
                      listUnsubscribePost: String) -> Offer {
        let uris = extractURIs(listUnsubscribe)
        var httpURLs: [URL] = []
        var mailto: Mailto?
        for uri in uris {
            let scheme = uri.scheme?.lowercased() ?? ""
            if scheme == "mailto" {
                if mailto == nil { mailto = parseMailto(uri.absoluteString) }
            } else if scheme == "https" || scheme == "http" {
                httpURLs.append(uri)
            }
        }
        return Offer(
            httpURLs: httpURLs,
            mailto: mailto,
            allowsOneClick: isOneClickPostHeader(listUnsubscribePost))
    }

    /// Nil when the message has not recorded headers yet (`listUnsubscribe`
    /// is nil) or when the header yields no safe action.
    static func offer(from message: Message) -> Offer? {
        guard let header = message.listUnsubscribe else { return nil }
        let offer = parse(
            listUnsubscribe: header,
            listUnsubscribePost: message.listUnsubscribePost ?? "")
        return offer.preferredAction == nil ? nil : offer
    }

    /// Newest message in `messages` that has a usable unsubscribe action.
    static func preferredMessage(in messages: [Message]) -> Message? {
        messages
            .filter { offer(from: $0)?.preferredAction != nil }
            .max(by: { $0.date < $1.date })
    }

    static func confirmationTitle(fromHeader: String) -> String {
        let name = MessageParser.displayName(fromHeader: fromHeader)
        return "Unsubscribe from emails from \(name)?"
    }

    static func confirmationDetail(for action: Action) -> String {
        switch action {
        case .oneClick:
            return "MishMail will tell this mailing list to stop sending you email. The sender must honor the request."
        case .mailto(let mailto):
            return "MishMail will send an unsubscribe email to \(mailto.address)."
        case .open:
            return "MishMail will open the sender's unsubscribe page in your browser."
        }
    }

    /// RFC 8058 one-click POST. Nil when the URL is not a safe HTTPS target.
    static func oneClickRequest(url: URL) -> URLRequest? {
        guard isSafeOneClickURL(url) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        req.timeoutInterval = 20
        return req
    }

    static func isSafeOneClickURL(_ url: URL) -> Bool {
        isSafeHTTPURL(url, requireHTTPS: true)
    }

    static func isSafeBrowserURL(_ url: URL) -> Bool {
        isSafeHTTPURL(url, requireHTTPS: false)
    }

    /// POST with no cookies, HTTPS-only redirects. Throws on non-2xx.
    static func performOneClick(_ url: URL) async throws {
        guard let req = oneClickRequest(url: url) else {
            throw PerformError.unsafeURL
        }
        let (data, response) = try await session.data(for: req)
        _ = data
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw PerformError.httpStatus(code)
        }
    }

    // MARK: - Header parsing

    /// Angle-bracket URIs first (RFC 2369). If none, comma-separated tokens.
    static func extractURIs(_ header: String) -> [URL] {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let bracketed = extractBracketed(trimmed)
        let raw = bracketed.isEmpty ? splitUnbracketed(trimmed) : bracketed
        return raw.compactMap { URL(string: $0) }
    }

    static func isOneClickPostHeader(_ value: String) -> Bool {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined()
        return collapsed.caseInsensitiveCompare("List-Unsubscribe=One-Click")
            == .orderedSame
    }

    // MARK: - Internals

    private static let redirectDelegate = HTTPSOnlyRedirectDelegate()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(
            configuration: config,
            delegate: redirectDelegate,
            delegateQueue: nil)
    }()

    private static func extractBracketed(_ header: String) -> [String] {
        var out: [String] = []
        var remainder = header[...]
        while let open = remainder.firstIndex(of: "<") {
            remainder = remainder[remainder.index(after: open)...]
            guard let close = remainder.firstIndex(of: ">") else { break }
            let inner = remainder[..<close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty { out.append(inner) }
            remainder = remainder[remainder.index(after: close)...]
        }
        return out
    }

    private static func splitUnbracketed(_ header: String) -> [String] {
        header.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func parseMailto(_ raw: String) -> Mailto? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              comps.scheme?.lowercased() == "mailto" else { return nil }
        var address = comps.path
        if address.isEmpty {
            let s = comps.string ?? trimmed
            if let colon = s.firstIndex(of: ":") {
                let rest = s[s.index(after: colon)...]
                address = rest.split(separator: "?", maxSplits: 1)
                    .first.map(String.init) ?? ""
            }
        }
        address = address.removingPercentEncoding ?? address
        if address.hasPrefix("//") { address = String(address.dropFirst(2)) }
        address = address.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = address.firstIndex(of: ",") {
            address = String(address[..<comma])
                .trimmingCharacters(in: .whitespaces)
        }
        guard address.contains("@"),
              !address.contains(where: { $0 == "\n" || $0 == "\r" || $0 == " " }),
              address.count <= 320,
              address.utf8.contains(where: { $0 == UInt8(ascii: "@") })
        else { return nil }

        var subject = ""
        var body = ""
        for item in comps.queryItems ?? [] {
            let name = item.name.lowercased()
            let value = item.value ?? ""
            if name == "subject" { subject = value }
            else if name == "body" { body = value }
        }
        subject = subject
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        body = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return Mailto(address: address, subject: subject, body: body)
    }

    /// One-click POST (and HTTPS open) must not target loopback, link-local,
    /// or URLs with embedded credentials. HTTP is allowed only for browser
    /// open (`requireHTTPS: false`).
    static func isSafeHTTPURL(_ url: URL, requireHTTPS: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if requireHTTPS {
            guard scheme == "https" else { return false }
        } else {
            guard scheme == "http" || scheme == "https" else { return false }
        }
        guard url.user == nil, url.password == nil else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        let h = host.lowercased()
        if h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "0.0.0.0" {
            return false
        }
        if h.hasPrefix("127.") || h.hasPrefix("169.254.") { return false }
        if h.hasPrefix("[") { return false }  // IPv6 literal
        return true
    }
}

/// Rejects redirects that leave HTTPS. Shared by the one-click session.
private final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, ListUnsubscribe.isSafeOneClickURL(url) else {
            return nil
        }
        return request
    }
}
