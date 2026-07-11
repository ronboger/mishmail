import Foundation

/// How remote images in HTML mail are allowed without a per-message click.
///
/// Default stays `.ask` (privacy-first: tracking pixels blocked until opt-in).
/// `.vip` is the middle ground — trusted senders get images automatically;
/// everyone else still needs Load images. `.always` is the full open policy.
enum RemoteImagePolicy: String, CaseIterable, Identifiable {
    case ask
    case vip
    case always

    var id: String { rawValue }

    static let defaultsKey = "remoteImagePolicy"
    /// Brief boolean toggle shipped before the three-way picker.
    static let legacyBoolKey = "loadRemoteImagesByDefault"

    var title: String {
        switch self {
        case .ask: return "Ask each time"
        case .vip: return "VIP senders"
        case .always: return "Always"
        }
    }

    /// Policy-specific explanation. Settings appends the shared cleartext note.
    var footer: String {
        switch self {
        case .ask:
            return "Each message shows Load images (and the thread can load all at once). Remote images can track opens."
        case .vip:
            return "HTTPS images load automatically only from VIP senders. Other messages still need a click."
        case .always:
            return "HTTPS images load in every message."
        }
    }

    /// Whether this message may fetch remote images without a further click.
    /// `messageOptIn` / `threadOptIn` are explicit UI loads for this session.
    static func allows(
        policy: RemoteImagePolicy,
        senderEmail: String,
        vipEmails: Set<String>,
        messageOptIn: Bool,
        threadOptIn: Bool
    ) -> Bool {
        if messageOptIn || threadOptIn { return true }
        switch policy {
        case .ask: return false
        case .always: return true
        case .vip:
            let email = senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !email.isEmpty && vipEmails.contains(email)
        }
    }

    /// One-shot migration from the old boolean default onto the string key.
    ///
    /// Only writes when the legacy key was actually present — fresh installs
    /// leave `remoteImagePolicy` unset so a future default change still applies.
    /// MessageCard reads the key via `@AppStorage` with an `.ask` fallback;
    /// the main window runs this in `onAppear` before threads are usually open,
    /// so a legacy-always user only theoretically sees a brief ask window.
    static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: defaultsKey) == nil else { return }
        guard defaults.object(forKey: legacyBoolKey) != nil else { return }
        if defaults.bool(forKey: legacyBoolKey) {
            defaults.set(RemoteImagePolicy.always.rawValue, forKey: defaultsKey)
        } else {
            defaults.set(RemoteImagePolicy.ask.rawValue, forKey: defaultsKey)
        }
        defaults.removeObject(forKey: legacyBoolKey)
    }

    static func stored(_ defaults: UserDefaults = .standard) -> RemoteImagePolicy {
        migrateIfNeeded(defaults)
        let raw = defaults.string(forKey: defaultsKey) ?? RemoteImagePolicy.ask.rawValue
        return RemoteImagePolicy(rawValue: raw) ?? .ask
    }
}
