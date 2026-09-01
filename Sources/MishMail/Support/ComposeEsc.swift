import Foundation

/// Pure Esc priority for compose-related chrome. ContentView's key monitor
/// switches on this so local-monitor install order never decides who wins.
enum ComposeEscIntent: Equatable {
    /// Leave the event alone (e.g. Settings owns Esc — handled later when
    /// compose is nil/minimized; with expanded compose, AppKit gets the event).
    case passThrough
    /// Close the open From identity list; keep compose, placement and focus.
    case dismissFromPicker
    /// Dismiss the `/` snippet picker; keep compose and placement.
    case dismissSlashPicker
    /// Close the command palette; keep compose and placement.
    case closeCommandPalette
    /// Blur the sidebar search field and drop its results panel; keep the draft.
    case dismissSearchFocus
    /// Leave side-by-side; draft stays open at the preferred placement.
    case exitSplit
    /// Same as the compose close button's `.cancelAction` (save draft & close).
    case saveAndCloseCompose
    /// Not compose's problem — continue the mailbox Esc ladder.
    case fallThrough
}

enum ComposeEsc {
    /// Priority: Settings → From list → slash picker → command palette → search focus →
    /// exit split → close expanded draft → mailbox ladder. Explicit gates
    /// only; never rely on `NSEvent` local-monitor registration order.
    ///
    /// Search focus outranks save-and-close so a floating/inline draft does
    /// not vanish while the user is typing `/` in the sidebar (three-pane).
    static func intent(
        isSettingsWindow: Bool,
        fromPickerOpen: Bool = false,
        slashPickerVisible: Bool,
        commandPaletteOpen: Bool,
        searchActive: Bool,
        composeExpanded: Bool,
        isSplit: Bool
    ) -> ComposeEscIntent {
        if isSettingsWindow { return .passThrough }
        // The From list only opens from the focused From control, so Esc
        // must close the list — not save-and-close the whole draft.
        if fromPickerOpen { return .dismissFromPicker }
        if slashPickerVisible { return .dismissSlashPicker }
        if commandPaletteOpen { return .closeCommandPalette }
        if searchActive { return .dismissSearchFocus }
        if composeExpanded, isSplit { return .exitSplit }
        if composeExpanded { return .saveAndCloseCompose }
        return .fallThrough
    }
}
