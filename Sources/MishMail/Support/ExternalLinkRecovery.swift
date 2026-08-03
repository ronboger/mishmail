import Foundation

/// Recover a browser/mail-safe external URL from a WebKit navigation request.
///
/// Message HTML is loaded via `loadHTMLString(..., baseURL: nil)`, so the
/// document base is `about:blank`. Schemeless hrefs some clients emit
/// (`href="cal.com/stevesimitzis"`) resolve to a URL with scheme `nil` or
/// `about` and must not navigate the message pane. This helper turns those
/// into `https://…` when they look like a real host, while leaving
/// `file://`, `javascript:`, `data:`, and custom app schemes inert.
enum ExternalLinkRecovery {

    /// Allowlisted schemes that may leave the message pane via NSWorkspace.
    private static let passthroughSchemes: Set<String> = ["http", "https", "mailto"]

    /// Returns a URL safe to open externally, or `nil` to keep the click inert.
    static func recoveredExternalURL(from url: URL?) -> URL? {
        guard let url else { return nil }
        let scheme = (url.scheme ?? "").lowercased()

        if passthroughSchemes.contains(scheme) {
            return url
        }

        // Only schemeless / about-resolved hrefs are candidates for recovery.
        // Everything else (file, javascript, data, custom) stays cancelled.
        guard scheme.isEmpty || scheme == "about" else { return nil }

        guard let candidate = bareHostCandidate(from: url) else { return nil }
        // Same bar as compose autolink: multi-label host + known TLD, not
        // file-looking tokens (readme.md) or single labels (foo).
        guard TextDirection.isLinkableHost(candidate) else { return nil }
        return URL(string: "https://\(candidate)")
    }

    /// Peel WebKit's about:blank resolution off `absoluteString` and return a
    /// bare `host[/path]` candidate, or nil when nothing domain-like remains.
    private static func bareHostCandidate(from url: URL) -> String? {
        // Prefer absoluteString so percent-encoded path forms
        // (`about:blank%2Fcal.com%2Ffoo`) survive; decode after peeling.
        var s = url.absoluteString
        if let decoded = s.removingPercentEncoding {
            s = decoded
        }

        // Case-insensitive "about:" strip (scheme already checked).
        if s.count >= 6, s.prefix(6).lowercased() == "about:" {
            s = String(s.dropFirst(6))
        }

        // `about:blank` document marker only — not hosts like blank.example.com.
        if s.lowercased() == "blank" {
            return nil
        }
        if s.count >= 6, s.prefix(6).lowercased() == "blank/" {
            s = String(s.dropFirst(5)) // leave the leading '/'
        }

        while s.hasPrefix("/") {
            s.removeFirst()
        }

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        guard !s.contains(where: { $0.isWhitespace }) else { return nil }

        // Reject any reconstructed scheme (javascript:, data:, file:, …).
        // host:port keeps a '.' before the first ':', so it falls through.
        if let colon = s.firstIndex(of: ":") {
            let prefix = String(s[..<colon])
            if isSchemeToken(prefix) { return nil }
        }

        // Leading token before '/' must look like a hostname (contains a dot).
        let hostPart = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? s
        // Strip :port for the shape check; TextDirection does this too for TLD.
        let hostOnly: String = {
            if let colon = hostPart.lastIndex(of: ":"),
               hostPart[hostPart.index(after: colon)...].allSatisfy(\.isNumber) {
                return String(hostPart[..<colon])
            }
            return hostPart
        }()
        guard hostOnly.contains(".") else { return nil }
        guard isHostnameCharacters(hostOnly) else { return nil }

        return s
    }

    /// RFC 3986 scheme shape without '.': ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
    /// but we ban '.' so `example.com:8080` is not treated as a scheme.
    private static func isSchemeToken(_ prefix: String) -> Bool {
        guard let first = prefix.first, first.isLetter else { return false }
        return prefix.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "+" || ch == "-"
        }
    }

    private static func isHostnameCharacters(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        return host.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            // a-z A-Z 0-9 . -
            return (v >= 0x61 && v <= 0x7A)
                || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x30 && v <= 0x39)
                || scalar == "." || scalar == "-"
        }
    }
}
