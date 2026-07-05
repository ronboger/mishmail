import Foundation

/// On-device email triage. Owns the label set and result normalization; the
/// actual model call lives in `Ollama`. Everything here is pure (no network,
/// no SwiftUI) so it's unit-testable.
enum Classifier {
    /// Default triage buckets. Deliberately short so a small local model is
    /// reliable and the sidebar stays legible.
    static let categories = ["Reply needed", "FYI", "Newsletter", "Receipt", "Other"]

    /// Maps a raw (possibly chatty) model response down to exactly one of
    /// `categories`, defaulting to "Other" when nothing matches.
    static func normalize(_ raw: String, categories: [String] = categories) -> String {
        let fallback = categories.last ?? "Other"
        let lower = raw.lowercased()
        // Prefer an explicit category-name mention.
        for category in categories where lower.contains(category.lowercased()) {
            return category
        }
        // Keyword fallbacks, only for categories that are actually enabled.
        func pick(_ name: String) -> String? { categories.first { $0 == name } }
        if lower.contains("reply") || lower.contains("respond") || lower.contains("action needed"),
           let c = pick("Reply needed") { return c }
        if lower.contains("newsletter") || lower.contains("digest") || lower.contains("promo"),
           let c = pick("Newsletter") { return c }
        if lower.contains("receipt") || lower.contains("invoice") || lower.contains("order"),
           let c = pick("Receipt") { return c }
        return fallback
    }
}
