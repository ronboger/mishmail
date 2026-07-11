import Foundation
import Combine

/// A user-rebindable single-key command (Gmail-style, no modifiers).
enum ShortcutCommand: String, CaseIterable, Codable {
    case archive, trash, toggleStar, toggleRead, snooze
    case markSpam
    case reply, replyAll, forward, label, undo, compose
    case next, prev
}

struct ShortcutSpec: Identifiable {
    let command: ShortcutCommand
    let title: String
    let category: KeyBindings.Category
    let defaultKey: String
    var id: ShortcutCommand { command }
}

/// Single source of truth for the Gmail-style single-key shortcuts:
/// defaults, user overrides (persisted to UserDefaults), and both
/// key→command and command→key lookups. The `g` prefix and `?` help key
/// are reserved and handled before this registry is consulted.
@MainActor
final class KeyBindings: ObservableObject {
    enum Category: String, CaseIterable {
        case navigation = "Navigation"
        case actions = "Actions"
    }

    static let reservedKeys: Set<String> = ["g", "?"]

    static let catalog: [ShortcutSpec] = [
        .init(command: .next, title: "Next conversation", category: .navigation, defaultKey: "j"),
        .init(command: .prev, title: "Previous conversation", category: .navigation, defaultKey: "k"),
        .init(command: .archive, title: "Archive", category: .actions, defaultKey: "e"),
        .init(command: .trash, title: "Delete (Trash)", category: .actions, defaultKey: "#"),
        .init(command: .toggleStar, title: "Star / Unstar", category: .actions, defaultKey: "s"),
        .init(command: .toggleRead, title: "Mark read / unread", category: .actions, defaultKey: "u"),
        .init(command: .snooze, title: "Snooze", category: .actions, defaultKey: "b"),
        // Gmail's Report spam key. When the thread is already in Spam the
        // same binding runs Not spam (toggle) — see MailStore.perform.
        .init(command: .markSpam, title: "Mark as spam / Not spam", category: .actions, defaultKey: "!"),
        .init(command: .reply, title: "Reply", category: .actions, defaultKey: "r"),
        .init(command: .replyAll, title: "Reply all", category: .actions, defaultKey: "a"),
        .init(command: .forward, title: "Forward", category: .actions, defaultKey: "f"),
        .init(command: .label, title: "Label…", category: .actions, defaultKey: "l"),
        .init(command: .undo, title: "Undo", category: .actions, defaultKey: "z"),
        .init(command: .compose, title: "Compose", category: .actions, defaultKey: "c"),
    ]

    static func title(for command: ShortcutCommand) -> String {
        catalog.first { $0.command == command }!.title
    }

    enum RebindResult: Equatable {
        case ok
        case conflict(ShortcutCommand)
        case rejected(String)
    }

    /// True while the Settings pane is capturing a key press, so the main
    /// window's key monitor stands down and the capture can't fire actions.
    @Published var capturing = false

    @Published private(set) var overrides: [ShortcutCommand: String]

    private let store: UserDefaults
    private static let defaultsKey = "keyBindings"

    init(defaults: UserDefaults = .standard) {
        store = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            overrides = raw.reduce(into: [:]) { map, entry in
                if let cmd = ShortcutCommand(rawValue: entry.key) { map[cmd] = entry.value }
            }
        } else {
            overrides = [:]
        }
    }

    func key(for command: ShortcutCommand) -> String {
        overrides[command] ?? Self.catalog.first { $0.command == command }!.defaultKey
    }

    /// Secondary built-in keys that fire a command when the key isn't
    /// bound to anything else (a rebind to the key wins over the alias).
    static let aliases: [String: ShortcutCommand] = ["h": .snooze]

    func command(for key: String) -> ShortcutCommand? {
        primaryCommand(for: key) ?? Self.aliases[key]
    }

    private func primaryCommand(for key: String) -> ShortcutCommand? {
        Self.catalog.map(\.command).first { self.key(for: $0) == key }
    }

    func rebind(_ command: ShortcutCommand, to key: String) -> RebindResult {
        guard key.count == 1, key != " " else {
            return .rejected("Press a single character key.")
        }
        guard !Self.reservedKeys.contains(key) else {
            return .rejected("\"\(key)\" is reserved.")
        }
        if self.key(for: command) == key { return .ok }
        if let other = primaryCommand(for: key) { return .conflict(other) }
        overrides[command] = key
        persist()
        return .ok
    }

    func resetToDefaults() {
        overrides = [:]
        store.removeObject(forKey: Self.defaultsKey)
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            store.set(data, forKey: Self.defaultsKey)
        }
    }
}
