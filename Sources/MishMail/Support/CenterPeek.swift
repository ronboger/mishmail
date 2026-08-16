import CoreGraphics

/// Notion Mail-style "center peek": the conversation opens in a centered
/// card over the list instead of filling the window or docking beside it.
/// Pure geometry so it is unit-testable without SwiftUI.
enum CenterPeekLayout {
    /// Below this the conversation is unreadable; the card claims what it
    /// can of the host instead.
    static let minimumCardWidth: CGFloat = 520
    /// Reading measure cap — Notion Mail's peek stays a column, not a sheet.
    static let maximumCardWidth: CGFloat = 980
    /// Preferred share of the host width.
    static let widthFraction: CGFloat = 0.72
    /// Backdrop margins that keep the list visible around the card.
    static let horizontalInset: CGFloat = 48
    static let verticalInset: CGFloat = 32

    static func cardSize(host: CGSize) -> CGSize {
        let available = max(0, host.width - horizontalInset * 2)
        let preferred = min(maximumCardWidth,
                            max(minimumCardWidth, host.width * widthFraction))
        return CGSize(width: min(preferred, available),
                      height: max(0, host.height - verticalInset * 2))
    }
}
