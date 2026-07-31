import Foundation

/// Bidirectional text helpers for Hebrew/Arabic ↔ English compose.
///
/// MishMail is mostly LTR, but mixed RTL paragraphs (Hebrew + URLs/IDs) need:
/// 1. A paragraph **base direction** (HTML `dir=auto` / first strong char)
/// 2. **Isolation** of embedded LTR runs (URLs) so UBA does not shred them
///
/// Pure Foundation — no AppKit — so unit tests cover detection and HTML attrs.
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

    // MARK: - LTR spans to isolate

    /// UTF-16 ranges of bare `http(s)://` / `mailto:` URLs that should be
    /// LTR-isolated inside an RTL paragraph (compose highlighter + HTML).
    ///
    /// Trailing prose punctuation (`.`, `,`, …) is excluded, matching
    /// `ComposeLinks` bare-URL trimming so isolate bounds stay consistent
    /// with the linkified HTML alternative.
    static func ltrIsolateNSRanges(in string: String) -> [NSRange] {
        guard !string.isEmpty,
              let re = try? NSRegularExpression(
                pattern: #"(?i)\b((?:https?://|mailto:)[^\s<>\[\]()\"']+)"#)
        else { return [] }
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [NSRange] = []
        re.enumerateMatches(in: string, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            var range = match.range(at: 1)
            guard range.location != NSNotFound, range.length > 0 else { return }
            // Drop trailing punctuation commonly stuck to URLs in prose.
            while range.length > 0 {
                let last = ns.character(at: range.location + range.length - 1)
                guard let scalar = Unicode.Scalar(last),
                      ".,;:!?)]}\"'".unicodeScalars.contains(scalar) else { break }
                range.length -= 1
            }
            if range.length > 0 { out.append(range) }
        }
        return out
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

    /// Strong LTR: Latin letters (ASCII + common Latin extensions). Digits are
    /// weak and do not set base direction (so "2028606" alone stays neutral).
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
