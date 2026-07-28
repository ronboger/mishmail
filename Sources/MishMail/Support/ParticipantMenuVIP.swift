import Foundation

/// Whether the participant (sender/recipient) click menu should offer
/// Add/Remove VIP for a given address. Mirrors the thread-list context
/// menu, but lives here so the message-header menu and tests share one
/// rule: never VIP your own accounts, only addresses that look real.
enum ParticipantMenuVIP {
    enum Action: Equatable {
        case add(email: String)
        case remove(email: String)
    }

    /// - Parameters:
    ///   - email: Raw address from a From/To/Cc header (any case).
    ///   - vipEmails: Lowercased VIP set from `MailStore.vipEmails`.
    ///   - ownEmails: Lowercased account ids / aliases that belong to the user.
    /// - Returns: `nil` when the address is own, empty, or not an email.
    static func action(email: String,
                       vipEmails: Set<String>,
                       ownEmails: Set<String>) -> Action? {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard e.contains("@"), e.contains(".") else { return nil }
        if ownEmails.contains(e) { return nil }
        if vipEmails.contains(e) {
            return .remove(email: e)
        }
        return .add(email: e)
    }

    static func title(for action: Action) -> String {
        switch action {
        case .add(let email): return "Add \(email) to VIPs"
        case .remove(let email): return "Remove \(email) from VIPs"
        }
    }

    static func systemImage(for action: Action) -> String {
        switch action {
        case .add: return "star.circle"
        case .remove: return "star.circle.fill"
        }
    }
}
