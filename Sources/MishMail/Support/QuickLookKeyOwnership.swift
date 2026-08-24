import Foundation

/// Whether the mailbox key monitor must yield to the system Quick Look panel.
///
/// `event.window is QLPreviewPanel` is not enough: a local key monitor often
/// sees the main window as `event.window` even while the panel is up. Esc
/// then closes the reading pane instead of the preview.
enum QuickLookKeyOwnership {
    /// True when every key (Esc, space, arrows) belongs to Quick Look.
    static func claimsKeys(eventWindowIsPreviewPanel: Bool,
                           previewPanelVisible: Bool) -> Bool {
        eventWindowIsPreviewPanel || previewPanelVisible
    }
}
