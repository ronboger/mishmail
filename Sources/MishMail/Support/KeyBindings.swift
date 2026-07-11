import Foundation
import Combine

/// A user-rebindable single-key command (Gmail-style, no modifiers).
enum ShortcutCommand: String, CaseIterable, Codable {
    case archive, trash, toggleStar, toggleRead, snooze
    case markSpam
    case reply, replyAll, forward, label, undo, compose
    case next, prev
    /// Toggle multi-select checkbox on the focused conversation (Gmail `x`).
    case toggleCheck
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
        .init(command: .toggleCheck, title: "Select / deselect conversation", category: .navigation, defaultKey: "x"),
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
    /// Candidate keys when a new catalog default collides with a stored
    /// override (home-row leftovers not already in the catalog).
    private static let freeKeyCandidates = Array("qwertyuiopasdfghjklzxcvbnm0123456789!@#$%^&*-=_+;:'\",.<>/?\\|`~")
        .map(String.init)

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
        // New catalog defaults (e.g. toggleCheck → x) must not shadow an
        // existing user rebind of that key. Prefer the override at lookup,
        // and park the un-overridden command on a free key so Settings and
        // command(for:) agree.
        if migrateCollidingDefaults() {
            persist()
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

    /// Explicit user overrides always win over catalog defaults so a
    /// previously rebound key (archive → x) is not stolen by a new default
    /// (toggleCheck → x).
    private func primaryCommand(for key: String) -> ShortcutCommand? {
        if let overridden = overrides.first(where: { $0.value == key })?.key {
            return overridden
        }
        return Self.catalog.first {
            overrides[$0.command] == nil && $0.defaultKey == key
        }?.command
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

    /// When a catalog default is already claimed by a stored override of a
    /// different command, park the default-only command on a free key.
    /// Returns true if `overrides` changed.
    @discardableResult
    private func migrateCollidingDefaults() -> Bool {
        var claimed = Set(overrides.values)
        // Defaults already held by un-overridden commands also claim slots.
        for spec in Self.catalog where overrides[spec.command] == nil {
            claimed.insert(spec.defaultKey)
        }
        var changed = false
        for spec in Self.catalog {
            guard overrides[spec.command] == nil else { continue }
            // Recompute: is this default only "ours", or also an override?
            let takenByOverride = overrides.contains { $0.key != spec.command && $0.value == spec.defaultKey }
            guard takenByOverride else { continue }
            // Park us elsewhere. Leave `spec.defaultKey` in `claimed` so it
            // stays reserved for the override (must not re-park onto it).
            guard let free = Self.firstFreeKey(excluding: claimed.union(Self.reservedKeys)) else { continue }
            overrides[spec.command] = free
            claimed.insert(free)
            changed = true
        }
        return changed
    }

    /// First single-character candidate not in `excluding` and not reserved.
    static func firstFreeKey(excluding: Set<String>) -> String? {
        freeKeyCandidates.first { !excluding.contains($0) && !reservedKeys.contains($0) }
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            store.set(data, forKey: Self.defaultsKey)
        }
    }
}
