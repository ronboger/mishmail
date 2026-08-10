import Foundation

/// Transient connectivity failures that background poll should swallow
/// (next tick retries). Walks `NSUnderlyingErrorKey` chains.
enum TransientNetworkError {
    static func isTransient(_ error: Error) -> Bool {
        var current: Error? = error
        while let err = current {
            if let urlError = err as? URLError, isTransientURLErrorCode(urlError.code) {
                return true
            }
            let ns = err as NSError
            if ns.domain == NSURLErrorDomain,
               isTransientURLErrorCode(URLError.Code(rawValue: ns.code)) {
                return true
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return false
    }

    private static func isTransientURLErrorCode(_ code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}
