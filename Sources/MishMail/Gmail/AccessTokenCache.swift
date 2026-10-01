import Foundation

/// The short-lived Gmail access token for one account, with the rule for
/// when a refresh result may be cached. A value type so the hostless suite
/// can cover it without the network or the Keychain.
struct AccessTokenCache {
    /// A token this close to expiry is treated as expired, so a request
    /// cannot outlive it in flight.
    static let expiryMargin: TimeInterval = 60

    /// Advances each time the account's sign-in changes (reauthorized or
    /// removed). A refresh captures it before it starts; see `store`.
    private(set) var generation = 0
    private var token: String?
    private var expiry: Date = .distantPast

    func token(now: Date) -> String? {
        guard let token, expiry > now.addingTimeInterval(Self.expiryMargin) else {
            return nil
        }
        return token
    }

    /// Caches a refresh result. Returns false, and stores nothing, when
    /// `generation` is not current: the refresh used a sign-in that has
    /// since been replaced or removed.
    @discardableResult
    mutating func store(_ token: String, expiresIn: Int, now: Date,
                        generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        self.token = token
        expiry = now.addingTimeInterval(TimeInterval(expiresIn))
        return true
    }

    /// The server rejected the token (401). Same sign-in, so the generation
    /// stays and the refresh that follows is accepted.
    mutating func expire() {
        token = nil
        expiry = .distantPast
    }

    /// The sign-in changed. Drops the token and rejects every refresh that
    /// is already in flight.
    mutating func invalidate() {
        expire()
        generation += 1
    }
}
