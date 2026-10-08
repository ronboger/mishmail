import Foundation

/// Explicit writing preferences, shared by compose and Ask Mish. No sent-mail
/// mining is needed to remember a preferred tone, signature, or booking link.
enum AIWritingPreferences {
    static let storageKey = "ai.writingInstructions"
    static let characterLimit = 3_000

    static func normalized(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(characterLimit))
    }

    static func instructions(in defaults: UserDefaults = .standard) -> String {
        normalized(defaults.string(forKey: storageKey) ?? "")
    }

    static func prompt(_ text: String) -> String {
        let instructions = normalized(text)
        guard !instructions.isEmpty else { return "" }
        return "\n\nThe user's writing preferences (apply when drafting or editing mail; the current request takes precedence):\n\(instructions)"
    }
}
