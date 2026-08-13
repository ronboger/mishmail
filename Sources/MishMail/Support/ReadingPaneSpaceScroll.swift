import Foundation

/// Space / Shift+Space paging for the reading pane (Gmail-style): scroll by
/// most of a viewport, keeping a small overlap for reading continuity, and
/// clamp to the document bounds. Pure math — AppKit lookup stays in the
/// caller.
enum ReadingPaneSpaceScroll {
    /// Fraction of the viewport kept visible across a page for continuity.
    static let overlapFraction: Double = 0.15

    /// Next vertical offset after one Space press. `up` is Shift+Space.
    /// Returns nil when the content already fits (nothing to scroll).
    static func pageTarget(current: Double, viewportHeight: Double,
                           contentHeight: Double, up: Bool) -> Double? {
        let maxOffset = contentHeight - viewportHeight
        guard maxOffset > 0, viewportHeight > 0 else { return nil }
        let step = viewportHeight * (1 - overlapFraction)
        let target = up ? current - step : current + step
        let clamped = min(max(target, 0), maxOffset)
        guard clamped != current else { return nil }
        return clamped
    }
}
