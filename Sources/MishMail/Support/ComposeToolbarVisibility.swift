import Foundation

/// Compose footer / format-bar controls the user can hide in Settings.
///
/// Stored as a comma-separated list of raw values under
/// `ComposeToolbarVisibility.storageKey` (empty = show everything).
/// Pure helpers stay free of AppKit/SwiftUI so unit tests can drive them.
enum ComposeToolbarItem: String, CaseIterable, Identifiable, Codable {
    // Left tools
    case attach
    case link
    case snippets
    case ai
    // Format strip (no second link — dedicated link button owns ⌘K)
    case bold
    case italic
    case strikethrough
    case code
    case heading
    case quote
    case bullet
    case math

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attach: return "Attach"
        case .link: return "Link"
        case .snippets: return "Snippets"
        case .ai: return "AI draft"
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .code: return "Code"
        case .heading: return "Heading"
        case .quote: return "Quote"
        case .bullet: return "Bullet list"
        case .math: return "Math"
        }
    }

    /// Hover tooltip (includes shortcut when one exists).
    var help: String {
        switch self {
        case .attach: return "Attach files"
        case .link: return "Insert link (⌘K)"
        case .snippets: return "Insert a saved snippet (⌘/)"
        case .ai: return "Draft with local AI (Ollama)"
        case .bold: return "Bold (⌘B)"
        case .italic: return "Italic (⌘I)"
        case .strikethrough: return "Strikethrough (⌘⇧X)"
        case .code: return "Code (⌘E)"
        case .heading: return "Heading (⌘⌥1)"
        case .quote: return "Quote (⌘⇧.)"
        case .bullet: return "Bullet list (⌘⇧8)"
        case .math: return "Math (⌘⇧M)"
        }
    }

    var systemImage: String {
        switch self {
        case .attach: return "paperclip"
        case .link: return "link"
        case .snippets: return "text.badge.plus"
        case .ai: return "sparkles"
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .heading: return "number"
        case .quote: return "text.quote"
        case .bullet: return "list.bullet"
        case .math: return "function"
        }
    }

    /// Left cluster before the format strip.
    var isLeftTool: Bool {
        switch self {
        case .attach, .link, .snippets, .ai: return true
        default: return false
        }
    }

    /// Markdown format strip items (order matches the bar).
    var isFormat: Bool { !isLeftTool }

    /// Stable Settings / toolbar order.
    static let displayOrder: [ComposeToolbarItem] = [
        .attach, .link, .snippets, .ai,
        .bold, .italic, .strikethrough, .code,
        .heading, .quote, .bullet, .math,
    ]

    static let formatOrder: [ComposeToolbarItem] = displayOrder.filter(\.isFormat)
}

enum ComposeToolbarVisibility {
    static let storageKey = "composeToolbar.hidden"

    /// Parse the UserDefaults / `@AppStorage` string into a set of hidden raw values.
    /// Unknown tokens are kept so a future version's keys aren't wiped.
    static func hiddenSet(from raw: String) -> Set<String> {
        Set(raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    static func encode(_ hidden: Set<String>) -> String {
        hidden.sorted().joined(separator: ",")
    }

    static func isVisible(_ item: ComposeToolbarItem, hiddenRaw: String) -> Bool {
        !hiddenSet(from: hiddenRaw).contains(item.rawValue)
    }

    static func isVisible(_ item: ComposeToolbarItem,
                          hidden: Set<String>) -> Bool {
        !hidden.contains(item.rawValue)
    }

    /// Toggle one item; returns the new encoded string.
    static func toggling(_ item: ComposeToolbarItem, in raw: String) -> String {
        var set = hiddenSet(from: raw)
        if set.contains(item.rawValue) {
            set.remove(item.rawValue)
        } else {
            set.insert(item.rawValue)
        }
        return encode(set)
    }

    /// Force-hide (or show) an item.
    static func setting(_ item: ComposeToolbarItem, hidden: Bool, in raw: String) -> String {
        var set = hiddenSet(from: raw)
        if hidden {
            set.insert(item.rawValue)
        } else {
            set.remove(item.rawValue)
        }
        return encode(set)
    }
}
