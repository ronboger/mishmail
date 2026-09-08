import Foundation

/// How capable a chat model is relative to what is worth picking today.
/// Browse lists hide everything below a floor; search still finds the rest.
enum LLMModelIntelligence: Int, Comparable, CaseIterable, Hashable, Sendable {
    case older = 0
    case current = 1
    case strong = 2
    case frontier = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .frontier: return "Frontier"
        case .strong: return "Strong"
        case .current: return "Current"
        case .older: return "Older"
        }
    }

    /// Unknown ids count as current so a new listing is not hidden.
    static func of(_ model: String) -> LLMModelIntelligence {
        let name = AskMishModelMenu.displayName(model).lowercased()
        if name.hasPrefix("grok-2") || name.hasPrefix("grok-3") { return .older }
        if name.hasPrefix("gemini-1") || name.hasPrefix("gemini-2") { return .older }
        if name.contains("claude") { return claudeRank(name) }
        if name.contains("gpt-") || name.hasPrefix("gpt") { return gptRank(name) }
        if name.hasPrefix("o1") { return .older }
        if name.contains("o3-pro") { return .frontier }
        if name.hasPrefix("o3-mini") { return .current }
        if name.hasPrefix("o3") || name.hasPrefix("o4") { return .strong }
        if name.contains("gemini") { return geminiRank(name) }
        if name.contains("grok") { return grokRank(name) }
        return .current
    }

    private static func claudeRank(_ name: String) -> LLMModelIntelligence {
        if isClaude3(name) { return .older }
        if name.contains("haiku") { return .current }
        if name.contains("opus") { return .frontier }
        if name.contains("sonnet") { return .strong }
        return .strong
    }

    /// Claude 3.x (3, 3.5, 3.7). Must not match haiku-4-5 / sonnet-4-5.
    private static func isClaude3(_ name: String) -> Bool {
        name.contains("claude-3") || name.contains("claude-3.")
            || name.contains("3-5-") || name.contains("3.5-")
            || name.contains("3-7-") || name.contains("3.7-")
    }

    private static func gptRank(_ name: String) -> LLMModelIntelligence {
        if name.contains("gpt-4") { return .older }
        if name.contains("mini") || name.contains("nano") { return .current }
        if name.contains("gpt-5.4") || name.contains("gpt-5.5") || name.contains("gpt-5.6")
            || name.contains("gpt-5-4")
            || name.contains("sol") || name.contains("terra") || name.contains("luna") {
            return .frontier
        }
        if name.contains("gpt-5") { return .strong }
        return .current
    }

    private static func geminiRank(_ name: String) -> LLMModelIntelligence {
        if name.contains("lite") { return .current }
        if name.contains("flash") { return .strong }
        if name.contains("pro") { return .frontier }
        return .strong
    }

    private static func grokRank(_ name: String) -> LLMModelIntelligence {
        if name.contains("4.6") || name.contains("4-6") { return .frontier }
        if name.contains("fast") { return .current }
        if name.contains("grok-4") { return .strong }
        return .current
    }
}
