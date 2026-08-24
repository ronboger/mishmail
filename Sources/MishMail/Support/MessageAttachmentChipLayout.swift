import CoreGraphics
import Foundation

/// Hit-target contract for file chips under a message in `ThreadDetailView`.
///
/// The screenshot bug: padding and background sat on an outer `HStack` while
/// the Quick Look `Button` wrapped only the icon + filename. `.buttonStyle(.plain)`
/// then hit-tested the text glyphs, so clicks on the chip chrome, icon, size
/// line, or padding did nothing.
///
/// Contract: every region of the chip is a button. The preview region includes
/// the leading/vertical chip padding. Eye and Save keep distinct trailing
/// targets. `MessageAttachmentChip` uses these values.
enum MessageAttachmentChipLayout {
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8
    static let iconTextSpacing: CGFloat = 8
    static let actionInnerPadding: CGFloat = 4
    /// Matches `PMRadius.md`. Kept numeric so tests compile without Styles.
    static let cornerRadius: CGFloat = 8

    /// No gap between regions — a non-zero spacing was dead chrome.
    static let regionSpacing: CGFloat = 0

    /// Leading → trailing interactive regions. `preview` is the icon +
    /// filename + size + chip padding (not text-only).
    static let regions = ["preview", "quickLook", "save"]

    static let previewAction = "quickLook"
    static let quickLookAction = "quickLook"
    static let saveAction = "save"

    /// Insets applied *inside* the preview button so padding is part of the
    /// hit target. Trailing inset equals icon-text spacing so the gap before
    /// the eye is still preview, not dead chrome.
    static func previewHitInsets() -> (leading: CGFloat, trailing: CGFloat, vertical: CGFloat) {
        (horizontalPadding, iconTextSpacing, verticalPadding)
    }

    /// Save's trailing inset is the chip's trailing padding so the rounded
    /// corner is still a button hit, not dead chrome.
    static func saveHitInsets() -> (leading: CGFloat, trailing: CGFloat, vertical: CGFloat) {
        (actionInnerPadding, horizontalPadding, verticalPadding)
    }

    /// True when chip padding lives inside the preview button rather than
    /// an inert wrapper. The old layout set this to false (screenshot bug).
    static var previewIncludesChipPadding: Bool { true }

    /// Eye and Save are shorter than the 20pt file icon. They grow to this
    /// height so the band above/below them is not dead. Min — not max —
    /// so a horizontal `ScrollView` cannot stretch the chip.
    static var chipMinHeight: CGFloat { 20 + verticalPadding * 2 }

    static var regionsFillChipHeight: Bool { true }
}
