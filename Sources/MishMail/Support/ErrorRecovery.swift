import Foundation

enum ErrorRecoveryAction: Equatable {
    case none
    case retrySync
    case reauthorize
}

struct PresentedError: Equatable {
    let message: String
    let recovery: ErrorRecoveryAction
    var accountID: String? = nil
}

enum ErrorRecovery {
    static func none(_ message: String) -> PresentedError {
        PresentedError(message: message, recovery: .none)
    }

    /// Explicit sync-retry presentation used by focused tests and callers
    /// that already know the error came from a sync operation.
    static func retry(_ message: String, accountID: String) -> PresentedError {
        PresentedError(message: message, recovery: .retrySync, accountID: accountID)
    }

    static func reauthorizationRequired(for accountID: String) -> PresentedError {
        PresentedError(
            message: "\(accountID): needs to be reauthorized (Settings → Accounts).",
            recovery: .reauthorize, accountID: accountID)
    }
}
