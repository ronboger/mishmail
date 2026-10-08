import Foundation

/// Link detection for plain-text message bodies shown in a SwiftUI `Text`.
///
/// The body is untrusted. Only `http`, `https` and `mailto` become links, and
/// the visible text of a link is always its destination (a bare address gets
/// `mailto:` in front), so a link cannot show one target and open another.
enum PlainTextLinks {
    struct Link: Equatable {
        /// UTF-16 range in the source text.
        let range: NSRange
        let url: URL
    }

    /// Only this many UTF-16 units from the start are scanned; the rest of a
    /// huge body stays plain text.
    static let maxScanLength = 200_000
    /// Bound on attributed runs: `Text` layout slows with thousands of them.
    static let maxLinks = 1_000

    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Brackets are allowed inside (`…/Swift_(language)`); `trimmed` removes
    /// the unbalanced ones at the end.
    private static let urlRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?i)\b(?:https?://|mailto:)[^\s<>"]+"#)
    }()

    /// ASCII mailbox with a dotted domain. The lookbehind keeps a match from
    /// starting inside a longer token; the lookahead rejects `git@host:path`.
    private static let emailRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<![\w.+\-/:@=])[A-Za-z0-9][A-Za-z0-9._+\-]{0,63}@(?:[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,24}(?![\w@\-]|\.\w|:[\w/~])"#)
    }()

    private static let trailingPunctuation = Set(".,;:!?'\"".utf16)
    private static let closers: [unichar: unichar] = [
        0x29: 0x28,  // ) (
        0x5D: 0x5B,  // ] [
        0x7D: 0x7B,  // } {
    ]

    // MARK: - Detection

    /// Links in `text`, sorted by position, never overlapping.
    static func links(in text: String) -> [Link] {
        // Cheap reject: most bodies with no link have neither marker.
        guard text.contains("@") || text.contains("://") else { return [] }
        let ns = text as NSString
        let scan = NSRange(location: 0, length: min(ns.length, maxScanLength))
        let truncated = scan.length < ns.length

        var found: [Link] = []
        var urlSpans: [NSRange] = []
        urlRegex.enumerateMatches(in: text, options: [], range: scan) { match, _, stop in
            guard let match else { return }
            urlSpans.append(match.range)
            // A match that runs into the cap may be the front of a longer URL.
            if truncated, NSMaxRange(match.range) == scan.length { return }
            guard let range = trimmed(match.range, in: ns),
                  let url = URL(string: ns.substring(with: range)),
                  isOpenable(url) else { return }
            found.append(Link(range: range, url: url))
            if found.count >= maxLinks { stop.pointee = true }
        }
        if found.count < maxLinks {
            emailRegex.enumerateMatches(in: text, options: [], range: scan) { match, _, stop in
                guard let match else { return }
                if truncated, NSMaxRange(match.range) == scan.length { return }
                // Part of a URL (`?email=a@b.com`, `mailto:a@b.com`).
                guard !urlSpans.contains(where: {
                    NSIntersectionRange($0, match.range).length > 0
                }), let url = URL(string: "mailto:" + ns.substring(with: match.range))
                else { return }
                found.append(Link(range: match.range, url: url))
                if found.count >= maxLinks { stop.pointee = true }
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Drop sentence punctuation and unbalanced closing brackets from the end
    /// of a URL match: `(see https://a.com/x).` links `https://a.com/x`.
    private static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange? {
        var counts: [unichar: Int] = [:]
        for i in range.location..<NSMaxRange(range) {
            let ch = ns.character(at: i)
            if closers[ch] != nil || closers.values.contains(ch) {
                counts[ch, default: 0] += 1
            }
        }
        var r = range
        while r.length > 0 {
            let last = ns.character(at: NSMaxRange(r) - 1)
            if trailingPunctuation.contains(last) {
                r.length -= 1
            } else if let opener = closers[last],
                      counts[last, default: 0] > counts[opener, default: 0] {
                counts[last, default: 0] -= 1
                r.length -= 1
            } else {
                break
            }
        }
        return r.length > 0 ? r : nil
    }

    private static func isOpenable(_ url: URL) -> Bool {
        switch (url.scheme ?? "").lowercased() {
        case "http", "https":
            return !(url.host ?? "").isEmpty
        case "mailto":
            return url.absoluteString.count > "mailto:".count
        default:
            return false
        }
    }

    // MARK: - Attributed text

    /// `text` unchanged, with `.link` on each detected range. Memoized: the
    /// reading pane asks again on every view update.
    static func attributed(_ text: String) -> AttributedString {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = buildAttributed(text)
        cache.setObject(Box(value), forKey: key, cost: key.length)
        return value
    }

    private static func buildAttributed(_ text: String) -> AttributedString {
        let found = links(in: text)
        guard !found.isEmpty else { return AttributedString(text) }
        let ns = text as NSString
        var out = AttributedString()
        var cursor = 0
        for link in found {
            if link.range.location > cursor {
                out.append(AttributedString(ns.substring(
                    with: NSRange(location: cursor, length: link.range.location - cursor))))
            }
            var piece = AttributedString(ns.substring(with: link.range))
            piece.link = link.url
            out.append(piece)
            cursor = NSMaxRange(link.range)
        }
        if cursor < ns.length {
            out.append(AttributedString(ns.substring(from: cursor)))
        }
        return out
    }

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 32
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    // MARK: - Opening

    /// The URL to hand to the system for a clicked link, or nil to keep the
    /// click inert. Same scheme allow-list as `ExternalLinkRecovery`, without
    /// its schemeless-host recovery: every link here was built with a scheme.
    static func externalURL(for url: URL) -> URL? {
        allowedSchemes.contains((url.scheme ?? "").lowercased()) ? url : nil
    }
}
