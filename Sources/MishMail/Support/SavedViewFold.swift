import Foundation

/// Folds the ViewEditor's structured fields back into the chip set of a
/// chips-backed saved view ("Save as view…"), where `chipsJSON` is what the
/// list query reads.
///
/// Pure and on primitive types: `FilterChips` and `MailStore.saveView` are
/// app-target only, so the rules live here where the hostless tests reach them.
enum SavedViewFold {
    /// The two categories behind the editor's "Exclude Promotions & Social".
    static let promotionsAndSocial: Set<String> = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"]

    struct Categories: Equatable {
        var show: Set<String>
        var hide: Set<String>
    }

    /// Category chips after an editor save.
    ///
    /// The toggle reads "on" only when BOTH categories are hidden, so "off"
    /// removes the pair only when both are present. A view that hides one of
    /// them (or Updates/Forums) shows the toggle off and must survive a save
    /// that did not touch it. The Category picker holds one value: a pick
    /// replaces `show`, "Any" clears it.
    static func categories(show: Set<String>, hide: Set<String>,
                           excludePromotions: Bool, category: String?) -> Categories {
        var out = Categories(show: show, hide: hide)
        if excludePromotions {
            out.hide.formUnion(promotionsAndSocial)
        } else if out.hide.isSuperset(of: promotionsAndSocial) {
            out.hide.subtract(promotionsAndSocial)
        }
        out.show = category.map { [$0] } ?? []
        return out
    }

    /// `FilterChips.labelName` after an editor save. The name is display-only
    /// and the editor edits the id alone, so a changed id drops the old name
    /// instead of leaving it on the wrong label.
    static func labelName(current: String?, oldLabelId: String?, newLabelId: String?) -> String? {
        oldLabelId == newLabelId ? current : nil
    }
}
