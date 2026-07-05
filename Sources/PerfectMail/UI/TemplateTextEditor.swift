import SwiftUI
import AppKit

/// Plain-text editor for snippet bodies. Two things TextEditor can't do:
/// placeholders highlight live as you type — accent for variables the
/// expander fills, orange for fill-in-yourself prompts like `{key_point_1}`
/// — and typing `{` pops the native completion list of known variables.
struct TemplateTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = TemplateTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 13),
                                     .foregroundColor: NSColor.labelColor]
        // Smart substitutions corrupt templates (curly quotes in shortcuts,
        // auto-links in bodies) — this is source text, keep it literal.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.string = text
        Coordinator.highlight(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? TemplateTextView,
              textView.string != text else { return }
        textView.string = text
        Coordinator.highlight(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var completing = false
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? TemplateTextView else { return }
            text.wrappedValue = textView.string
            Self.highlight(textView)
            // Typing inside a `{...` token keeps the variable menu up. The
            // guard breaks the cycle: completion's own tentative inserts land
            // back here and must not re-trigger complete().
            guard !completing, textView.activePlaceholderRange() != nil else { return }
            completing = true
            textView.complete(nil)
            completing = false
        }

        func textView(_ textView: NSTextView, completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let partial = (textView.string as NSString).substring(with: charRange)
            guard partial.hasPrefix("{") else { return words }
            let doubled = partial.hasPrefix("{{")
            let typed = partial.drop(while: { $0 == "{" }).lowercased()
            return SnippetExpander.variables
                .map { doubled ? "{\($0.token)}" : $0.token }
                .filter { token in
                    typed.isEmpty || token.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                        .hasPrefix(typed)
                }
        }

        static func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
            for placeholder in SnippetExpander.placeholders(in: textView.string) {
                storage.addAttribute(
                    .foregroundColor,
                    value: placeholder.known ? NSColor.controlAccentColor : NSColor.systemOrange,
                    range: placeholder.range)
            }
            storage.endEditing()
        }
    }
}

/// NSTextView whose completion token starts at the `{` being typed, so the
/// native completion popup (usually word-based) can offer `{first_name}`.
final class TemplateTextView: NSTextView {
    override var rangeForUserCompletion: NSRange {
        activePlaceholderRange() ?? super.rangeForUserCompletion
    }

    /// The `{partial` token the insertion point is sitting at the end of,
    /// if any: scans back over word characters to a `{` (or `{{`), giving up
    /// at whitespace, a closed brace, or an implausibly long name.
    func activePlaceholderRange() -> NSRange? {
        let caret = selectedRange().location
        guard caret != NSNotFound, selectedRange().length == 0 else { return nil }
        let ns = string as NSString
        var i = caret
        while i > 0, caret - i < 24 {
            let ch = Character(UnicodeScalar(ns.character(at: i - 1)) ?? " ")
            if ch == "{" {
                var start = i - 1
                if start > 0, ns.character(at: start - 1) == UInt16(UnicodeScalar("{").value) {
                    start -= 1
                }
                return NSRange(location: start, length: caret - start)
            }
            guard ch.isLetter || ch.isNumber || ch == "_" else { return nil }
            i -= 1
        }
        return nil
    }
}
