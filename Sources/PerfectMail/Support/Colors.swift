import SwiftUI
import AppKit

extension NSColor {
    /// Theme-adaptive color from light/dark sRGB hex values.
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        }
    }
}

extension Color {
    // MARK: Notion Mail palette
    // Warm near-blacks in dark mode, warm off-whites in light mode, and the
    // Notion blue accent. Everything theme-adaptive via NSColor providers.

    /// Notion blue, used everywhere the app previously used the system accent.
    static let notionAccent = Color(nsColor: .adaptive(light: 0x2383E2, dark: 0x2E9BE8))
    /// Main content background (thread list, reading pane).
    static let notionContent = Color(nsColor: .adaptive(light: 0xFFFFFF, dark: 0x191919))
    /// Sidebar background, a step warmer/lighter than the content.
    static let notionSidebar = Color(nsColor: .adaptive(light: 0xF7F7F5, dark: 0x232323))

    /// Deterministic pleasant color for a string (sender avatars, etc.).
    static func stable(for string: String) -> Color {
        var hash: UInt64 = 5381
        for byte in string.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .cyan]
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// Gmail-style category accent colors.
    static func category(_ id: String) -> Color {
        switch id {
        case "CATEGORY_PROMOTIONS": return .green
        case "CATEGORY_SOCIAL": return .blue
        case "CATEGORY_UPDATES": return .orange
        case "CATEGORY_FORUMS": return .purple
        default: return .gray
        }
    }
}
