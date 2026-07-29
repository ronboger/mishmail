import Foundation

/// Chrome for colored pills in a thread list row (user labels, AI categories).
///
/// Idle rows use a soft tinted capsule (Notion Mail-style). Selected rows sit
/// on the system blue list highlight, where a 16% tint wash disappears and
/// the colored text clashes — so focus flips to light text on a solid-enough
/// tint fill that still carries the label's color.
enum ThreadRowPillChrome: Equatable, Sendable {
    /// Colored text + low-opacity tint fill (unselected rows).
    case softTint
    /// White text + stronger tint fill (selected / focused rows).
    case onSelection

    static func forFocused(_ isFocused: Bool) -> ThreadRowPillChrome {
        isFocused ? .onSelection : .softTint
    }

    /// Whether the pill title should render white (selection) vs the label tint.
    var usesLightForeground: Bool {
        switch self {
        case .softTint: return false
        case .onSelection: return true
        }
    }

    /// Opacity of the capsule fill (applied over the label tint color).
    var fillOpacity: Double {
        switch self {
        case .softTint: return 0.16
        case .onSelection: return 0.78
        }
    }
}
