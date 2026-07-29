import CoreGraphics
import Foundation

/// Footer draft-status chrome metrics.
///
/// Idle used to be `EmptyView`, so the first "Draft saved" / "Saving…" paint
/// inserted width into the compose footer. That reflow nudged the right
/// cluster (and used to wrap "Snippets" onto two lines, growing the card
/// chrome). Always reserve the longest label so status changes never change
/// the footer's laid-out size.
enum ComposeDraftStatusLayout {
    /// Matches the Send control's fixed height so the status slot never
    /// changes footer height when text appears.
    static let rowHeight: CGFloat = 22
    static let fontSize: CGFloat = 12

    static let savingLabel = "Saving…"
    static let savedLabel = "Draft saved"
    static let failedLabel = "Draft not saved"

    /// Longest user-visible status string — width sizer for the reserved slot.
    static var widthSizerLabel: String { failedLabel }

    /// Labels that paint in the reserved slot (idle is empty but still sized).
    static var visibleLabels: [String] {
        [savingLabel, savedLabel, failedLabel]
    }

    /// Character-count proxy that the sizer is at least as long as every
    /// painted label. Proportional fonts track this closely for these strings.
    static func sizerIsLongestLabel() -> Bool {
        let sizer = widthSizerLabel.count
        return visibleLabels.allSatisfy { $0.count <= sizer }
    }
}
