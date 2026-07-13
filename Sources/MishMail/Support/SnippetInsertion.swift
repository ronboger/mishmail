import Foundation

/// Pure recipient/trigger logic behind snippet insertion, kept out of the
/// SwiftUI layer so it can be unit-tested: the move-to-bcc shuffle (intro
/// etiquette) and detection of an active `/query` slash trigger in the body.
enum SnippetInsertion {
    struct Recipients: Equatable {
        var to: [String]
        var cc: [String]
        var bcc: [String]
    }

    /// Intro etiquette: everyone in To (the introducer) moves to Bcc, and Cc
    /// (the person being introduced) is promoted to To. Existing Bcc entries
    /// are kept; duplicates are dropped case-insensitively.
    static func moveToBcc(to: [String], cc: [String], bcc: [String]) -> Recipients {
        var newBcc = bcc
        var inBcc = Set(bcc.map { $0.lowercased() })
        for addr in to where inBcc.insert(addr.lowercased()).inserted {
            newBcc.append(addr)
        }
        var newTo: [String] = []
        var inTo = Set<String>()
        for addr in cc where !inBcc.contains(addr.lowercased())
            && inTo.insert(addr.lowercased()).inserted {
            newTo.append(addr)
        }
        return Recipients(to: newTo, cc: [], bcc: newBcc)
    }

    struct SlashToken: Equatable {
        /// Range of the whole token (`/` through the caret) — replace this
        /// with the expanded snippet, leaving any text after the caret alone.
        var range: Range<String.Index>
        /// What the user typed after the `/`, used to filter snippets.
        var query: String
    }

    /// An active slash trigger ending at `caret` (or at the end of `text` when
    /// caret is nil): a `/` at the start of the text or right after whitespace,
    /// with everything from after it up to the caret as the query.
    ///
    /// Caret-based so `/` works mid-message and more than once per compose —
    /// the old end-of-text rule silently failed whenever anything followed the
    /// query (or a prior snippet left a trailing newline below the caret).
    /// Slashes inside words or URLs don't trigger. Any whitespace in the query
    /// ends the trigger (Space/Tab/Return dismiss the picker; typed text stays).
    static func slashToken(in text: String, atCaret caret: String.Index? = nil) -> SlashToken? {
        let end = caret ?? text.endIndex
        guard end >= text.startIndex, end <= text.endIndex else { return nil }
        let prefix = text[..<end]
        guard let slash = prefix.lastIndex(of: "/") else { return nil }
        if slash > text.startIndex {
            let prev = text[text.index(before: slash)]
            guard prev == " " || prev == "\n" || prev == "\t" else { return nil }
        }
        let query = text[text.index(after: slash)..<end]
        // Space (and any other whitespace) ends the token — same as newline.
        // Keeps `/name` filtering single-token and lets the user dismiss the
        // picker by typing a space without Esc.
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return SlashToken(range: slash..<end, query: String(query))
    }

    /// UTF-16 convenience for NSTextView caret locations.
    static func slashToken(in text: String, caretUTF16: Int) -> SlashToken? {
        let ns = text as NSString
        let clamped = max(0, min(caretUTF16, ns.length))
        guard let end = Range(NSRange(location: 0, length: clamped), in: text)?.upperBound else {
            return slashToken(in: text, atCaret: text.endIndex)
        }
        return slashToken(in: text, atCaret: end)
    }
}
