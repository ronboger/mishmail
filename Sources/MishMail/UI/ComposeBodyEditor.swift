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
    /// Gmail-style grey suffix drawn after the caret (greeting autocomplete).
    /// Not part of the model string — Tab in ComposeView commits it.
    var ghostText: String = ""
    var formatTarget: ComposeBodyFormatTarget?
    var fontSize: CGFloat = 14
    /// Files dropped on the body (Finder / other apps) — attach, don't insert
    /// paths into the markdown source.
    var onFilesDropped: (([URL]) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, caretUTF16: $caretUTF16,
                    formatTarget: formatTarget, onFilesDropped: onFilesDropped)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposeBodyTextView()
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        // Natural writing direction so Hebrew/Arabic paragraphs base RTL
        // while English stays LTR (per first strong character / keyboard).
        textView.baseWritingDirection = .natural
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        // Keep markdown source literal — curly quotes break `**` / `$`.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        // Opaque fill matching the compose card so partial glyph updates after
        // delete never leave trails (drawsBackground=false + custom ghost draw
        // used to retain deleted characters under the caret).
        textView.backgroundColor = .windowBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        // Match TextEditor's ~5pt line fragment padding cancel used in ComposeView.
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        // minSize defaults to the initial frame; leave it at zero so the
        // first layout pass (often 0×0 from SwiftUI) can't pin a stale width.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.onFormat = { [weak coord = context.coordinator] action in
            coord?.apply(action)
        }
        textView.onFocusChange = { [weak coord = context.coordinator] focused in
            coord?.isFocused.wrappedValue = focused
        }
        textView.onFilesDropped = { [weak coord = context.coordinator] urls in
            coord?.onFilesDropped?(urls)
        }
        // Do NOT call registerForDraggedTypes here — NSView replaces (not
        // merges) the type set, which would wipe NSTextView's built-in
        // string/RTF/image registrations and break text drags into the body.
        // NSTextView already accepts .fileURL; performDragOperation intercepts.
        textView.ghostText = ghostText
        context.coordinator.bindFormatTarget()
        Coordinator.highlight(textView, fontSize: fontSize)

        // OverlayComposeScrollView pins scrollerStyle so AppKit can't flip
        // back to legacy when a mouse is plugged in / "Always show scroll bars"
        // is on (that flip used to reflow the body on the next Enter).
        let scroll = OverlayComposeScrollView()
        // Match the text view so the gutter never shows a different clear/erase
        // path than the body (stale pixels on delete lived in that mismatch).
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.borderType = .noBorder
        scroll.documentView = textView
        context.coordinator.fontSize = fontSize
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.fontSize = fontSize
        context.coordinator.formatTarget = formatTarget
        context.coordinator.onFilesDropped = onFilesDropped
        context.coordinator.bindFormatTarget()
        guard let textView = scroll.documentView as? ComposeBodyTextView else { return }
        context.coordinator.textView = textView
        textView.onFilesDropped = { [weak coord = context.coordinator] urls in
            coord?.onFilesDropped?(urls)
        }

        if textView.string != text {
            // Suppress publishCaret while rewriting: assigning string and
            // setSelectedRange both fire textViewDidChangeSelection
            // synchronously, and writing the binding mid-updateNSView is
            // "modifying state during view update". Callers that rewrite
            // body_ also set caretUTF16 to the intended park position.
            let coord = context.coordinator
            coord.isProgrammaticUpdate = true
            // Invalidate any prior ghost before the string rewrite so old
            // overlay pixels can't sit on top of the new layout.
            textView.invalidateGhostDisplay()
            textView.string = text
            let maxLen = (text as NSString).length
            let loc = min(max(caretUTF16, 0), maxLen)
            textView.setSelectedRange(NSRange(location: loc, length: 0))
            // Keep the guard up through highlight so a future attribute/text
            // mutation inside it can't leak a binding write mid-update.
            Coordinator.highlight(textView, fontSize: fontSize)
            coord.isProgrammaticUpdate = false
        }

        if textView.ghostText != ghostText {
            textView.ghostText = ghostText
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
        var onFilesDropped: (([URL]) -> Void)?
        weak var textView: ComposeBodyTextView?
        var fontSize: CGFloat = 14
        /// True while updateNSView (or another external rewrite) is driving
        /// the text view — selection-change callbacks must not write the
        /// caret binding (SwiftUI forbids state mutation during view update).
        var isProgrammaticUpdate = false

        init(text: Binding<String>, isFocused: Binding<Bool>,
             caretUTF16: Binding<Int>,
             formatTarget: ComposeBodyFormatTarget?,
             onFilesDropped: (([URL]) -> Void)?) {
            self.text = text
            self.isFocused = isFocused
            self.caretUTF16 = caretUTF16
            self.formatTarget = formatTarget
            self.onFilesDropped = onFilesDropped
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
            // Ghost is drawn outside the text system — force a full body
            // redraw after every edit so deleted glyphs + old ghost suffix
            // never leave a double-image under the caret.
            if let body = textView as? ComposeBodyTextView {
                body.invalidateGhostDisplay()
                body.needsDisplay = true
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            publishCaret(textView)
            // Selection moves the ghost anchor (or hides it when length > 0).
            // Property `ghostText` may be unchanged, so didSet won't redraw.
            if let body = textView as? ComposeBodyTextView {
                body.invalidateGhostDisplay()
            }
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
            // Base font/color only — paragraph BiDi + URL isolation are
            // re-applied below so setAttributes does not leave an LTR-only
            // surface after every keystroke.
            storage.setAttributes([
                .font: plain,
                .foregroundColor: NSColor.labelColor,
            ], range: full)

            let s = textView.string
            let ns = s as NSString

            applyBidiAttributes(to: storage, string: s, fullRange: full)

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
            // Markdown links + bare autolinkable URLs/hosts (same spans
            // htmlFragment turns into anchors) — blue without requiring
            // a [url](url) wrap that doubles the plain-text body.
            let linkAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            for range in ComposeLinks.editorLinkStyleRanges(in: s) {
                storage.addAttributes(linkAttrs, range: range)
            }

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

        /// Per-paragraph base writing direction + LTR isolation on bare URLs.
        /// Does not mutate the plain `string` model — attributes only — so
        /// drafts/send stay free of FSI/PDI control characters.
        private static func applyBidiAttributes(to storage: NSTextStorage,
                                                string: String,
                                                fullRange: NSRange) {
            guard fullRange.length > 0 else { return }
            let ns = string as NSString

            // Paragraph base direction from first strong character.
            // Style range includes the paragraph terminator (`paraEnd`) so
            // AppKit fixAttributes sees a uniform style across the whole
            // paragraph; direction is still detected from content only.
            var paraStart = 0
            while paraStart <= ns.length {
                let rest = NSRange(location: paraStart, length: ns.length - paraStart)
                var paraEnd = NSMaxRange(rest)
                var contentsEnd = paraEnd
                if rest.length > 0 {
                    ns.getParagraphStart(nil, end: &paraEnd,
                                         contentsEnd: &contentsEnd,
                                         for: NSRange(location: paraStart, length: 0))
                }
                let styleLen = max(0, paraEnd - paraStart)
                if styleLen > 0 {
                    let styleRange = NSRange(location: paraStart, length: styleLen)
                    let contentLen = max(0, contentsEnd - paraStart)
                    let paraText = contentLen > 0
                        ? ns.substring(with: NSRange(location: paraStart, length: contentLen))
                        : ""
                    let style = NSMutableParagraphStyle()
                    style.alignment = .natural
                    switch TextDirection.base(of: paraText) {
                    case .rtl:
                        style.baseWritingDirection = .rightToLeft
                    case .ltr:
                        style.baseWritingDirection = .leftToRight
                    case .neutral:
                        style.baseWritingDirection = .natural
                    }
                    storage.addAttribute(.paragraphStyle, value: style, range: styleRange)
                }
                if paraEnd <= paraStart { break }
                paraStart = paraEnd
            }

            // Isolate bare URLs as LTR embeddings so Hebrew+URL lines do not
            // visually shred (Unicode Bidirectional Algorithm).
            // Embedding (not isolate) is the best AppKit attribute can do —
            // true FSI would require control chars in the model string.
            // writingDirection: NSWritingDirection | NSWritingDirectionFormatType
            let ltrEmbed = NSNumber(value:
                NSWritingDirection.leftToRight.rawValue
                | NSWritingDirectionFormatType.embedding.rawValue)
            for range in TextDirection.ltrIsolateNSRanges(in: string) {
                guard NSIntersectionRange(range, fullRange).length == range.length
                else { continue }
                storage.addAttribute(.writingDirection, value: [ltrEmbed], range: range)
            }
        }
    }
}

/// NSScrollView that never yields to legacy scrollers.
///
/// AppKit resets `scrollerStyle` when `NSScroller.preferredScrollerStyle`
/// changes (mouse connect, System Settings). Legacy style steals ~15pt of
/// clip width the moment the body overflows — the Enter-key reflow jump.
/// Forcing overlay here (not just in makeNSView) closes the one-frame window
/// where a style flip could still reflow before the next updateNSView.
final class OverlayComposeScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        super.scrollerStyle = .overlay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        super.scrollerStyle = .overlay
    }
}

/// NSTextView that claims markdown formatting key equivalents and reports
/// first-responder focus (not just the editing session).
final class ComposeBodyTextView: NSTextView {
    var onFormat: ((ComposeBodyEditor.FormatAction) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    /// Finder / other-app file drops → compose attachments (not path text).
    var onFilesDropped: (([URL]) -> Void)?
    /// Grey ghost suffix after the caret (greeting autocomplete). Drawn only;
    /// never part of `string` / the SwiftUI binding.
    var ghostText: String = "" {
        didSet {
            if oldValue != ghostText { invalidateGhostDisplay() }
        }
    }
    /// Last rect where ghost text was painted — invalidated on move/clear so
    /// partial dirty-rects after delete can't leave a double image.
    private var lastGhostRect: NSRect = .null

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

    /// Mark the previous ghost overlay dirty.
    ///
    /// Always full-view redraw: the overlay is drawn outside the text system,
    /// so partial dirty rects alone aren't enough after delete/selection moves.
    /// `lastGhostRect` is still tracked for future tighter invalidation.
    func invalidateGhostDisplay() {
        if !lastGhostRect.isNull {
            setNeedsDisplay(lastGhostRect.insetBy(dx: -4, dy: -4))
        }
        lastGhostRect = .null
        needsDisplay = true
    }

    override func setSelectedRanges(_ ranges: [NSValue],
                                    affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        invalidateGhostDisplay()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // New caret/selection may need ghost at a different anchor.
        if !ghostText.isEmpty { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGhostText()
    }

    /// Gmail-style tertiary label ghost after a zero-length caret.
    private func drawGhostText() {
        guard !ghostText.isEmpty else {
            lastGhostRect = .null
            return
        }
        let sel = selectedRange()
        guard sel.length == 0 else {
            lastGhostRect = .null
            return
        }
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let font = self.font ?? NSFont.systemFont(ofSize: 14)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let origin = textContainerOrigin
        let charIndex = min(sel.location, (string as NSString).length)
        let drawPoint: NSPoint
        if (string as NSString).length == 0 {
            // Empty body: prefer the layout manager's extra line fragment
            // (real caret metrics) over a hand-rolled origin pin.
            let extra = lm.extraLineFragmentUsedRect
            if extra.height > 0 {
                drawPoint = NSPoint(x: origin.x + extra.minX, y: origin.y + extra.minY)
            } else {
                drawPoint = NSPoint(
                    x: origin.x + tc.lineFragmentPadding,
                    y: origin.y)
            }
        } else {
            // Prefer caret rect from firstRect — handles trailing spaces and
            // end-of-document without zero-width boundingRect glitches.
            let caretRange = NSRange(location: charIndex, length: 0)
            let caretRect = firstRect(forCharacterRange: caretRange, actualRange: nil)
            if caretRect.height > 0, let win = window {
                // firstRect is in screen coords; convert into this view.
                let inWindow = win.convertFromScreen(caretRect)
                let inView = convert(inWindow, from: nil)
                drawPoint = NSPoint(x: inView.minX, y: inView.minY)
            } else {
                let length = (string as NSString).length
                if charIndex >= length {
                    var used = lm.usedRect(for: tc)
                    if lm.extraLineFragmentUsedRect.height > 0 {
                        used = lm.extraLineFragmentUsedRect
                        drawPoint = NSPoint(x: origin.x + used.minX,
                                            y: origin.y + used.minY)
                    } else {
                        let lastChar = max(0, length - 1)
                        let g = lm.glyphIndexForCharacter(at: lastChar)
                        var lineRange = NSRange()
                        let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &lineRange)
                        let loc = lm.location(forGlyphAt: g)
                        let glyphW = lm.boundingRect(
                            forGlyphRange: NSRange(location: g, length: 1),
                            in: tc).width
                        drawPoint = NSPoint(x: origin.x + loc.x + glyphW,
                                            y: origin.y + line.minY)
                    }
                } else {
                    let g = lm.glyphIndexForCharacter(at: charIndex)
                    var lineRange = NSRange()
                    let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &lineRange)
                    let loc = lm.location(forGlyphAt: g)
                    drawPoint = NSPoint(x: origin.x + loc.x, y: origin.y + line.minY)
                }
            }
        }
        // Flipped view: draw(at:) treats y as the top of the string's box when
        // using NSStringDrawing with default (we center within line height).
        let size = (ghostText as NSString).size(withAttributes: attrs)
        let lineH = lm.extraLineFragmentRect.height > 0
            ? lm.extraLineFragmentRect.height
            : font.boundingRectForFont.height
        let y = drawPoint.y + max(0, (lineH - size.height) / 2)
        let originDraw = NSPoint(x: drawPoint.x, y: y)
        lastGhostRect = NSRect(origin: originDraw, size: size)
        (ghostText as NSString).draw(at: originDraw, withAttributes: attrs)
    }

    // MARK: - File drag → attachments

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if ComposeAttachmentDrop.containsFileURLs(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if ComposeAttachmentDrop.containsFileURLs(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if ComposeAttachmentDrop.containsFileURLs(sender.draggingPasteboard) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = ComposeAttachmentDrop.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else {
            return super.performDragOperation(sender)
        }
        // Never insert file paths / NSTextAttachments into the markdown body.
        onFilesDropped?(urls)
        return true
    }

    /// `scrollRangeToVisible` (caret after Return) can nudge the clip view
    /// horizontally when document width and clip width disagree by a pixel —
    /// classic NSTextView "body jumps sideways while typing" failure mode.
    /// Pin origin.x so the body never drifts while typing newlines.
    override func scrollRangeToVisible(_ charRange: NSRange) {
        super.scrollRangeToVisible(charRange)
        pinHorizontalScroll()
    }

    override func layout() {
        super.layout()
        pinHorizontalScroll()
    }

    private func pinHorizontalScroll() {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        guard abs(clip.bounds.origin.x) > 0.01 else { return }
        var origin = clip.bounds.origin
        origin.x = 0
        clip.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(clip)
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
///
/// Link lives on the dedicated footer button (⌘K sheet), not here — a second
/// chain icon at the trailing edge was the first thing clipped when the left
/// cluster ran out of room.
struct ComposeFormatBar: View {
    let action: (ComposeBodyEditor.FormatAction) -> Void
    /// Raw values from `ComposeToolbarVisibility.storageKey` (empty = show all).
    var hiddenRaw: String = ""

    private var visible: [ComposeToolbarItem] {
        ComposeToolbarItem.formatOrder.filter {
            ComposeToolbarVisibility.isVisible($0, hiddenRaw: hiddenRaw)
        }
    }

    var body: some View {
        let items = visible
        // Split at the first "structure" control so the bar keeps a hairline
        // between character styles and block markers when both sides exist.
        let styleEnd = items.firstIndex(where: {
            switch $0 {
            case .heading, .quote, .bullet, .math: return true
            default: return false
            }
        }) ?? items.endIndex
        let styles = Array(items.prefix(styleEnd))
        let structure = Array(items.suffix(from: styleEnd))

        return HStack(spacing: 2) {
            ForEach(styles) { item in
                fmt(item) { run(item) }
            }
            if !styles.isEmpty, !structure.isEmpty {
                Divider().frame(height: 12).padding(.horizontal, 2)
            }
            ForEach(structure) { item in
                fmt(item) { run(item) }
            }
        }
    }

    private func run(_ item: ComposeToolbarItem) {
        switch item {
        case .bold: action(.bold)
        case .italic: action(.italic)
        case .strikethrough: action(.strikethrough)
        case .code: action(.code)
        case .heading: action(.heading1)
        case .quote: action(.quote)
        case .bullet: action(.bullet)
        case .math: action(.math)
        case .attach, .link, .snippets, .ai: break
        }
    }

    private func fmt(_ item: ComposeToolbarItem, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: item.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                // 24×22 so wide glyphs (function / list) aren't optically clipped
                // inside the icon cell.
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.help)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("composeFormat.\(item.rawValue)")
    }
}
