import Foundation

/// Pure contact-ranking logic mined from message headers. Kept free of DB/UI
/// so unit tests can drive incremental merges without GRDB.
enum ContactMiner {
    struct Contact: Identifiable, Hashable {
        let name: String
        let email: String
        let weight: Int
        var id: String { email }
        var display: String { name.isEmpty ? email : "\(name) — \(email)" }
    }

    /// email → (best display name, cumulative weight, whether name was seen on From)
    typealias WeightMap = [String: (name: String, weight: Int, nameFromSelf: Bool)]

    /// One message's address headers + SQLite rowid for high-water marks.
    struct MessageHeaders: Equatable {
        var rowid: Int64
        var fromHeader: String
        var toHeader: String
        var ccHeader: String
        var labelIds: String
    }

    /// True when `name` is a real human display name for `email` — not empty,
    /// not the address itself (any casing), and not email-shaped (`@` present).
    /// Bare From headers like `John@ormoni.bio` parse as displayName == email;
    /// those must not poison greetings or contact chips.
    static func isUsableDisplayName(_ name: String, email: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return false }
        if n.contains("@") { return false }
        if n.caseInsensitiveCompare(email) == .orderedSame { return false }
        return true
    }

    /// True when `longer` looks like `shorter` with 1–2 non-space characters
    /// glued on the front (e.g. `"jJoshua Yang"` vs `"Joshua Yang"`). Titles
    /// like `"Dr "` are three characters and are not treated as typos.
    /// Counts use case-folded strings so Unicode lowercasing cannot desync
    /// `extra` from the suffix check (e.g. `İ` → multi-scalar `i̇`).
    static func isLikelyTypoPrefix(longer: String, shorter: String) -> Bool {
        let lFold = longer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sFold = shorter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lFold.count > sFold.count else { return false }
        let extra = lFold.count - sFold.count
        guard (1...2).contains(extra) else { return false }
        guard lFold.hasSuffix(sFold) else { return false }
        let prefix = lFold.dropLast(sFold.count)
        return !prefix.contains(where: \.isWhitespace)
    }

    /// Choose which display name to keep. From-header names beat To/Cc (self-
    /// identification over third-party address-book typos). Same tier: reject
    /// likely glued prefixes, then prefer the longer usable name.
    static func preferredName(
        current: String, currentFromSelf: Bool,
        candidate: String, candidateFromSelf: Bool
    ) -> (name: String, fromSelf: Bool) {
        if candidate.isEmpty {
            return (current, currentFromSelf)
        }
        if current.isEmpty {
            return (candidate, candidateFromSelf)
        }
        // Same name (any casing): promote to From-sourced if either was.
        if current.caseInsensitiveCompare(candidate) == .orderedSame {
            return (currentFromSelf ? current : candidate,
                    currentFromSelf || candidateFromSelf)
        }
        if candidateFromSelf && !currentFromSelf {
            return (candidate, true)
        }
        if currentFromSelf && !candidateFromSelf {
            return (current, true)
        }
        if isLikelyTypoPrefix(longer: candidate, shorter: current) {
            return (current, currentFromSelf)
        }
        if isLikelyTypoPrefix(longer: current, shorter: candidate) {
            return (candidate, candidateFromSelf)
        }
        if candidate.count > current.count {
            return (candidate, candidateFromSelf)
        }
        return (current, currentFromSelf)
    }

    /// Merge `messages` into `weights`. Returns the max rowid seen (0 if empty).
    /// Sent mail (`labelIds` contains `SENT`) counts +5; everything else +1.
    /// Prefers From-header names over To/Cc, then longer usable names (rejecting
    /// glued typo prefixes). Skips own addresses and junk tokens. Email-shaped
    /// "names" are stored as empty so ranking stays clean.
    @discardableResult
    static func merge(messages: [MessageHeaders],
                      into weights: inout WeightMap,
                      excluding ownAddresses: Set<String>) -> Int64 {
        var maxRowId: Int64 = 0
        for msg in messages {
            if msg.rowid > maxRowId { maxRowId = msg.rowid }
            let isSent = msg.labelIds.contains("SENT")
            let headers: [(String, Bool)] = [
                (msg.fromHeader, true),
                (msg.toHeader, false),
                (msg.ccHeader, false),
            ]
            for (header, isFrom) in headers {
                for piece in MessageParser.splitAddresses(header) {
                    let email = MessageParser.emailAddress(piece).lowercased()
                    guard email.contains("@"), !email.contains(" "),
                          !ownAddresses.contains(email) else { continue }
                    let raw = MessageParser.displayName(fromHeader: piece)
                    let name = isUsableDisplayName(raw, email: email) ? raw : ""
                    let add = isSent ? 5 : 1
                    let prev = weights[email] ?? ("", 0, false)
                    let chosen = preferredName(
                        current: prev.name, currentFromSelf: prev.nameFromSelf,
                        candidate: name, candidateFromSelf: isFrom && !name.isEmpty)
                    weights[email] = (chosen.name, prev.weight + add, chosen.fromSelf)
                }
            }
        }
        return maxRowId
    }

    /// Top contacts by weight (desc), capped for the published suggestion list.
    /// Scrubs email-shaped / email-equal names left from older weight maps so
    /// a full rebuild isn't required for the greeting fix to take effect.
    static func ranked(from weights: WeightMap, limit: Int = 2000) -> [Contact] {
        Array(
            weights
                .map { email, value in
                    let name = isUsableDisplayName(value.name, email: email)
                        ? value.name : ""
                    return Contact(name: name, email: email, weight: value.weight)
                }
                .sorted { $0.weight > $1.weight }
                .prefix(limit)
        )
    }

    /// Prefix/substring match for live search and address fields.
    /// Pure + allocation-light: lowercases the query once, scans email as-is
    /// (emails are stored lowercased) and only lowercases `name` when needed.
    static func suggestions(from contacts: [Contact], matching query: String,
                            limit: Int = 6) -> [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var out: [Contact] = []
        out.reserveCapacity(limit)
        for c in contacts {
            if c.email.contains(q) {
                out.append(c)
            } else if !c.name.isEmpty, c.name.lowercased().contains(q) {
                out.append(c)
            }
            if out.count >= limit { break }
        }
        return out
    }
}
