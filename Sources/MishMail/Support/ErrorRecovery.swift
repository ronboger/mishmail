import Foundation

enum ErrorRecoveryAction: Equatable {
    case retrySync
    case reauthorize
}

enum ErrorRecovery {
    /// A stale reauth flag for some other account must not replace the retry
    /// action for the error currently on screen.
    static func action(for error: String,
                       accountsNeedingReauth: Set<String>) -> ErrorRecoveryAction {
        let message = error.lowercased()
        let namesAffectedAccount = accountsNeedingReauth.contains {
            message.contains($0.lowercased())
        }
        return namesAffectedAccount && message.contains("reauthor")
            ? .reauthorize
            : .retrySync
    }
}
