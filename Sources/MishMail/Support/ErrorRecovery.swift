import Foundation

enum ErrorRecoveryAction: Equatable {
    case retrySync
    case reauthorize
}

struct PresentedError: Equatable {
    let message: String
    let recovery: ErrorRecoveryAction
}

enum ErrorRecovery {
    static func retry(_ message: String) -> PresentedError {
        PresentedError(message: message, recovery: .retrySync)
    }

    static func reauthorizationRequired(for accountID: String) -> PresentedError {
        PresentedError(
            message: "\(accountID): needs to be reauthorized (Settings → Accounts).",
            recovery: .reauthorize)
    }
}
