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

    /// email → (best display name, cumulative weight)
    typealias WeightMap = [String: (name: String, weight: Int)]

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

    /// Merge `messages` into `weights`. Returns the max rowid seen (0 if empty).
    /// Sent mail (`labelIds` contains `SENT`) counts +5; everything else +1.
    /// Prefers the longer *usable* display name; skips own addresses and junk
    /// tokens. Email-shaped "names" are stored as empty so ranking stays clean.
    @discardableResult
    static func merge(messages: [MessageHeaders],
                      into weights: inout WeightMap,
                      excluding ownAddresses: Set<String>) -> Int64 {
        var maxRowId: Int64 = 0
        for msg in messages {
            if msg.rowid > maxRowId { maxRowId = msg.rowid }
            let isSent = msg.labelIds.contains("SENT")
            for header in [msg.fromHeader, msg.toHeader, msg.ccHeader] {
                for piece in MessageParser.splitAddresses(header) {
                    let email = MessageParser.emailAddress(piece).lowercased()
                    guard email.contains("@"), !email.contains(" "),
                          !ownAddresses.contains(email) else { continue }
                    let raw = MessageParser.displayName(fromHeader: piece)
                    let name = isUsableDisplayName(raw, email: email) ? raw : ""
                    let add = isSent ? 5 : 1
                    let prev = weights[email] ?? ("", 0)
                    // Prefer longer usable names; never let an empty "win" over
                    // a prior real name (count 0 would otherwise replace).
                    let bestName: String
                    if name.isEmpty {
                        bestName = prev.name
                    } else if prev.name.isEmpty || name.count > prev.name.count {
                        bestName = name
                    } else {
                        bestName = prev.name
                    }
                    weights[email] = (bestName, prev.weight + add)
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
