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

    /// Opaque color from an sRGB hex value (same in light and dark).
    static func hex(_ hex: UInt32) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

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

    /// Accent for an on-device AI triage bucket (Classifier.categories).
    static func aiCategory(_ name: String) -> Color {
        switch name {
        case "Reply needed": return .red
        case "FYI": return .blue
        case "Newsletter": return .purple
        case "Receipt": return .teal
        default: return .gray
        }
    }
}

/// Notion Mail-style icon + color per mailbox view: colorful for the primary
/// views (red inbox, purple promotions, blue social…), quiet gray for the
/// utility ones. Used by the sidebar and the list-column header.
extension MailboxView {
    var icon: String {
        switch self {
        case .inbox: return "tray.fill"
        case .promotions: return "basket.fill"
        case .social: return "bubble.left.fill"
        case .starred: return "star.fill"
        case .snoozed: return "clock.fill"
        case .reminders: return "bell.fill"
        case .drafts: return "doc.text"
        case .scheduled: return "calendar.badge.clock"
        case .sent: return "paperplane"
        case .allMail: return "archivebox"
        case .trash: return "trash"
        case .account: return "person.crop.circle"
        case .label: return "tag.fill"
        case .saved: return "line.3.horizontal.decrease.circle"
        }
    }

    var iconColor: Color {
        switch self {
        case .inbox: return .hex(0xEB5757)        // Notion red
        case .promotions: return .hex(0x9B51E0)   // purple
        case .social: return .hex(0x2D9CDB)       // blue
        case .starred: return .hex(0xF2C94C)      // yellow
        case .snoozed: return .hex(0xF2994A)      // orange
        case .reminders: return .hex(0xF2994A)
        case .label: return .hex(0x27AE60)        // green
        default: return .secondary
        }
    }
}
