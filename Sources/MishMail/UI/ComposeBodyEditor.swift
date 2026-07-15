import SwiftUI
import AppKit

/// Shared handle so the format toolbar can mutate the live NSTextView
/// (and its selection) without the button stealing first-responder.
final class ComposeBodyFormatTarget {
    var apply: ((ComposeBodyEditor.FormatAction) -> Void)?
    func run(_ action: ComposeBodyEditor.FormatAction) { apply?(action) }
}

/// Markdown-aware compose body editor.
///
/// Replaces SwiftUI `TextEditor` so we can:
/// 1. Live-highlight markdown markers (headers, bold, italic, code, math…)
/// 2. Handle formatting shortcuts (⌘B / ⌘I / …) before the field editor eats them
/// 3. Keep the binding as plain `String` (markdown source) for drafts/send
///
/// Slash-snippet ↑/↓/Return still work via ComposeView's local key monitor;
/// those keys only fire when the picker is open and we don't claim them here.
struct ComposeBodyEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    /// UTF-16 caret location (NSTextView selectedRange.location). Used by
    /// compose's `/` snippet trigger so the token ends at the caret, not the
    /// end of the body — multi-snippet and mid-message `/` depend on this.
    @Binding var caretUTF16: Int
    var formatTarget: ComposeBodyFormatTarget?
    var fontSize: CGFloat = 14

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, caretUTF16: $caretUTF16,
                    formatTarget: formatTarget)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposeBodyTextView()
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        // Keep markdown source literal — curly quotes break `**` / `$`.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        // Match TextEditor's ~5pt line fragment padding cancel used in ComposeView.
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.onFormat = { [weak coord = context.coordinator] action in
            coord?.apply(action)
        }
        textView.onFocusChange = { [weak coord = context.coordinator] focused in
            coord?.isFocused.wrappedValue = focused
        }
        context.coordinator.bindFormatTarget()
        Coordinator.highlight(textView, fontSize: fontSize)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        context.coordinator.fontSize = fontSize
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.fontSize = fontSize
        context.coordinator.formatTarget = formatTarget
        context.coordinator.bindFormatTarget()
        guard let textView = scroll.documentView as? ComposeBodyTextView else { return }
        context.coordinator.textView = textView

        if textView.string != text {
            // Suppress publishCaret while rewriting: assigning string and
            // setSelectedRange both fire textViewDidChangeSelection
            // synchronously, and writing the binding mid-updateNSView is
            // "modifying state during view update". Callers that rewrite
            // body_ also set caretUTF16 to the intended park position.
            let coord = context.coordinator
            coord.isProgrammaticUpdate = true
            textView.string = text
            let maxLen = (text as NSString).length
            let loc = min(max(caretUTF16, 0), maxLen)
            textView.setSelectedRange(NSRange(location: loc, length: 0))
            // Keep the guard up through highlight so a future attribute/text
            // mutation inside it can't leak a binding write mid-update.
            Coordinator.highlight(textView, fontSize: fontSize)
            coord.isProgrammaticUpdate = false
        }

        // Only programmatically *take* focus (e.g. focusBody after prefill).
        // Never resign here: isFocused tracks first-responder, and blur-on-
        // false races click→toolbar→apply and steals caret from Subject/To.
        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                guard isFocused, textView.window?.firstResponder !== textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    enum FormatAction {
        case bold, italic, strikethrough, code, math, link
        case heading1, heading2, heading3
        case quote, bullet
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var caretUTF16: Binding<Int>
        var formatTarget: ComposeBodyFormatTarget?
        weak var textView: ComposeBodyTextView?
        var fontSize: CGFloat = 14
        /// True while updateNSView (or another external rewrite) is driving
        /// the text view — selection-change callbacks must not write the
        /// caret binding (SwiftUI forbids state mutation during view update).
        var isProgrammaticUpdate = false

        init(text: Binding<String>, isFocused: Binding<Bool>,
             caretUTF16: Binding<Int>,
             formatTarget: ComposeBodyFormatTarget?) {
            self.text = text
            self.isFocused = isFocused
            self.caretUTF16 = caretUTF16
            self.formatTarget = formatTarget
        }

        func bindFormatTarget() {
            formatTarget?.apply = { [weak self] action in
                self?.apply(action)
            }
        }

        private func publishCaret(_ textView: NSTextView) {
            guard !isProgrammaticUpdate else { return }
            let loc = textView.selectedRange().location
            if caretUTF16.wrappedValue != loc {
                caretUTF16.wrappedValue = loc
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // textDidChange also fires for some programmatic edits; skip the
            // binding write when we're mid-rewrite so SwiftUI doesn't see a
            // state mutation inside updateNSView.
            if !isProgrammaticUpdate {
                text.wrappedValue = textView.string
            }
            publishCaret(textView)
            Self.highlight(textView, fontSize: fontSize)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            publishCaret(textView)
        }

        func apply(_ action: FormatAction) {
            guard let textView else { return }
            // Toolbar buttons can steal first responder — reclaim it so the
            // caret stays visible and further typing lands in the body.
            textView.window?.makeFirstResponder(textView)
            let sel = textView.selectedRange()
            let source = textView.string
            let result: (text: String, selection: NSRange)
            switch action {
            case .bold:          result = Markdown.toggleWrap(source, selection: sel, open: "**", close: "**")
            case .italic:        result = Markdown.toggleWrap(source, selection: sel, open: "*", close: "*")
            case .strikethrough: result = Markdown.toggleWrap(source, selection: sel, open: "~~", close: "~~")
            case .code:          result = Markdown.toggleWrap(source, selection: sel, open: "`", close: "`")
            case .math:          result = Markdown.toggleWrap(source, selection: sel, open: "$", close: "$")
            case .link:
                // Selected text becomes the label; URL placeholder selected for overwrite.
                let ns = source as NSString
                let label = sel.length > 0 ? ns.substring(with: sel) : "text"
                let insert = "[\(label)](url)"
                let replaced = ns.replacingCharacters(in: sel, with: insert)
                let urlStart = sel.location + 1 + (label as NSString).length + 2  // after "]("
                result = (replaced, NSRange(location: urlStart, length: 3))
            case .heading1: result = Markdown.toggleLinePrefix(source, selection: sel, prefix: "# ")
            case .heading2: result = Markdown.toggleLinePrefix(source, selection: sel, prefix: "## ")
            case .heading3: result = Markdown.toggleLinePrefix(source, selection: sel, prefix: "### ")
            case .quote:    result = Markdown.toggleLinePrefix(source, selection: sel, prefix: "> ")
            case .bullet:   result = Markdown.toggleLinePrefix(source, selection: sel, prefix: "- ")
            }
            guard result.text != source || result.selection != sel else { return }
            // Replace only the changed span so undo is a small step.
            if let storage = textView.textStorage,
               let (range, replacement) = Self.changedSpan(from: source, to: result.text) {
                guard textView.shouldChangeText(in: range, replacementString: replacement)
                else { return }
                storage.beginEditing()
                storage.replaceCharacters(in: range, with: replacement)
                storage.endEditing()
                textView.didChangeText()
            } else if let storage = textView.textStorage {
                let full = NSRange(location: 0, length: storage.length)
                guard textView.shouldChangeText(in: full, replacementString: result.text)
                else { return }
                storage.beginEditing()
                storage.replaceCharacters(in: full, with: result.text)
                storage.endEditing()
                textView.didChangeText()
            } else {
                textView.string = result.text
            }
            textView.setSelectedRange(result.selection)
            text.wrappedValue = result.text
            Self.highlight(textView, fontSize: fontSize)
        }

        /// Common-prefix/suffix diff so a Bold toggle undoes as two characters,
        /// not a whole-document replacement.
        static func changedSpan(from old: String, to new: String)
            -> (range: NSRange, replacement: String)? {
            let o = old as NSString, n = new as NSString
            if o.length == n.length, o.isEqual(to: new) { return nil }
            var start = 0
            let minLen = min(o.length, n.length)
            while start < minLen, o.character(at: start) == n.character(at: start) {
                start += 1
            }
            var oEnd = o.length, nEnd = n.length
            while oEnd > start, nEnd > start,
                  o.character(at: oEnd - 1) == n.character(at: nEnd - 1) {
                oEnd -= 1
                nEnd -= 1
            }
            let range = NSRange(location: start, length: oEnd - start)
            let replacement = n.substring(with: NSRange(location: start, length: nEnd - start))
            return (range, replacement)
        }

        // Cached once — highlight runs on every keystroke.
        private static let reFence = try! NSRegularExpression(pattern: #"(?m)^```.*$"#)
        private static let reHeading = try! NSRegularExpression(pattern: #"(?m)^(#{1,6})(\s+)(.+)$"#)
        private static let reDisplayMath = try! NSRegularExpression(pattern: #"\$\$[^$]+\$\$"#)
        private static let reInlineMath = try! NSRegularExpression(pattern: Markdown.inlineMathPattern)
        private static let reInlineCode = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
        private static let reBoldStar = try! NSRegularExpression(pattern: #"\*\*[^*\n]+\*\*"#)
        private static let reBoldUnder = try! NSRegularExpression(pattern: #"__[^_\n]+__"#)
        private static let reStrike = try! NSRegularExpression(pattern: #"~~[^~\n]+~~"#)
        private static let reItalicStar = try! NSRegularExpression(pattern: #"(?<![\w*])\*[^*\n]+\*(?![\w*])"#)
        private static let reItalicUnder = try! NSRegularExpression(pattern: #"(?<![\w_])_[^_\n]+_(?![\w_])"#)
        private static let reLink = try! NSRegularExpression(pattern: #"\[[^\]]+\]\([^)\s]+\)"#)
        private static let reLineMarker = try! NSRegularExpression(pattern: #"(?m)^(\s*)(>|\d+\.|[-*+])(\s)"#)
        private static let reDimBoldStar = try! NSRegularExpression(pattern: #"(\*\*)([^*\n]+)(\*\*)"#)
        private static let reDimBoldUnder = try! NSRegularExpression(pattern: #"(__)([^_\n]+)(__)"#)
        private static let reDimStrike = try! NSRegularExpression(pattern: #"(~~)([^~\n]+)(~~)"#)
        private static let reDimItalicStar = try! NSRegularExpression(pattern: #"(?<![\w*])(\*)([^*\n]+)(\*)(?![\w*])"#)
        private static let reDimItalicUnder = try! NSRegularExpression(pattern: #"(?<![\w_])(_)([^_\n]+)(_)(?![\w_])"#)
        private static let reDimCode = try! NSRegularExpression(pattern: #"(`)([^`\n]+)(`)"#)
        private static let reDimMath = try! NSRegularExpression(pattern: #"(?<![\$\w])(\$)((?:[^$\n]*[^\s$])?)(\$)(?![\d$])"#)

        static func highlight(_ textView: NSTextView, fontSize: CGFloat) {
            guard let storage = textView.textStorage else { return }
            let plain = NSFont.systemFont(ofSize: fontSize)
            let bold = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let mono = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
            let heading = NSFont.systemFont(ofSize: fontSize + 2, weight: .semibold)
            let marker = NSColor.tertiaryLabelColor
            let accent = NSColor.controlAccentColor
            let codeBg = NSColor.controlAccentColor.withAlphaComponent(0.12)
            let mathColor = NSColor.systemPurple

            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([
                .font: plain,
                .foregroundColor: NSColor.labelColor,
            ], range: full)

            let s = textView.string
            let ns = s as NSString

            func apply(_ re: NSRegularExpression, attrs: [NSAttributedString.Key: Any]) {
                re.enumerateMatches(in: s, options: [], range: full) { match, _, _ in
                    guard let match else { return }
                    storage.addAttributes(attrs, range: match.range)
                }
            }

            // Fenced code blocks (line-based).
            let fenceMatches = reFence.matches(in: s, range: full)
            var fi = 0
            while fi + 1 < fenceMatches.count {
                let a = fenceMatches[fi].range
                let b = fenceMatches[fi + 1].range
                let block = NSRange(location: a.location,
                                    length: NSMaxRange(b) - a.location)
                storage.addAttributes([
                    .font: mono,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: codeBg,
                ], range: block)
                storage.addAttributes([.foregroundColor: marker], range: a)
                storage.addAttributes([.foregroundColor: marker], range: b)
                fi += 2
            }

            // Headings: whole line slightly larger; # markers dimmed.
            reHeading.enumerateMatches(in: s, range: full) { match, _, _ in
                guard let match, match.numberOfRanges >= 4 else { return }
                storage.addAttributes([.font: heading, .foregroundColor: NSColor.labelColor],
                                      range: match.range)
                storage.addAttributes([.foregroundColor: marker, .font: plain],
                                      range: match.range(at: 1))
            }

            apply(reDisplayMath, attrs: [.font: mono, .foregroundColor: mathColor])
            apply(reInlineMath, attrs: [.font: mono, .foregroundColor: mathColor])
            apply(reInlineCode, attrs: [
                .font: mono, .foregroundColor: accent, .backgroundColor: codeBg,
            ])
            apply(reBoldStar, attrs: [.font: bold])
            apply(reBoldUnder, attrs: [.font: bold])
            apply(reStrike, attrs: [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
            apply(reItalicStar, attrs: [.obliqueness: 0.15])
            apply(reItalicUnder, attrs: [.obliqueness: 0.15])
            apply(reLink, attrs: [
                .foregroundColor: accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])

            reLineMarker.enumerateMatches(in: s, range: full) { match, _, _ in
                guard let match, match.numberOfRanges >= 3 else { return }
                storage.addAttributes([.foregroundColor: marker], range: match.range(at: 2))
            }

            dimMarkers(in: storage, string: ns, re: reDimBoldStar)
            dimMarkers(in: storage, string: ns, re: reDimBoldUnder)
            dimMarkers(in: storage, string: ns, re: reDimStrike)
            dimMarkers(in: storage, string: ns, re: reDimItalicStar)
            dimMarkers(in: storage, string: ns, re: reDimItalicUnder)
            dimMarkers(in: storage, string: ns, re: reDimCode)
            dimMarkers(in: storage, string: ns, re: reDimMath)

            storage.endEditing()
        }

        private static func dimMarkers(in storage: NSTextStorage, string: NSString,
                                       re: NSRegularExpression) {
            let full = NSRange(location: 0, length: string.length)
            let marker = NSColor.tertiaryLabelColor
            re.enumerateMatches(in: string as String, range: full) { match, _, _ in
                guard let match, match.numberOfRanges >= 4 else { return }
                storage.addAttributes([.foregroundColor: marker], range: match.range(at: 1))
                storage.addAttributes([.foregroundColor: marker], range: match.range(at: 3))
            }
        }
    }
}

/// NSTextView that claims markdown formatting key equivalents and reports
/// first-responder focus (not just the editing session).
final class ComposeBodyTextView: NSTextView {
    var onFormat: ((ComposeBodyEditor.FormatAction) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)
        let opt = flags.contains(.option)
        // Only plain ⌘ / ⌘⇧ / ⌘⌥ — leave control chords alone.
        guard cmd, !flags.contains(.control) else {
            return super.performKeyEquivalent(with: event)
        }
        // Symbol keys: `charactersIgnoringModifiers` still reflects Shift, so
        // ⌘⇧8 arrives as "*" and ⌘⇧. as ">". Match keyCodes (ANSI layout).
        // kVK_ANSI_8 = 28, kVK_ANSI_Period = 47.
        if shift, !opt {
            switch event.keyCode {
            case 28: onFormat?(.bullet); return true
            case 47: onFormat?(.quote); return true
            default: break
            }
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (key, shift, opt) {
        case ("b", false, false): onFormat?(.bold); return true
        case ("i", false, false): onFormat?(.italic); return true
        case ("x", true, false):  onFormat?(.strikethrough); return true
        case ("e", false, false): onFormat?(.code); return true
        case ("m", true, false):  onFormat?(.math); return true
        // ⌘⇧V = paste without formatting (Slack/Chrome/VS Code convention).
        // Body is already plain-text markdown, so this matches ⌘V / system
        // paste — but ⌘⇧V is not bound by default and would otherwise no-op.
        case ("v", true, false):
            pasteAsPlainText(nil)
            return true
        // ⌘K is owned by ComposeView's link sheet (local key monitor) — don't
        // also inject raw `[text](url)` here or the sheet never opens.
        case ("1", false, true):  onFormat?(.heading1); return true
        case ("2", false, true):  onFormat?(.heading2); return true
        case ("3", false, true):  onFormat?(.heading3); return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

// MARK: - Format toolbar

/// Compact markdown format strip for the compose footer.
struct ComposeFormatBar: View {
    let action: (ComposeBodyEditor.FormatAction) -> Void

    var body: some View {
        HStack(spacing: 2) {
            fmt("bold", "Bold (⌘B)") { action(.bold) }
            fmt("italic", "Italic (⌘I)") { action(.italic) }
            fmt("strikethrough", "Strikethrough (⌘⇧X)") { action(.strikethrough) }
            fmt("chevron.left.forwardslash.chevron.right", "Code (⌘E)") { action(.code) }
            Divider().frame(height: 12).padding(.horizontal, 2)
            fmt("number", "Heading (⌘⌥1)") { action(.heading1) }
            fmt("text.quote", "Quote (⌘⇧.)") { action(.quote) }
            fmt("list.bullet", "Bullet list (⌘⇧8)") { action(.bullet) }
            fmt("function", "Math (⌘⇧M)") { action(.math) }
            fmt("link", "Link (⌘K)") { action(.link) }
        }
    }

    private func fmt(_ systemName: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        // Help strings are "Bold (⌘B)" — VoiceOver label is the bare action name.
        let label = help.split(separator: " (").first.map(String.init) ?? help
        return Button(action: act) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}
