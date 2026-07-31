import Foundation

/// Bidirectional text helpers for Hebrew/Arabic ↔ English compose.
///
/// MishMail is mostly LTR, but mixed RTL paragraphs (Hebrew + URLs/IDs) need:
/// 1. A paragraph **base direction** (HTML `dir=auto` / first strong char)
/// 2. **Isolation** of embedded LTR runs (URLs, bare hosts, phones) so UBA
///    does not shred them
///
/// Pure Foundation — no AppKit — so unit tests cover detection and HTML attrs.
///
/// Coverage is intentional, not complete UAX #9: Latin/Greek/Cyrillic and
/// Hebrew/Arabic families are strong; CJK and other scripts are treated as
/// neutral (they rarely set compose direction for this app's user base).
enum TextDirection: Equatable {
    case ltr
    case rtl
    case neutral

    // MARK: - Base direction (HTML dir=auto)

    /// First strong directional character wins (same rule as HTML `dir=auto`).
    static func base(of string: String) -> TextDirection {
        for scalar in string.unicodeScalars {
            if isStrongRTL(scalar) { return .rtl }
            if isStrongLTR(scalar) { return .ltr }
        }
        return .neutral
    }

    /// HTML `dir` value for authored content. Neutral / empty defaults to
    /// `ltr` (matches Gmail's default wrapper for English-first clients).
    static func htmlDir(of string: String) -> String {
        switch base(of: string) {
        case .rtl: return "rtl"
        case .ltr, .neutral: return "ltr"
        }
    }

    /// True when the string's base direction is right-to-left.
    static func isRTL(_ string: String) -> Bool {
        base(of: string) == .rtl
    }

    // MARK: - Shared bare-URL pattern (ComposeLinks / Markdown / isolate)

    /// Bare `http(s)://` / `mailto:` matcher. Single compiled regex so
    /// isolate ranges and linkify cannot drift.
    static let bareURLRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?i)\b((?:https?://|mailto:)[^\s<>\[\]()\"']+)"#)
    }()

    /// Characters trimmed from the end of a bare-URL / host match so trailing
    /// prose punctuation stays outside the isolate / anchor.
    static let trailingURLPunctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'")

    // MARK: - LTR spans to isolate

    /// Kind of LTR run isolated inside RTL prose.
    enum IsolateKind: Equatable {
        /// `http(s)://` / `mailto:` (and autolinkable bare hosts).
        case url
        /// Domain-like token without scheme (isolate always; linkify when safe).
        case host
        /// Phone / long ID with separators that UBA otherwise reorders.
        case phone
    }

    struct IsolateSpan: Equatable {
        let range: NSRange
        let kind: IsolateKind
    }

    /// Conservative bare-host: `label(.label)+.tld` with optional `:port` / path.
    /// TLD is letters only (rejects `v1.0`); common file extensions are skipped
    /// so `README.md` is not treated as a domain.
    private static let bareHostRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?i)\b((?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24})(?::\d{2,5})?(?:/[^\s<>\[\]()\"']*)?"#)
    }()

    /// File-extension denylist for bare-host false positives.
    private static let hostTLDDenylist: Set<String> = [
        "txt", "md", "pdf", "png", "jpg", "jpeg", "gif", "svg", "webp",
        "zip", "gz", "tgz", "rar", "7z", "tar", "bz2",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv",
        "mp3", "mp4", "mov", "avi", "mkv", "wav",
        "js", "ts", "tsx", "jsx", "css", "scss", "html", "htm", "xml", "json",
        "swift", "py", "rb", "go", "rs", "c", "h", "cpp", "java", "kt",
        "log", "lock", "yml", "yaml", "toml", "ini", "cfg", "conf",
    ]

    /// Phone / ID-like: optional `+`, digits with spaces / dashes / dots / parens.
    /// Requires ≥7 digits so short numbers stay weak (UBA handles "2028606" OK).
    private static let phoneRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<![\w])(\+?\d[\d\s().-]{5,}\d)"#)
    }()

    /// UTF-16 ranges of LTR runs to isolate in RTL paragraphs (compose
    /// highlighter + HTML plain spans). Non-overlapping, sorted by location.
    ///
    /// Priority when ranges collide: scheme URL > bare host > phone.
    static func ltrIsolateSpans(in string: String) -> [IsolateSpan] {
        guard !string.isEmpty else { return [] }
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var candidates: [IsolateSpan] = []

        func trimTrailing(_ range: NSRange) -> NSRange? {
            var r = range
            while r.length > 0 {
                let last = ns.character(at: r.location + r.length - 1)
                guard let scalar = Unicode.Scalar(last),
                      trailingURLPunctuation.contains(scalar) else { break }
                r.length -= 1
            }
            return r.length > 0 ? r : nil
        }

        bareURLRegex.enumerateMatches(in: string, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                  let r = trimTrailing(match.range(at: 1)) else { return }
            candidates.append(IsolateSpan(range: r, kind: .url))
        }

        bareHostRegex.enumerateMatches(in: string, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                  let r = trimTrailing(match.range(at: 1)) else { return }
            let text = ns.substring(with: r)
            guard isPlausibleBareHost(text) else { return }
            candidates.append(IsolateSpan(range: r, kind: .host))
        }

        phoneRegex.enumerateMatches(in: string, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            // Trim only prose punctuation — keep phone separators - ( ) .
            var r = match.range(at: 1)
            while r.length > 0 {
                let last = ns.character(at: r.location + r.length - 1)
                guard let scalar = Unicode.Scalar(last) else { break }
                let ch = Character(scalar)
                if ",;:!?)]}\"'".contains(ch) {
                    r.length -= 1
                    continue
                }
                // Trailing period only when not part of a digit.digit sequence
                // already ended (prose "call me 555-1234.")
                if ch == "." {
                    r.length -= 1
                    continue
                }
                break
            }
            guard r.length > 0 else { return }
            let text = ns.substring(with: r)
            guard digitCount(in: text) >= 7 else { return }
            candidates.append(IsolateSpan(range: r, kind: .phone))
        }

        // Resolve overlaps: keep higher-priority kind, then longer, then earlier.
        let priority: [IsolateKind: Int] = [.url: 3, .host: 2, .phone: 1]
        let sorted = candidates.sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length > $1.range.length
        }
        var accepted: [IsolateSpan] = []
        for span in sorted {
            if accepted.contains(where: { rangesOverlap($0.range, span.range) }) {
                // Prefer higher priority already-accepted; skip if lower.
                if let idx = accepted.firstIndex(where: { rangesOverlap($0.range, span.range) }) {
                    let existing = accepted[idx]
                    let pNew = priority[span.kind] ?? 0
                    let pOld = priority[existing.kind] ?? 0
                    if pNew > pOld
                        || (pNew == pOld && span.range.length > existing.range.length) {
                        accepted[idx] = span
                    }
                }
                continue
            }
            accepted.append(span)
        }
        return accepted.sorted { $0.range.location < $1.range.location }
    }

    /// Convenience: ranges only (compose highlighter).
    static func ltrIsolateNSRanges(in string: String) -> [NSRange] {
        ltrIsolateSpans(in: string).map(\.range)
    }

    /// Whether `host` (optional path/port) is safe to treat as a domain.
    static func isPlausibleBareHost(_ raw: String) -> Bool {
        var s = raw
        // Strip path for TLD check.
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        // Strip port.
        if let colon = s.lastIndex(of: ":"),
           s[s.index(after: colon)...].allSatisfy(\.isNumber) {
            s = String(s[..<colon])
        }
        let labels = s.split(separator: ".")
        guard labels.count >= 2 else { return false }
        let tld = String(labels.last!).lowercased()
        guard tld.count >= 2, tld.unicodeScalars.allSatisfy({
            ($0.value >= 0x61 && $0.value <= 0x7A) // a-z
        }) else { return false }
        if hostTLDDenylist.contains(tld) { return false }
        // Reject single-letter second-level like "i.e" if only two labels and
        // first is one char — but "i.e" fails TLD length if "e". "a.co" is OK.
        return true
    }

    private static func digitCount(in s: String) -> Int {
        s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
    }

    private static func rangesOverlap(_ a: NSRange, _ b: NSRange) -> Bool {
        let aEnd = a.location + a.length
        let bEnd = b.location + b.length
        return a.location < bEnd && b.location < aEnd
    }

    // MARK: - Paragraph / blank-line blocks (HTML dir + spacing)

    /// A blank-line-separated text block or a run of empty lines.
    enum Block: Equatable {
        /// Non-empty paragraph (may contain single newlines between lines).
        case paragraph(String)
        /// One or more consecutive blank lines (after whitespace trim).
        case blanks(Int)
    }

    /// Split text into paragraphs and blank-line runs.
    /// Whitespace-only lines count as blank. Leading/trailing blank runs are kept
    /// so multi-blank fidelity can be preserved for HTML.
    static func blocks(in text: String) -> [Block] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Drop a single trailing empty line so "para\n" is one paragraph
        // (editor often ends with a newline without meaning an extra blank).
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        if lines.isEmpty { return [] }

        var out: [Block] = []
        var buf: [String] = []
        var blankRun = 0

        func flushPara() {
            guard !buf.isEmpty else { return }
            out.append(.paragraph(buf.joined(separator: "\n")))
            buf = []
        }
        func flushBlanks() {
            guard blankRun > 0 else { return }
            out.append(.blanks(blankRun))
            blankRun = 0
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushPara()
                blankRun += 1
            } else {
                flushBlanks()
                buf.append(line)
            }
        }
        flushPara()
        flushBlanks()
        return out
    }

    /// Blank-line-separated paragraphs only (empty input → `[]`).
    /// Blank runs are dropped; use `blocks(in:)` when spacing fidelity matters.
    static func paragraphs(in text: String) -> [String] {
        blocks(in: text).compactMap {
            if case .paragraph(let p) = $0 { return p }
            return nil
        }
    }

    // MARK: - Strong character classification

    /// Strong RTL: Hebrew, Arabic, and related presentation forms.
    static func isStrongRTL(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF: return true  // Hebrew
        case 0x0600...0x06FF: return true  // Arabic
        case 0x0700...0x074F: return true  // Syriac
        case 0x0750...0x077F: return true  // Arabic Supplement
        case 0x0780...0x07BF: return true  // Thaana
        case 0x07C0...0x07FF: return true  // NKo
        case 0x0800...0x083F: return true  // Samaritan
        case 0x0840...0x085F: return true  // Mandaic
        case 0x08A0...0x08FF: return true  // Arabic Extended-A
        case 0xFB1D...0xFDFF: return true  // Alphabetic Presentation Forms / Arabic PF-A
        case 0xFE70...0xFEFF: return true  // Arabic Presentation Forms-B
        default: return false
        }
    }

    /// Strong LTR: Latin letters (ASCII + common Latin extensions), Greek,
    /// Cyrillic. Digits are weak and do not set base direction.
    ///
    /// CJK / Hangul / Devanagari etc. are intentionally **not** strong here —
    /// full UAX #9 would treat many as L; we only need Hebrew↔English for
    /// compose quality.
    static func isStrongLTR(_ scalar: Unicode.Scalar) -> Bool {
        if isStrongRTL(scalar) { return false }
        let v = scalar.value
        // Basic Latin letters
        if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { return true }
        // Latin-1 Supplement letters (À-ö, ø-ÿ) — skip × ÷
        if (0xC0...0xD6).contains(v) || (0xD8...0xF6).contains(v)
            || (0xF8...0xFF).contains(v) { return true }
        // Latin Extended-A / B
        if (0x0100...0x024F).contains(v) { return true }
        // Common LTR scripts used in mail (Cyrillic, Greek)
        if (0x0370...0x03FF).contains(v) { return true }  // Greek
        if (0x0400...0x04FF).contains(v) { return true }  // Cyrillic
        return false
    }
}
