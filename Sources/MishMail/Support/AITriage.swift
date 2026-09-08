import Foundation

/// Inbox auto-sort / classify policy. `MailStore` still owns the in-memory
/// category map (it is observable UI state); this type decides whether a
/// silent pass may run and how long a failure backs off.
enum AITriage {
    static let autoClassifyKey = "autoClassifyEnabled"
    /// Compose shows auto-generated reply chips for fresh replies (default on).
    static let suggestRepliesKey = "composeSuggestReplies"
    /// Quiet auto-sort backs off this long after a failure so a down server
    /// isn't retried on every poll tick.
    static let failurePause: TimeInterval = 600

    /// Missing key means on — the historical default.
    static func isAutoClassifyEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: autoClassifyKey) == nil
            || defaults.bool(forKey: autoClassifyKey)
    }

    /// Silent auto-sort must not upload inbox snippets to a cloud host.
    /// `nil` config means no provider resolved — do not skip; the classify
    /// pass runs and fails locally, same as before.
    static func shouldSkipSilentAutoSort(config: LLMProviderConfig?) -> Bool {
        guard let config else { return false }
        return LLMRemotePolicy.blocksSilentAutoSort(config)
    }

    static func isFailurePauseActive(pausedUntil: Date?, now: Date = Date()) -> Bool {
        guard let pause = pausedUntil else { return false }
        return pause > now
    }
}
