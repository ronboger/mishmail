import Foundation
import Darwin

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

    /// Split only at commas that start a new URI, so a mailto subject that
    /// contains a comma is not torn apart.
    private static func splitUnbracketed(_ header: String) -> [String] {
        let pattern = #",\s*(?=mailto:|https?:)"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else {
            return header.split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let ns = header as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: header, range: full)
        var starts = [0]
        starts.append(contentsOf: matches.map { $0.range.location + $0.range.length })
        var ends = matches.map(\.range.location)
        ends.append(ns.length)
        return zip(starts, ends).compactMap { start, end in
            guard end > start else { return nil }
            let s = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
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
        if subject.isEmpty { subject = "unsubscribe" }
        body = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return Mailto(address: address, subject: subject, body: body)
    }

    /// From identity for the RFC 2369 mailto: send. Prefer a To/Cc/Bcc
    /// address that is one of ours (the address that subscribed), else the
    /// mailbox primary.
    static func fromEmail(toHeader: String, ccHeader: String, bccHeader: String,
                          ownEmails: Set<String>, accountId: String) -> String {
        let own = Set(ownEmails.map { $0.lowercased() })
        for header in [toHeader, ccHeader, bccHeader] {
            for raw in MessageParser.splitAddresses(header) {
                let email = MessageParser.emailAddress(raw).lowercased()
                if own.contains(email) { return email }
            }
        }
        return accountId
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
        return !isDisallowedHost(host)
    }

    /// Reject local, private, and special-use destinations. `inet_aton` is
    /// intentional here: unlike a dotted-decimal parser it also accepts the
    /// legacy numeric forms browsers and URL stacks may interpret, including
    /// one-component decimal and hexadecimal/short forms.
    static func isDisallowedHost(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") {
            h = String(h.dropFirst().dropLast())
        }
        while h.hasSuffix(".") { h.removeLast() }
        if h == "localhost" || h.hasSuffix(".localhost") ||
            h == "local" || h.hasSuffix(".local") {
            return true
        }

        if let ipv4 = parseIPv4(h) {
            return isDisallowedIPv4(ipv4)
        }
        guard let ipv6 = parseIPv6(h) else { return false }

        // IPv6 unspecified, loopback, link-local, ULA, and multicast.
        if ipv6.allSatisfy({ $0 == 0 }) ||
            (ipv6.dropLast().allSatisfy({ $0 == 0 }) && ipv6.last == 1) {
            return true
        }
        if (ipv6[0] & 0xfe) == 0xfc || // fc00::/7
            (ipv6[0] == 0xfe && (ipv6[1] & 0xc0) == 0x80) || // fe80::/10
            (ipv6[0] & 0xff) == 0xff { // ff00::/8
            return true
        }

        // Treat both IPv4-mapped (::ffff:a.b.c.d) and deprecated
        // IPv4-compatible (::a.b.c.d) addresses as their IPv4 destination.
        let isMapped = ipv6.prefix(10).allSatisfy({ $0 == 0 })
            && ipv6[10] == 0xff && ipv6[11] == 0xff
        let isCompatible = ipv6.prefix(12).allSatisfy({ $0 == 0 })
        if isMapped || isCompatible {
            return isDisallowedIPv4(Array(ipv6.suffix(4)))
        }
        return false
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        var address = in_addr()
        let result = host.withCString { inet_aton($0, &address) }
        guard result == 1 else { return nil }
        let value = UInt32(bigEndian: address.s_addr)
        return [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    private static func parseIPv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let result = host.withCString { inet_pton(AF_INET6, $0, &address) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0.prefix(16)) }
    }

    private static func isDisallowedIPv4(_ address: [UInt8]) -> Bool {
        guard address.count == 4 else { return false }
        let first = address[0]
        let second = address[1]
        if first == 0 || first == 10 || first == 127 { return true }
        if first == 169 && second == 254 { return true }
        if first == 192 && second == 168 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 100 && (64...127).contains(second) { return true }
        if (224...239).contains(first) { return true }
        return address == [255, 255, 255, 255]
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
