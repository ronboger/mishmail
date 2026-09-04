import Foundation

/// Pure helpers behind `MailStore.mailboxForCorrespondents`: which addresses
/// from a `mailto:` are worth looking up, how to quote them for a `LIKE`
/// prefilter, and whether a candidate row really corresponds with them.
enum MailtoSender {

    /// One candidate row from the correspondent query.
    struct Candidate: Equatable {
        var accountId: String
        var fromHeader: String
        var toHeader: String
        var ccHeader: String
        var labelIds: String
    }

    /// Lowercased, de-duplicated recipient addresses that are real emails
    /// and not one of the user's own (mailing yourself says nothing about
    /// which mailbox to send from). Order is preserved.
    static func lookupAddresses(_ addresses: [String], own: Set<String>) -> [String] {
        let ownLower = Set(own.map { $0.lowercased() })
        var seen = Set<String>()
        var out: [String] = []
        for raw in addresses {
            let email = MessageParser.emailAddress(raw).lowercased()
            guard email.contains("@"), !email.contains(" "),
                  !ownLower.contains(email),
                  seen.insert(email).inserted else { continue }
            out.append(email)
        }
        return out
    }

    /// Escape `LIKE` metacharacters so `a_b%c@x.com` matches literally.
    /// Pairs with `ESCAPE '\'` in the query.
    static func likeEscaped(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Mailbox for the newest candidate that genuinely corresponds with one
    /// of `addresses`. `candidates` must already be newest-first.
    ///
    /// The SQL prefilter is a substring `LIKE`, so it also returns rows where
    /// the address is only a suffix of a longer one (`gabe@x.com` for a lookup
    /// of `abe@x.com`). Each header is re-parsed into whole addresses here so
    /// only an exact match counts. Spam and deleted mail are skipped for the
    /// same reason `ContactMiner` skips them: Gmail caches both locally, and
    /// an unsolicited message is not evidence of correspondence.
    static func mailbox(matching addresses: [String],
                        in candidates: [Candidate]) -> String? {
        let wanted = Set(addresses.map { $0.lowercased() })
        guard !wanted.isEmpty else { return nil }
        for row in candidates {
            guard ContactMiner.isEligibleForContacts(
                .init(rowid: 0, fromHeader: row.fromHeader, toHeader: row.toHeader,
                      ccHeader: row.ccHeader, labelIds: row.labelIds))
            else { continue }
            let headers = [row.fromHeader, row.toHeader, row.ccHeader]
            let addressesInRow = headers.flatMap { header in
                MessageParser.splitAddresses(header).map {
                    MessageParser.emailAddress($0).lowercased()
                }
            }
            if addressesInRow.contains(where: { wanted.contains($0) }) {
                return row.accountId
            }
        }
        return nil
    }
}
