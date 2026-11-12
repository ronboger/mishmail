import AppKit

/// Apple's system spelling and grammar checking for the writing surfaces
/// (compose body, subject, snippet editor). The checker itself is
/// NSSpellChecker — the same one Mail and TextEdit use, with the user's
/// language and learned words — so this only decides which checks are on.
///
/// Both default to on. The settings are global; Edit ▸ Spelling and Grammar
/// can still flip one view for the current editing session.
enum ComposeSpellCheck {
    static let spellingKey = "composeSpellCheck"
    static let grammarKey = "composeGrammarCheck"

    struct Options: Equatable {
        var spelling: Bool
        var grammar: Bool
    }

    /// Current settings. A missing key means on: users who never opened
    /// Settings still get red underlines.
    static func options(from defaults: UserDefaults = .standard) -> Options {
        Options(spelling: defaults.object(forKey: spellingKey) as? Bool ?? true,
                grammar: defaults.object(forKey: grammarKey) as? Bool ?? true)
    }

    /// Turns the checks on or off for one text view. Grammar marks only
    /// show while spelling is on (AppKit checks both in the same pass), so
    /// grammar follows spelling off.
    static func apply(_ options: Options, to textView: NSTextView) {
        let grammar = options.spelling && options.grammar
        if textView.isContinuousSpellCheckingEnabled != options.spelling {
            textView.isContinuousSpellCheckingEnabled = options.spelling
        }
        if textView.isGrammarCheckingEnabled != grammar {
            textView.isGrammarCheckingEnabled = grammar
        }
    }
}
