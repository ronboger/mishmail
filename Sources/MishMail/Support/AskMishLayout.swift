import CoreGraphics
import Foundation

/// Pure geometry for the Ask Mish side panel.
enum AskMishLayout {

    /// Narrowest panel that still fits a readable chat column plus the
    /// composer chrome.
    static let minPanelWidth: CGFloat = 320
    /// Cap so a full-screen window does not stretch the chat past a
    /// comfortable reading measure; the mailbox absorbs the rest.
    static let maxPanelWidth: CGFloat = 480
    /// Narrowest window that hosts both the mailbox and the panel. Below this
    /// the panel stays hidden instead of crushing the list.
    static let minHostWidth: CGFloat = 900

    /// Panel width: about a third of the window, clamped to a usable range.
    /// Mirrors `ComposePlacement.splitComposeWidth`, with a narrower share so
    /// the mailbox stays the primary surface.
    static func panelWidth(hostWidth: CGFloat) -> CGFloat {
        min(max(hostWidth * 0.32, minPanelWidth), maxPanelWidth)
    }

    /// Whether the panel renders at this window width. An unmeasured host
    /// (width 0 on the first frame) counts as too narrow, so the panel does
    /// not flash in at the floor width and then move.
    static func showsPanel(hostWidth: CGFloat, enabled: Bool) -> Bool {
        enabled && hostWidth >= minHostWidth
    }
}
