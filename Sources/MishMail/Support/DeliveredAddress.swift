import Foundation

/// Which of the user's own addresses a received message reached.
///
/// A Bcc, mailing-list, or forwarded message often names none of the user's
/// addresses in To / Cc ("undisclosed-recipients:;", a list address). The
/// `Delivered-To` chain still records it. Gmail prepends one value per local
/// delivery hop, so the LAST value is the address the sender's mail first
/// arrived at (a send-as alias or a forwarding domain) and the first value
/// is the Gmail mailbox itself.
enum DeliveredAddress {
    enum Source: Equatable {
        /// Named in To or Cc — the reading pane already shows it.
        case to, cc
        /// Named in Bcc (only present on mail the user sent).
        case bcc
        /// Only the `Delivered-To` chain names it.
        case delivered
        /// Nothing names it; the owning mailbox is the best guess.
        case mailbox
    }

    struct Result: Equatable {
        /// Lowercased address.
        let email: String
        let source: Source

        /// True when To / Cc do not already show this address, so the
        /// reading pane needs its own "delivered to" row.
        var needsOwnRow: Bool { source != .to && source != .cc }
    }

    static func resolve(toHeader: String, ccHeader: String, bccHeader: String,
                        deliveredTo: String?, ownEmails: Set<String>,
                        accountId: String) -> Result {
        let primary = accountId.lowercased()
        var own = Set(ownEmails.map { $0.lowercased() })
        own.insert(primary)

        for (header, source) in [(toHeader, Source.to), (ccHeader, .cc), (bccHeader, .bcc)] {
            for raw in MessageParser.splitAddresses(header) {
                let email = MessageParser.emailAddress(raw).lowercased()
                if own.contains(email) { return Result(email: email, source: source) }
            }
        }

        // Oldest hop first: the address the sender's mail first arrived at.
        let chain = chainAddresses(deliveredTo).reversed()
        if let alias = chain.first(where: { own.contains($0) && $0 != primary }) {
            return Result(email: alias, source: .delivered)
        }
        if let oldest = chain.first {
            return Result(email: oldest, source: .delivered)
        }
        return Result(email: primary, source: .mailbox)
    }

    static func resolve(_ message: Message, ownEmails: Set<String>) -> Result {
        resolve(toHeader: message.toHeader, ccHeader: message.ccHeader,
                bccHeader: message.bccHeader, deliveredTo: message.deliveredTo,
                ownEmails: ownEmails, accountId: message.accountId)
    }

    /// Lowercased addresses from the stored chain, newest hop first.
    static func chainAddresses(_ deliveredTo: String?) -> [String] {
        MessageParser.splitAddresses(deliveredTo ?? "")
            .map { MessageParser.emailAddress($0).lowercased() }
            .filter { $0.contains("@") }
    }

    /// Address a reply should be sent from, Gmail's "reply from the same
    /// address the message was sent to": the own sender of the original
    /// (replying to own mail), else the own address it reached. Nil when
    /// only the mailbox fallback is known.
    static func replyFromEmail(for message: Message, ownEmails: Set<String>) -> String? {
        var own = Set(ownEmails.map { $0.lowercased() })
        own.insert(message.accountId.lowercased())
        let sender = MessageParser.emailAddress(message.fromHeader).lowercased()
        if own.contains(sender) { return sender }
        let result = resolve(message, ownEmails: ownEmails)
        guard result.source != .mailbox, own.contains(result.email) else { return nil }
        return result.email
    }
}
