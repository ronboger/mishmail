import Foundation

/// Compose-body markdown: a small, email-friendly subset with math delimiters.
///
/// Source of truth in the editor stays as plain text (markdown). On send/draft
/// we optionally attach an HTML alternative so bold/headers/math actually render
/// for recipients. No third-party markdown package — the subset is intentional
/// and fully unit-tested.
enum Markdown {

    // MARK: - Shared patterns

    /// Pandoc-style inline math: opening `$` not after word/`$` and not before
    /// space/`$`; closing `$` not after space and not before a digit. Rejects
    /// money prose like `$5 and $10` while still matching `$E=mc^2$`.
    static let inlineMathPattern =
        #"(?<![\$\w])\$(?![\s$])((?:[^$\n]*[^\s$])?)\$(?![\d$])"#

    // MARK: - Detection

    /// True when the body uses syntax that should become an HTML alternative.
    /// Conservative enough to leave ordinary prose as plain-only, generous
    /// enough that intentional formatting is not dropped.
    static func looksLikeMarkdown(_ text: String) -> Bool {
        if text.contains("```") { return true }
        if text.contains("**") || text.contains("__") { return true }
        if text.contains("~~") { return true }
        if text.range(of: #"\[.+?\]\(.+?\)"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"(?m)^#{1,6}\s+\S"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"(?m)^>\s"#, options: .regularExpression) != nil { return true }
        // Lists: require ≥2 consecutive items so a sign-off like `- Ron` or a
        // lone `2026. …` line doesn't force an HTML part.
        if text.range(of: #"(?m)^(\s*[-*+])\s+\S.*\n(\s*[-*+])\s+\S"#,
                      options: .regularExpression) != nil { return true }
        if text.range(of: #"(?m)^(\s*\d+\.)\s+\S.*\n(\s*\d+\.)\s+\S"#,
                      options: .regularExpression) != nil { return true }
        // Inline code, but not a bare backtick (typo).
        if text.range(of: #"`[^`\n]+`"#, options: .regularExpression) != nil { return true }
        // Emphasis: *word* or _word_ (not bare asterisks used as bullets alone).
        if text.range(of: #"(?<![\w*])\*[^*\n]+\*(?![\w*])"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"(?<![\w_])_[^_\n]+_(?![\w_])"#, options: .regularExpression) != nil {
            return true
        }
        // Math: $...$ or $$...$$ with non-empty interior (Pandoc rules for $).
        if text.range(of: #"\$\$[^$]+\$\$"#, options: .regularExpression) != nil { return true }
        if text.range(of: inlineMathPattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    // MARK: - HTML

    /// Full-body markdown → HTML fragment suitable for a multipart/alternative
    /// text/html part. Blank lines split paragraphs; fenced code and display
    /// math keep their internal newlines.
    static func toHTML(_ source: String) -> String {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // Drop a single trailing empty line so the last block isn't blank.
        while lines.last == "" { lines.removeLast() }
        if lines.isEmpty { return "" }

        var html: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Fenced code block.
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") {
                    body.append(escapeHTML(lines[i]))
                    i += 1
                }
                if i < lines.count { i += 1 }  // closing fence
                let classAttr = lang.isEmpty ? "" : " class=\"language-\(escapeAttr(lang))\""
                html.append("<pre><code\(classAttr)>\(body.joined(separator: "\n"))</code></pre>")
                continue
            }

            // Display math $$...$$ (single line or multi until closing $$).
            // Unclosed `$$` falls through as a normal paragraph so it cannot
            // swallow the rest of the message into a centered math div.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("$$") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Single-line $$...$$ (content between the two delimiters).
                if trimmed != "$$", trimmed.hasSuffix("$$"), trimmed.count >= 4 {
                    let chunk = String(trimmed.dropFirst(2).dropLast(2))
                    html.append(renderDisplayMath(chunk))
                    i += 1
                    continue
                }
                // Multi-line: open on this line, close on a later line ending $$.
                var chunk = trimmed == "$$" ? "" : String(trimmed.dropFirst(2))
                var j = i + 1
                var closed = false
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.hasSuffix("$$") {
                        let inner = t == "$$" ? "" : String(t.dropLast(2))
                        if !inner.isEmpty {
                            chunk = chunk.isEmpty ? inner : chunk + "\n" + inner
                        }
                        closed = true
                        j += 1
                        break
                    }
                    chunk = chunk.isEmpty ? lines[j] : chunk + "\n" + lines[j]
                    j += 1
                }
                if closed {
                    html.append(renderDisplayMath(chunk))
                    i = j
                    continue
                }
                // No closer — emit the opening line as a normal paragraph and
                // advance (must not fall through or `i` stalls forever on `$$`).
                html.append("<p>\(inlineHTML(line))</p>")
                i += 1
                continue
            }

            // Blank line → paragraph break.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // ATX headings.
            if let heading = parseHeading(line) {
                html.append("<h\(heading.level)>\(inlineHTML(heading.text))</h\(heading.level)>")
                i += 1
                continue
            }

            // Horizontal rule.
            if isHorizontalRule(line) {
                html.append("<hr>")
                i += 1
                continue
            }

            // Blockquote (consecutive > lines).
            if line.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count, lines[i].hasPrefix(">") {
                    var q = lines[i]
                    q.removeFirst()  // >
                    if q.hasPrefix(" ") { q.removeFirst() }
                    quoted.append(q)
                    i += 1
                }
                // Nested markdown inside quotes is rendered as plain lines with
                // inline markup — good enough for reply trails.
                let inner = quoted.map { inlineHTML($0) }.joined(separator: "<br>")
                html.append("<blockquote type=\"cite\">\(inner)</blockquote>")
                continue
            }

            // Unordered list.
            if isUnorderedItem(line) {
                var items: [String] = []
                while i < lines.count, isUnorderedItem(lines[i]) {
                    items.append(inlineHTML(stripListMarker(lines[i])))
                    i += 1
                }
                html.append("<ul>" + items.map { "<li>\($0)</li>" }.joined() + "</ul>")
                continue
            }

            // Ordered list.
            if isOrderedItem(line) {
                var items: [String] = []
                while i < lines.count, isOrderedItem(lines[i]) {
                    items.append(inlineHTML(stripOrderedMarker(lines[i])))
                    i += 1
                }
                html.append("<ol>" + items.map { "<li>\($0)</li>" }.joined() + "</ol>")
                continue
            }

            // Paragraph: gather consecutive non-special lines.
            var para: [String] = []
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if l.hasPrefix("```") || l.trimmingCharacters(in: .whitespaces).hasPrefix("$$") { break }
                if parseHeading(l) != nil || isHorizontalRule(l) { break }
                if l.hasPrefix(">") || isUnorderedItem(l) || isOrderedItem(l) { break }
                para.append(l)
                i += 1
            }
            // Safety: never stall if a "special" line matched no handler above.
            if para.isEmpty {
                html.append("<p>\(inlineHTML(lines[i]))</p>")
                i += 1
            } else {
                html.append("<p>\(para.map { inlineHTML($0) }.joined(separator: "<br>"))</p>")
            }
        }
        return html.joined(separator: "\n")
    }

    // MARK: - Inline formatting for the editor

    /// Wraps (or unwraps) a selection with `open`/`close` markers.
    /// Returns the new full string and the selection range after the edit
    /// (UTF-16 indices, NSTextView-compatible).
    static func toggleWrap(_ text: String, selection: NSRange,
                           open: String, close: String) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard selection.location != NSNotFound,
              NSIntersectionRange(selection, full).length == selection.length,
              selection.location + selection.length <= ns.length
        else { return (text, selection) }

        // Already wrapped? Strip the markers.
        if selection.location >= (open as NSString).length {
            let beforeLoc = selection.location - (open as NSString).length
            let afterLoc = selection.location + selection.length
            let afterEnd = afterLoc + (close as NSString).length
            if afterEnd <= ns.length {
                let before = ns.substring(with: NSRange(location: beforeLoc, length: (open as NSString).length))
                let after = ns.substring(with: NSRange(location: afterLoc, length: (close as NSString).length))
                if before == open && after == close,
                   !isHalfOfDoubleMarker(ns, open: open, beforeLoc: beforeLoc, afterEnd: afterEnd) {
                    let stripped = ns.replacingCharacters(
                        in: NSRange(location: beforeLoc,
                                    length: selection.length
                                        + (open as NSString).length
                                        + (close as NSString).length),
                        with: ns.substring(with: selection))
                    return (stripped, NSRange(location: beforeLoc, length: selection.length))
                }
            }
        }
        // Selection itself includes the markers.
        if selection.length >= (open as NSString).length + (close as NSString).length {
            let head = ns.substring(with: NSRange(location: selection.location,
                                                  length: (open as NSString).length))
            let tailLoc = selection.location + selection.length - (close as NSString).length
            let tail = ns.substring(with: NSRange(location: tailLoc, length: (close as NSString).length))
            if head == open && tail == close {
                let inner = ns.substring(with: NSRange(
                    location: selection.location + (open as NSString).length,
                    length: selection.length - (open as NSString).length - (close as NSString).length))
                let stripped = ns.replacingCharacters(in: selection, with: inner)
                return (stripped, NSRange(location: selection.location, length: (inner as NSString).length))
            }
        }

        // Empty selection → insert markers and park the caret between them.
        if selection.length == 0 {
            let insert = open + close
            let replaced = ns.replacingCharacters(in: selection, with: insert)
            return (replaced, NSRange(location: selection.location + (open as NSString).length, length: 0))
        }

        let wrapped = open + ns.substring(with: selection) + close
        let replaced = ns.replacingCharacters(in: selection, with: wrapped)
        return (replaced, NSRange(location: selection.location + (open as NSString).length,
                                  length: selection.length))
    }

    /// Prefixes each line of the selection with `prefix` (e.g. "# ", "> ", "- ").
    /// If every line already has it, strips instead. Heading prefixes strip any
    /// existing `#{1,6} ` level first so ⌘⌥2 on `# Title` becomes `## Title`.
    static func toggleLinePrefix(_ text: String, selection: NSRange,
                                 prefix: String) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        guard selection.location != NSNotFound, selection.location <= ns.length else {
            return (text, selection)
        }
        // Expand to whole lines.
        var start = selection.location
        while start > 0, ns.character(at: start - 1) != 10 /* \n */ { start -= 1 }
        var end = selection.location + max(selection.length, 0)
        if end > ns.length { end = ns.length }
        // Caret on a line (empty or not): include that line.
        if selection.length == 0 {
            while end < ns.length, ns.character(at: end) != 10 { end += 1 }
        } else if end > start, end < ns.length, ns.character(at: end - 1) != 10 {
            while end < ns.length, ns.character(at: end) != 10 { end += 1 }
        }
        // Empty document: insert the prefix alone.
        if ns.length == 0 {
            return (prefix, NSRange(location: 0, length: (prefix as NSString).length))
        }
        let blockRange = NSRange(location: start, length: end - start)
        // Caret on empty line at EOF with zero-width block: insert prefix.
        if blockRange.length == 0 {
            let result = ns.replacingCharacters(in: blockRange, with: prefix)
            return (result, NSRange(location: start, length: (prefix as NSString).length))
        }
        let block = ns.substring(with: blockRange)
        let lines = block.components(separatedBy: "\n")
        let isHeading = prefix.hasPrefix("#")
        let allPrefixed = lines.allSatisfy {
            $0.hasPrefix(prefix) || $0.isEmpty
        } && lines.contains(where: { !$0.isEmpty && $0.hasPrefix(prefix) })

        let newLines: [String]
        if allPrefixed {
            newLines = lines.map { line in
                guard line.hasPrefix(prefix) else { return line }
                return String(line.dropFirst(prefix.count))
            }
        } else {
            newLines = lines.map { line in
                var base = line
                if isHeading { base = stripHeadingPrefix(base) }
                // Empty lines still get the marker (Gmail-style on a fresh line).
                if base.isEmpty { return prefix }
                return base.hasPrefix(prefix) ? base : prefix + base
            }
        }
        let replacement = newLines.joined(separator: "\n")
        let result = ns.replacingCharacters(in: blockRange, with: replacement)
        return (result, NSRange(location: start, length: (replacement as NSString).length))
    }

    private static func stripHeadingPrefix(_ line: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"^#{1,6}\s+"#),
              let m = re.firstMatch(in: line,
                                    range: NSRange(location: 0, length: (line as NSString).length)),
              let r = Range(m.range, in: line) else { return line }
        return String(line[r.upperBound...])
    }

    /// True when stripping `open`/`close` around a selection would peel one
    /// character off a longer marker (e.g. italic `*` eating half of `**bold**`).
    private static func isHalfOfDoubleMarker(_ ns: NSString, open: String,
                                             beforeLoc: Int, afterEnd: Int) -> Bool {
        guard open == "*" || open == "_" else { return false }
        let ch = (open as NSString).character(at: 0)
        if beforeLoc > 0, ns.character(at: beforeLoc - 1) == ch { return true }
        if afterEnd < ns.length, ns.character(at: afterEnd) == ch { return true }
        return false
    }

    // MARK: - Math helpers

    /// Light LaTeX-ish cleanup for email: no engine, just readable HTML.
    static func prettyMath(_ latex: String) -> String {
        var s = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        // \frac{a}{b} → (a)/(b)
        if let fracRe = try? NSRegularExpression(pattern: #"\\frac\{([^{}]+)\}\{([^{}]+)\}"#) {
            while true {
                let ns = s as NSString
                let full = NSRange(location: 0, length: ns.length)
                guard let m = fracRe.firstMatch(in: s, range: full),
                      m.numberOfRanges == 3 else { break }
                let a = ns.substring(with: m.range(at: 1))
                let b = ns.substring(with: m.range(at: 2))
                guard let r = Range(m.range, in: s) else { break }
                s.replaceSubrange(r, with: "(\(a))/(\(b))")
            }
        }
        let commands: [(String, String)] = [
            ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
            ("\\epsilon", "ε"), ("\\theta", "θ"), ("\\lambda", "λ"), ("\\mu", "μ"),
            ("\\pi", "π"), ("\\sigma", "σ"), ("\\omega", "ω"), ("\\Omega", "Ω"),
            ("\\sum", "∑"), ("\\prod", "∏"), ("\\int", "∫"), ("\\infty", "∞"),
            ("\\pm", "±"), ("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"),
            ("\\leq", "≤"), ("\\geq", "≥"), ("\\neq", "≠"), ("\\approx", "≈"),
            ("\\rightarrow", "→"), ("\\leftarrow", "←"), ("\\Rightarrow", "⇒"),
            ("\\ldots", "…"), ("\\cdots", "⋯"),
            ("\\sqrt", "√"), ("\\partial", "∂"), ("\\nabla", "∇"),
        ]
        for (cmd, rep) in commands {
            s = s.replacingOccurrences(of: cmd, with: rep)
        }
        // Simple superscripts: x^2, x^{10}
        s = applyScripts(s, open: "^", map: superscripts)
        s = applyScripts(s, open: "_", map: subscripts)
        // Drop remaining braces used only for grouping.
        s = s.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
        return s
    }

    // MARK: - Internals

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var n = 0
        for ch in line {
            if ch == "#" { n += 1; if n > 6 { return nil } }
            else { break }
        }
        guard n >= 1, n <= 6 else { return nil }
        let rest = line.dropFirst(n)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let text = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard !text.isEmpty else { return nil }
        return (n, String(text))
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3 else { return false }
        return t.allSatisfy({ $0 == "-" }) || t.allSatisfy({ $0 == "*" }) || t.allSatisfy({ $0 == "_" })
    }

    private static func isUnorderedItem(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return false }
        let c = t[t.startIndex]
        guard c == "-" || c == "*" || c == "+" else { return false }
        let second = t[t.index(after: t.startIndex)]
        return second == " " || second == "\t"
    }

    private static func isOrderedItem(_ line: String) -> Bool {
        line.range(of: #"^\s*\d+\.\s+\S"#, options: .regularExpression) != nil
    }

    private static func stripListMarker(_ line: String) -> String {
        var t = line
        while t.hasPrefix(" ") || t.hasPrefix("\t") { t.removeFirst() }
        if let c = t.first, c == "-" || c == "*" || c == "+" {
            t.removeFirst()
            while t.hasPrefix(" ") || t.hasPrefix("\t") { t.removeFirst() }
        }
        return t
    }

    private static func stripOrderedMarker(_ line: String) -> String {
        guard let r = line.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) else { return line }
        return String(line[r.upperBound...])
    }

    /// Inline markdown → HTML. Order matters: protect code/math first.
    static func inlineHTML(_ text: String) -> String {
        // Strip object-replacement chars so pasted U+FFFC can't alias placeholders.
        var work = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        var protected: [String] = []

        func protect(_ html: String) -> String {
            protected.append(html)
            return "\u{FFFC}\(protected.count - 1)\u{FFFC}"
        }

        // Inline code `...`
        work = replaceAll(work, pattern: #"`([^`\n]+)`"#) { m in
            protect("<code>\(escapeHTML(m[1]))</code>")
        }
        // Display-style shouldn't appear inline; still handle $$ for safety.
        work = replaceAll(work, pattern: #"\$\$([^$]+)\$\$"#) { m in
            protect(renderDisplayMath(m[1]))
        }
        // Inline math $...$ (Pandoc rules — see `inlineMathPattern`).
        work = replaceAll(work, pattern: inlineMathPattern) { m in
            protect(renderInlineMath(m[1]))
        }
        // Links [text](url) — same allowlist / normalization as ComposeLinks.
        // Invalid schemes stay as raw text and are escaped in the final pass.
        work = replaceAll(work, pattern: #"\[([^\]]*)\]\(([^)\s]+)\)"#) { m in
            guard let href = ComposeLinks.normalizeURL(m[2]) else { return m[0] }
            return protect("<a href=\"\(ComposeLinks.escapeAttribute(href))\">\(escapeHTML(m[1]))</a>")
        }
        // Bare http(s)/mailto URLs (ComposeLinks parity for markdown bodies).
        work = replaceAll(work, pattern: #"(?i)\b((?:https?://|mailto:)[^\s<>\[\]()\"']+)"#) { m in
            var text = m[1]
            while let last = text.last, ".,;:!?)]}\"'".contains(last) { text.removeLast() }
            guard !text.isEmpty, let href = ComposeLinks.normalizeURL(text) else { return m[0] }
            // Trailing punctuation stays outside the anchor; escaped later.
            let trailing = String(m[1].dropFirst(text.count))
            return protect("<a href=\"\(ComposeLinks.escapeAttribute(href))\">\(escapeHTML(text))</a>")
                + trailing
        }
        // Bold ** ** or __ __
        work = replaceAll(work, pattern: #"\*\*([^*\n]+)\*\*"#) { m in
            protect("<strong>\(escapeHTML(m[1]))</strong>")
        }
        work = replaceAll(work, pattern: #"__([^_\n]+)__"#) { m in
            protect("<strong>\(escapeHTML(m[1]))</strong>")
        }
        // Strikethrough
        work = replaceAll(work, pattern: #"~~([^~\n]+)~~"#) { m in
            protect("<del>\(escapeHTML(m[1]))</del>")
        }
        // Italic * * or _ _
        work = replaceAll(work, pattern: #"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#) { m in
            protect("<em>\(escapeHTML(m[1]))</em>")
        }
        work = replaceAll(work, pattern: #"(?<![\w_])_([^_\n]+)_(?![\w_])"#) { m in
            protect("<em>\(escapeHTML(m[1]))</em>")
        }

        // Escape remaining plain text, restore protected spans.
        // Descending index order: later spans may nest earlier placeholders
        // (e.g. `**see `x` here**` → strong wraps a code placeholder).
        var out = escapeHTML(work)
        for (idx, html) in protected.enumerated().reversed() {
            out = out.replacingOccurrences(of: "\u{FFFC}\(idx)\u{FFFC}", with: html)
        }
        return out
    }

    private static func renderInlineMath(_ latex: String) -> String {
        let pretty = escapeHTML(prettyMath(latex))
        return "<span style=\"font-family:Cambria,'Times New Roman',serif;font-style:italic\">\(pretty)</span>"
    }

    private static func renderDisplayMath(_ latex: String) -> String {
        let pretty = escapeHTML(prettyMath(latex))
        return "<div style=\"text-align:center;margin:0.75em 0;font-family:Cambria,'Times New Roman',serif;font-style:italic;font-size:1.05em\">\(pretty)</div>"
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ", "i": "ᵢ", "j": "ⱼ", "n": "ₙ",
    ]

    private static func applyScripts(_ input: String, open: Character,
                                     map: [Character: Character]) -> String {
        var s = input
        // ^{...} or _{...}
        let bracePat = open == "^" ? #"\^\{([^{}]+)\}"# : #"_\{([^{}]+)\}"#
        while let range = s.range(of: bracePat, options: .regularExpression) {
            let inner = String(s[range])
                .drop(while: { $0 != "{" }).dropFirst()
                .prefix(while: { $0 != "}" })
            let mapped = String(inner.map { map[$0] ?? $0 })
            s.replaceSubrange(range, with: mapped)
        }
        // ^2 or _i single char
        let singlePat = open == "^" ? #"\^([0-9n+\-=()])"# : #"_([0-9aeoxijn+\-=()])"#
        while let range = s.range(of: singlePat, options: .regularExpression) {
            let ch = s[range].last!
            s.replaceSubrange(range, with: String(map[ch] ?? ch))
        }
        return s
    }

    private static func escapeHTML(_ s: String) -> String {
        // Match ComposeLinks so linkified + markdown paths escape identically.
        ComposeLinks.escapeText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeAttr(_ s: String) -> String {
        ComposeLinks.escapeAttribute(s)
    }

    /// Regex replace with capture groups as [full, g1, g2, ...].
    private static func replaceAll(_ input: String, pattern: String,
                                   with transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var result = input
        for match in matches.reversed() {
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(groups))
        }
        return result
    }
}
