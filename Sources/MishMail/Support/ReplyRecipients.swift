import Foundation

/// Who a Reply / Reply All goes to. One rule for the compose prefill and for
/// the Reply All button, so the button shows exactly when Reply All would
/// add someone.
///
/// Follows gmail.com:
/// - Reply goes to `Reply-To` when the header has an address, else to `From`.
/// - A reply to your own message goes to the people you wrote to. `Reply-To`
///   is ignored there (it is your own send-as setting, not a recipient).
/// - Reply All keeps that To and puts the original To and Cc in Cc, without
///   your own addresses and without anyone already in To.
enum ReplyRecipients {
    struct Result: Equatable {
        var to: [String]
        var cc: [String]
    }

    /// - Parameters:
    ///   - replyTo: raw `Reply-To` value. nil (row older than v43, not yet
    ///     recorded) and empty (parsed, no header) both mean "use From".
    ///   - ownAddresses: account addresses and send-as aliases, any case.
    /// - Returns: bare addresses in header order, de-duplicated without
    ///   regard to case. `cc` is empty unless `replyAll`.
    static func compute(from: String, replyTo: String?, to: String, cc: String,
                        ownAddresses: Set<String>, replyAll: Bool) -> Result {
        let own = Set(ownAddresses.map { $0.lowercased() })
        let sender = MessageParser.emailAddress(from)

        var targets: [String]
        if own.contains(sender.lowercased()) {
            targets = addresses(in: to).filter { !own.contains($0.lowercased()) }
            // Genuinely a note to self.
            if targets.isEmpty { targets = [sender] }
        } else {
            targets = addresses(in: replyTo ?? "")
            if targets.isEmpty { targets = [sender] }
        }
        targets = unique(targets)
        guard replyAll else { return Result(to: targets, cc: []) }

        let taken = Set(targets.map { $0.lowercased() })
        let others = addresses(in: to + "," + cc).filter {
            !own.contains($0.lowercased()) && !taken.contains($0.lowercased())
        }
        return Result(to: targets, cc: unique(others))
    }

    static func compute(for message: Message, ownAddresses: Set<String>,
                        replyAll: Bool) -> Result {
        compute(from: message.fromHeader, replyTo: message.replyToHeader,
                to: message.toHeader, cc: message.ccHeader,
                ownAddresses: ownAddresses, replyAll: replyAll)
    }

    private static func addresses(in header: String) -> [String] {
        MessageParser.splitAddresses(header)
            .map { MessageParser.emailAddress($0) }
            .filter { $0.contains("@") }
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.lowercased()).inserted }
    }
}
