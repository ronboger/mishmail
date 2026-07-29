import Foundation

/// Pure rules for who owns bare keys while compose is mounted.
///
/// Expanded compose normally owns typing and stands mailbox shortcuts down
/// (`g i`, j/k, e, …). After Send / discard / save-and-close claims finish,
/// the card stays mounted briefly while an in-flight draft persist completes
/// — during that window the user already hit Send and expects `g i` to work,
/// not type into a locked body or no-op.
enum ComposeKeyOwnership {
    /// Expanded compose still owns text chords and blocks mailbox single keys.
    static func claimsTyping(hasRequest: Bool,
                             minimized: Bool,
                             finishing: Bool) -> Bool {
        hasRequest && !minimized && !finishing
    }

    /// Mailbox single-key shortcuts may run (compose is nil, minimized, or
    /// mid-finish after Send).
    static func allowsMailboxKeys(hasRequest: Bool,
                                  minimized: Bool,
                                  finishing: Bool) -> Bool {
        !claimsTyping(hasRequest: hasRequest,
                      minimized: minimized,
                      finishing: finishing)
    }
}
