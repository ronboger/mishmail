import Foundation

/// What a failed Gmail write means for work that is queued to replay
/// (scheduled sends, queued draft deletes). Pure so the rules are tested.
///
/// The split that matters is "Gmail said no" versus "we do not know what
/// Gmail did". Only a clear 4xx verdict is `permanent`; everything else
/// leaves the outcome open and must be retried behind the caller's own
/// idempotency check rather than reported as a rejection.
enum RemoteFailureKind: Equatable {
    /// No network. The whole pass stops; the reconnect edge retries.
    case offline
    /// The account's saved sign-in is dead. Only the user can fix it.
    case reauth
    /// Rate limit, server error, or an outcome we cannot read (cancelled
    /// request, locked Keychain, undecodable response). Retry later.
    case retryable
    /// Gmail rejected the request itself. A retry would fail the same way.
    case permanent

    static func classify(_ error: Error) -> RemoteFailureKind {
        if TransientNetworkError.isTransient(error) { return .offline }
        if AccountLifecycle.isReauthRequired(error) { return .reauth }
        guard let gmail = error as? GmailError, case .http(let code, let body) = gmail else {
            return .retryable
        }
        switch code {
        case 401, 408, 429:
            // 401 here already survived the client's refresh-and-retry.
            return .retryable
        case 403:
            return MessageFetchFailureKind.isRateLimitBody(body) ? .retryable : .permanent
        case 400...499:
            return .permanent
        default:
            return .retryable
        }
    }
}
