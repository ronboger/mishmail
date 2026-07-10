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
        /// Range of the whole token (`/` through end of text) — replace this
        /// with the expanded snippet.
        var range: Range<String.Index>
        /// What the user typed after the `/`, used to filter snippets.
        var query: String
    }

    /// An active slash trigger: a `/` at the start of the text or right after
    /// whitespace, with everything after it (no newline yet) as the query.
    /// Slashes inside words or URLs don't trigger.
    static func slashToken(in text: String) -> SlashToken? {
        guard let slash = text.lastIndex(of: "/") else { return nil }
        if slash > text.startIndex {
            let prev = text[text.index(before: slash)]
            guard prev == " " || prev == "\n" || prev == "\t" else { return nil }
        }
        let query = text[text.index(after: slash)...]
        guard !query.contains("\n") else { return nil }
        return SlashToken(range: slash..<text.endIndex, query: String(query))
    }
}
