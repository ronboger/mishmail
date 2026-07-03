import SwiftUI

extension Color {
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
