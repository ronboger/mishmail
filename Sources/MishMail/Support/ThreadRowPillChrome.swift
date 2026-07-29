import Foundation

/// Chrome for colored pills in a thread list row (user labels, AI categories).
///
/// Idle rows use a soft tinted capsule (Notion Mail-style). Selected rows sit
/// on the system blue list highlight, where a 16% tint wash disappears and
/// the colored text clashes — so focus flips to a stronger tint fill with a
/// high-contrast title (white on dark tints, near-black on pale ones).
enum ThreadRowPillChrome: Equatable, Sendable {
    /// Colored text + low-opacity tint fill (unselected rows).
    case softTint
    /// High-contrast text + stronger tint fill (selected / focused rows).
    case onSelection

    static func forFocused(_ isFocused: Bool) -> ThreadRowPillChrome {
        isFocused ? .onSelection : .softTint
    }

    /// Opacity of the capsule fill (applied over the label tint color).
    var fillOpacity: Double {
        switch self {
        case .softTint: return 0.16
        case .onSelection: return 0.78
        }
    }

    /// Max relative luminance (WCAG, 0…1) at which selection chrome still uses
    /// white title text. Pale yellow / light gray Gmail tints sit above this
    /// and get near-black text instead. Tuned between saturated mid-tones
    /// (Notion yellow ~0.45) and light grays (~0.54).
    static let lightForegroundMaxLuminance: Double = 0.52

    /// WCAG relative luminance of an sRGB color (`r`/`g`/`b` in 0…1).
    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func channel(_ c: Double) -> Double {
            let x = min(1, max(0, c))
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Whether selection chrome should use white title text on this solid tint.
    /// Dark/mid tints → white; pale tints → dark text.
    static func selectionUsesLightForeground(r: Double, g: Double, b: Double) -> Bool {
        relativeLuminance(r: r, g: g, b: b) < lightForegroundMaxLuminance
    }

    /// Same as the RGB form, for a `#RRGGBB` / `RRGGBB` label color.
    /// Returns `nil` when the string is missing or malformed so callers can
    /// fall back (system semantic colors are mid-tone → prefer white).
    static func selectionUsesLightForeground(hex: String?) -> Bool? {
        guard let rgb = parseHexRGB(hex) else { return nil }
        return selectionUsesLightForeground(r: rgb.r, g: rgb.g, b: rgb.b)
    }

    /// Parse `#RRGGBB` / `RRGGBB` into 0…1 sRGB components.
    static func parseHexRGB(_ string: String?) -> (r: Double, g: Double, b: Double)? {
        guard var hex = string?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (
            r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255
        )
    }
}
