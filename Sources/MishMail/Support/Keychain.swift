import Foundation
import Security

/// Minimal Keychain wrapper for storing per-account OAuth refresh tokens.
/// Everything stays in the local login keychain; nothing syncs to iCloud.
enum Keychain {
    // Keyed by bundle id so "MishMail Debug" (dev.ronboger.MishMail.debug)
    // keeps its own items instead of tripping keychain prompts by reading the
    // release app's — each app only ever touches items it created itself.
    private static let service = Bundle.main.bundleIdentifier ?? "dev.ronboger.MishMail"

    static func set(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrSynchronizable as String] = false
            // Device-bound and available after first unlock: refresh tokens and
            // the DB master key never leave this Mac and are excluded from
            // Keychain backups/migration.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else {
            guard status == errSecSuccess else { throw KeychainError.status(status) }
        }
    }

    /// Preserves why a read failed. OAuth must not turn a temporarily locked
    /// or inaccessible Keychain into a destructive "sign-in missing" state.
    static func read(_ key: String) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return classifyRead(status: status, data: result as? Data)
    }

    /// Compatibility path for non-OAuth secrets whose callers already fail
    /// closed when a value cannot be read.
    static func get(_ key: String) -> String? {
        guard case .value(let value) = read(key) else { return nil }
        return value
    }

    /// Pure status classification for hostless tests.
    static func classifyRead(status: OSStatus, data: Data?) -> KeychainReadResult {
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data, let value = String(data: data, encoding: .utf8) else {
            return .unavailable(errSecDecode)
        }
        return .value(value)
    }

    /// Reuse an existing secret, create one only for a confirmed missing item,
    /// and fail closed for locked/access-controlled Keychain reads.
    static func existingOrCreate(
        from result: KeychainReadResult,
        create: () throws -> String
    ) throws -> String {
        switch result {
        case .value(let value):
            return value
        case .notFound:
            return try create()
        case .unavailable(let status):
            throw KeychainError.status(status)
        }
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainReadResult: Equatable {
    case value(String)
    case notFound
    case unavailable(OSStatus)
}

enum KeychainError: Error, Equatable, LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            return "Keychain is unavailable (error \(status)). Unlock your Mac and try again."
        }
    }
}
