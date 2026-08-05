import Foundation

/// Pure rules for who owns bare keys while compose is mounted.
///
/// Expanded compose normally owns typing and stands mailbox shortcuts down
/// (`g i`, j/k, e, …). After Send / discard / save-and-close claims finish,
/// the card may stay mounted briefly (or a lagging AppKit focus re-steal can
/// leave the body editable) — during that window the user already hit Send
/// and expects mailbox keys (`e` archive, `g i`, …) to work, not type into a
/// locked body or no-op behind `TextFocus.isEditing`.
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

    /// Whether an editable first responder should still block mailbox keys.
    ///
    /// Mid-finish (`composeFinishing`) must bypass `TextFocus.isEditing`:
    /// `beginFinish` resigns focus and disables the form, but a pending
    /// `focusBody` / `updateNSView` re-focus can re-steal an editable body
    /// before unmount — that used to swallow post-Send `e` until the card
    /// finally closed.
    static func textFocusBlocksMailboxKeys(finishing: Bool) -> Bool {
        !finishing
    }

    /// ⌘Z may bypass an editable first responder when the only live undo is
    /// cancel-send and compose is not actively claiming typing.
    ///
    /// After Send, a lagging AppKit focus re-steal can leave an editable
    /// NSText as first responder even though compose has finished/unmounted.
    /// During the pending-send window the user expects ⌘Z to cancel send, not
    /// to be swallowed by that orphan text focus. Expanded compose that still
    /// claims typing must keep ⌘Z for text undo.
    static func undoChordBypassesTextFocus(pendingSend: Bool,
                                           composeClaimsTyping: Bool) -> Bool {
        pendingSend && !composeClaimsTyping
    }
}
