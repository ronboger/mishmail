import Foundation

/// Resolves `cid:` image references in HTML mail to `data:` URIs.
///
/// WebKit `loadHTMLString` has no MIME part graph, so `cid:` never paints
/// unless we rewrite it. CSP already allows `data:` and `cid:`; this module
/// supplies the missing bytes. Pure / hostless so unit tests can pin behavior
/// without WebKit or Gmail.
enum CIDImageInliner {
    /// Normalize a Content-ID header value or `cid:` URL target to a
    /// comparable key: strip optional `cid:` / angle brackets, percent-decode
    /// once, trim, lowercase.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 4, s.prefix(4).lowercased() == "cid:" {
            s = String(s.dropFirst(4))
        }
        s = s.removingPercentEncoding ?? s
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, s.first == "<", s.last == ">" {
            s = String(s.dropFirst().dropLast())
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.lowercased()
    }

    /// True when the HTML references at least one `cid:` image source.
    static func containsCIDReferences(_ html: String) -> Bool {
        html.range(of: #"src\s*=\s*(['"]?)cid:"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Distinct normalized content IDs referenced by `img` `src="cid:…"`.
    static func referencedIDs(in html: String) -> Set<String> {
        let pattern = #"src\s*=\s*(['"]?)cid:([^'"\s>]+)\1"#
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        var ids = Set<String>()
        re.enumerateMatches(in: html, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 3,
                  match.range(at: 2).location != NSNotFound else { return }
            let raw = ns.substring(with: match.range(at: 2))
            let key = normalize(raw)
            if !key.isEmpty { ids.insert(key) }
        }
        return ids
    }

    /// Replace matching `img src="cid:…"` with `data:` URIs.
    ///
    /// `parts` keys must already be `normalize`d. Unmatched cids are left
    /// alone (broken-image placeholder stays).
    static func rewrite(_ html: String,
                        parts: [String: (mimeType: String, data: Data)]) -> String {
        guard !parts.isEmpty, containsCIDReferences(html) else { return html }
        let pattern = #"(src\s*=\s*)(['"]?)cid:([^'"\s>]+)\2"#
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        let result = NSMutableString(string: html)
        // Walk matches reverse so range offsets stay valid.
        let matches = re.matches(in: html, options: [], range: full)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4,
                  match.range(at: 3).location != NSNotFound else { continue }
            let rawCID = ns.substring(with: match.range(at: 3))
            let key = normalize(rawCID)
            guard let part = parts[key] else { continue }
            let uri = dataURI(mimeType: part.mimeType, data: part.data)
            let prefix = ns.substring(with: match.range(at: 1))
            let replacement = "\(prefix)\"\(uri)\""
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    /// `data:` URI for an image part. Strips parameters from MIME type and
    /// rejects obviously non-image types with a safe `application/octet-stream`
    /// so a hostile Content-Type cannot inject a scriptable SVG-as-HTML payload
    /// via a type we don't expect (SVG still needs care; we only allow image/*).
    static func dataURI(mimeType: String, data: Data) -> String {
        let mime = sanitizeMIME(mimeType)
        let b64 = data.base64EncodedString()
        return "data:\(mime);base64,\(b64)"
    }

    /// Keep only a simple `type/subtype` token; default to `image/jpeg`.
    static func sanitizeMIME(_ raw: String) -> String {
        let head = (raw.split(separator: ";", maxSplits: 1,
                              omittingEmptySubsequences: true).first)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? ""
        // Allow image/* only — CID inlining is for mailpiece/logo scans, not
        // arbitrary attachments that happen to carry a Content-ID.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/.+-"))
        if head.hasPrefix("image/"),
           head.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return head
        }
        return "image/jpeg"
    }

    /// Filename for an inline part that Gmail shipped without one.
    static func syntheticFilename(contentId: String?, mimeType: String) -> String {
        let ext: String = {
            switch sanitizeMIME(mimeType) {
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/svg+xml": return "svg"
            default: return "jpg"
            }
        }()
        if let cid = contentId, !cid.isEmpty {
            let safe = cid
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
                .prefix(48)
            return "inline-\(safe).\(ext)"
        }
        return "inline-image.\(ext)"
    }
}
