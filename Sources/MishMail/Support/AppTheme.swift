import AppKit
import SwiftUI

/// User-selectable app theme: follow macOS, or force light/dark. Applied
/// app-wide via NSApp.appearance so AppKit, SwiftUI, and rendered HTML
/// (WKWebView picks up the effective appearance) all agree.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appTheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil = follow the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Unknown raw values (edited defaults, future removals) fall back to
    /// following the system rather than crashing or sticking.
    static func from(raw: String?) -> AppTheme {
        AppTheme(rawValue: raw ?? "") ?? .system
    }

    static var current: AppTheme {
        from(raw: UserDefaults.standard.string(forKey: storageKey))
    }

    @MainActor
    static func apply(_ theme: AppTheme) {
        NSApp.appearance = theme.nsAppearance
    }
}
