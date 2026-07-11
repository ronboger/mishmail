import Foundation

/// Converts a Gmail API `GMessage` (format=full) into our local rows.
enum MessageParser {
    static func parse(_ g: GMessage, accountId: String) -> (Message, [AttachmentRow]) {
        func header(_ name: String) -> String {
            g.payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        var text = ""
        var html: String?
        var attachments: [AttachmentRow] = []
        let localId = "\(accountId):\(g.id)"
        collectParts(g.payload, messageId: localId, text: &text, html: &html, attachments: &attachments)
        if text.isEmpty, let html { text = Self.stripHTML(html) }

        let millis = Double(g.internalDate ?? "0") ?? 0
        let labels = g.labelIds ?? []
        let message = Message(
            id: localId,
            accountId: accountId,
            gmailId: g.id,
            threadId: "\(accountId):\(g.threadId)",
            fromHeader: header("From"),
            toHeader: header("To"),
            ccHeader: header("Cc"),
            bccHeader: header("Bcc"),
            subject: header("Subject"),
            date: Date(timeIntervalSince1970: millis / 1000),
            snippet: (g.snippet ?? "").decodingHTMLEntities(),
            bodyText: text,
            bodyHTML: html,
            messageIdHeader: header("Message-ID"),
            referencesHeader: header("References"),
            labelIds: labels.joined(separator: " "),
            isUnread: labels.contains("UNREAD"),
            hasAttachment: !attachments.isEmpty
        )
        return (message, attachments)
    }

    private static func collectParts(_ part: GMessage.Part?, messageId: String,
                                     text: inout String, html: inout String?,
                                     attachments: inout [AttachmentRow]) {
        guard let part else { return }
        if let filename = part.filename, !filename.isEmpty,
           let attachmentId = part.body?.attachmentId {
            attachments.append(AttachmentRow(
                id: nil, messageId: messageId, gmailAttachmentId: attachmentId,
                filename: filename, mimeType: part.mimeType ?? "application/octet-stream",
                size: part.body?.size ?? 0))
        } else if let data = part.body?.data, let decoded = decodeBase64URL(data) {
            switch part.mimeType {
            case "text/plain" where text.isEmpty: text = decoded
            case "text/html" where html == nil: html = decoded
            default: break
            }
        }
        for child in part.parts ?? [] {
            collectParts(child, messageId: messageId, text: &text, html: &html, attachments: &attachments)
        }
    }

    static func decodeBase64URL(_ s: String) -> String? {
        decodeBase64URLData(s).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decodeBase64URLData(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }

    /// Converts an HTML body to readable plain text. Non-content elements
    /// (`<style>`, `<script>`, `<head>`, comments) are removed *with their
    /// contents* — Notion Mail in particular ships a large `<style>` block
    /// whose CSS used to leak into quoted replies. Structural tags become
    /// newlines so paragraphs survive, then entities are decoded.
    static func stripHTML(_ html: String) -> String {
        var s = html
        // Tags whose contents are not message text: drop tag AND contents.
        for tag in ["style", "script", "head", "title"] {
            s = s.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>",
                with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ",
                                   options: .regularExpression)
        // Structure → newlines, before the tags themselves are stripped.
        // Closing tags only: open+close both breaking would leave a blank
        // line between every adjacent paragraph/list item.
        s = s.replacingOccurrences(of: "<br\\s*/?\\s*>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(
            of: "</(p|div|li|ul|ol|h[1-6]|tr|table|blockquote|pre|section|article|header|footer)\\s*>",
            with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        // Tidy: collapse horizontal whitespace per line, trim line edges,
        // and allow at most one blank line between paragraphs.
        var lines: [String] = []
        for raw in s.components(separatedBy: "\n") {
            let line = raw
                .replacingOccurrences(of: "[ \\t\\r\u{00A0}]+", with: " ",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty && (lines.last?.isEmpty ?? true) { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Decodes the common named entities plus numeric forms
    /// (`&#8217;`, `&#x1F600;`). `&amp;` goes last so `&amp;lt;` stays `&lt;`.
    static func decodeEntities(_ s: String) -> String {
        var r = s
        for (entity, ch) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
                             ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            r = r.replacingOccurrences(of: entity, with: ch)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            var result = ""
            var last = r.startIndex
            for m in regex.matches(in: r, range: NSRange(r.startIndex..., in: r)) {
                guard let range = Range(m.range, in: r),
                      let numRange = Range(m.range(at: 1), in: r) else { continue }
                let num = r[numRange]
                let value = num.hasPrefix("x")
                    ? UInt32(num.dropFirst(), radix: 16)
                    : UInt32(num)
                result += r[last..<range.lowerBound]
                if let value, let scalar = Unicode.Scalar(value) {
                    result.append(Character(scalar))
                }
                last = range.upperBound
            }
            result += r[last...]
            r = result
        }
        return r.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The text a reply should quote. Prefer the HTML body — it is what the
    /// reading pane displayed, and older synced rows derived `bodyText` from
    /// HTML with a stripper that leaked CSS — falling back to the plain part.
    static func replyQuotableText(text: String, html: String?) -> String {
        if let html, !html.isEmpty {
            let t = stripHTML(html)
            if !t.isEmpty { return t }
        }
        return text
    }

    /// Extracts a display name from a From header like `Jane Doe <jane@x.com>`.
    static func displayName(fromHeader: String) -> String {
        if let lt = fromHeader.firstIndex(of: "<") {
            let name = fromHeader[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return name }
        }
        return fromHeader.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    /// Extracts a bare email address from an address header.
    /// Tolerates malformed headers (missing or out-of-order angle brackets).
    static func emailAddress(_ header: String) -> String {
        if let lt = header.firstIndex(of: "<"),
           let gt = header.firstIndex(of: ">"),
           lt < gt {
            return String(header[header.index(after: lt)..<gt])
        }
        return header.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    /// Attachment filenames come from the sender. Reduce to a bare filename
    /// so a crafted "../../name" can't write outside a chosen directory.
    static func safeFilename(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        return (base.isEmpty || base == "." || base == "..") ? "attachment" : base
    }

    /// Extensions that typically launch code / installers when "Open" hands
    /// them to Launch Services. Used to prompt before opening — not a hard
    /// block (the user may still need a `.dmg` from someone they trust).
    private static let riskyExtensions: Set<String> = [
        "app", "command", "tool", "workflow", "action", "osax", "scptd",
        "dmg", "pkg", "mpkg", "appimage",
        "sh", "bash", "zsh", "csh", "ksh", "fish",
        "command", "js", "jxa", "py", "rb", "pl", "php", "ps1",
        "exe", "msi", "com", "bat", "cmd", "scr", "jar", "bin",
        "ipa", "apk",
    ]

    /// True when the filename looks executable / installer-like, including
    /// double extensions (`invoice.pdf.app`, `readme.txt.sh`).
    static func isRiskyAttachmentFilename(_ name: String) -> Bool {
        let base = safeFilename(name).lowercased()
        let parts = base.split(separator: ".")
        guard parts.count >= 2 else { return false }
        // Any extension segment that is risky (not only the last) — catches
        // `malware.app.zip` after unzip elsewhere, and `file.pdf.app`.
        return parts.dropFirst().contains { riskyExtensions.contains(String($0)) }
    }

    /// Splits an address-list header on commas, respecting quoted display
    /// names like `"Boger, Ron" <ron@x.com>`.
    static func splitAddresses(_ header: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in header {
            switch ch {
            case "\"":
                inQuotes.toggle()
                current.append(ch)
            case "," where !inQuotes:
                result.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current) }
        return result
    }
}

/// Builds the quoted block for forwarded messages — Gmail-style, with a
/// recognizable marker line instead of `> ` quoting, so the original text
/// survives readably and the send path can tell user text from quote.
///
/// Forwards intentionally start a **new** Gmail conversation (no `threadId`,
/// no `In-Reply-To`) — matching gmail.com / Notion Mail. Context travels in
/// the body: one message ("Forward") or the whole thread ("Forward all").
///
/// The compose editor is plain text, but most mail is HTML. To forward
/// without losing formatting, the send path recomputes this block from the
/// original message(s): if the composed body still ends with it verbatim, the
/// message is upgraded to multipart/alternative with the user's text (links
/// turned into anchors via `ComposeLinks`) on top of the original HTML. If
/// the user edited inside the quoted block, we fall back to regenerating
/// HTML from the whole plain body — the two parts must never disagree.
enum ForwardComposer {
    static let marker = "---------- Forwarded message ---------"

    /// One segment of a forward package (single message, or one turn in
    /// Forward all). Plain `bodyText` is what the compose quote shows and
    /// what the send path must match byte-for-byte; `bodyHTML` upgrades the
    /// MIME alternative when present.
    struct Part: Equatable {
        var fromHeader: String
        var date: Date
        var subject: String
        var toHeader: String
        var ccHeader: String
        var bodyText: String
        var bodyHTML: String?

        /// Prefer HTML-derived text so the plain block matches what the
        /// reading pane showed (older rows sometimes have CSS-leaky bodyText).
        init(message: Message) {
            fromHeader = message.fromHeader
            date = message.date
            subject = message.subject
            toHeader = message.toHeader
            ccHeader = message.ccHeader
            bodyText = MessageParser.replyQuotableText(
                text: message.bodyText, html: message.bodyHTML)
            let html = message.bodyHTML ?? ""
            bodyHTML = html.isEmpty ? nil : html
        }

        init(fromHeader: String, date: Date, subject: String,
             toHeader: String, ccHeader: String, bodyText: String,
             bodyHTML: String? = nil) {
            self.fromHeader = fromHeader
            self.date = date
            self.subject = subject
            self.toHeader = toHeader
            self.ccHeader = ccHeader
            self.bodyText = bodyText
            self.bodyHTML = bodyHTML.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        return f
    }()

    /// Plain-text package: one Gmail-style block per part, oldest first for
    /// Forward all (read top→bottom as the conversation unfolded).
    static func forwardBlock(parts: [Part]) -> String {
        parts.map(singlePlainBlock).joined(separator: "\n\n")
    }

    /// Convenience for a single-message forward (Gmail "Forward").
    static func forwardBlock(fromHeader: String, date: Date, subject: String,
                             toHeader: String, ccHeader: String,
                             bodyText: String) -> String {
        forwardBlock(parts: [
            Part(fromHeader: fromHeader, date: date, subject: subject,
                 toHeader: toHeader, ccHeader: ccHeader, bodyText: bodyText)
        ])
    }

    /// The text the user authored above the quoted block, or nil when the
    /// block was edited or removed (→ caller regenerates HTML from full body).
    static func userText(inBody body: String, expectedBlock block: String) -> String? {
        guard body.hasSuffix(block) else { return nil }
        return String(body.dropLast(block.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a message carries Gmail's DRAFT label (space-separated ids).
    static func hasDraftLabel(_ labelIds: String) -> Bool {
        labelIds.split(whereSeparator: \.isWhitespace).contains { $0 == "DRAFT" }
    }

    /// Messages safe to include in Forward all — unsent drafts must not leak
    /// to third parties. Order preserved (call with oldest-first rows).
    static func forwardableMessages(_ messages: [Message]) -> [Message] {
        messages.filter { !hasDraftLabel($0.labelIds) }
    }

    /// Which forward package still suffixes `body`, for HTML upgrade at send.
    ///
    /// **Order matters:** try the full non-draft thread package *before* the
    /// single-message block. A Forward-all package always ends with the newest
    /// message's block, so `hasSuffix(single)` would otherwise steal the match
    /// and HTML-escape older turns as "user text."
    static func matchHTMLUpgrade(
        body: String,
        original: Message,
        threadMessages: [Message]
    ) -> (userText: String, parts: [Part])? {
        let forwardable = forwardableMessages(threadMessages)
        if forwardable.count > 1 {
            let parts = forwardable.map { Part(message: $0) }
            let allBlock = forwardBlock(parts: parts)
            if let userText = userText(inBody: body, expectedBlock: allBlock) {
                return (userText, parts)
            }
        }
        let single = [Part(message: original)]
        let singleBlock = forwardBlock(parts: single)
        if let userText = userText(inBody: body, expectedBlock: singleBlock) {
            return (userText, single)
        }
        return nil
    }

    /// HTML alternative: user text (markdown when present, else linkified
    /// plain via ComposeLinks), then each part's header + body.
    static func htmlBody(userText: String, parts: [Part]) -> String {
        var out = ""
        if !userText.isEmpty {
            if Markdown.looksLikeMarkdown(userText) {
                out += Markdown.toHTML(userText) + "<br>"
            } else {
                // ComposeLinks turns [label](url) and bare URLs into anchors and
                // escapes everything else — same path as a normal compose send.
                out += "<div>\(ComposeLinks.htmlFragment(from: userText))</div><br>"
            }
        }
        for (i, part) in parts.enumerated() {
            if i > 0 { out += "<br>" }
            out += singleHTMLBlock(part)
        }
        return out
    }

    /// Convenience matching the historical single-message HTML path.
    static func htmlBody(userText: String, fromHeader: String, date: Date,
                         subject: String, toHeader: String, ccHeader: String,
                         originalHTML: String) -> String {
        htmlBody(userText: userText, parts: [
            Part(fromHeader: fromHeader, date: date, subject: subject,
                 toHeader: toHeader, ccHeader: ccHeader, bodyText: "",
                 bodyHTML: originalHTML)
        ])
    }

    private static func singlePlainBlock(_ part: Part) -> String {
        var lines = [marker,
                     "From: \(part.fromHeader)",
                     "Date: \(dateFormatter.string(from: part.date))",
                     "Subject: \(part.subject)",
                     "To: \(part.toHeader)"]
        if !part.ccHeader.isEmpty { lines.append("Cc: \(part.ccHeader)") }
        return lines.joined(separator: "\n") + "\n\n" + part.bodyText
    }

    private static func singleHTMLBlock(_ part: Part) -> String {
        var header = "\(marker)<br>From: \(escapeHTML(part.fromHeader))<br>"
            + "Date: \(escapeHTML(dateFormatter.string(from: part.date)))<br>"
            + "Subject: \(escapeHTML(part.subject))<br>To: \(escapeHTML(part.toHeader))<br>"
        if !part.ccHeader.isEmpty {
            header += "Cc: \(escapeHTML(part.ccHeader))<br>"
        }
        let content: String
        if let html = part.bodyHTML {
            content = html
        } else {
            content = "<div>\(escapeHTML(part.bodyText))</div>"
        }
        return "<div class=\"gmail_quote\"><div>\(header)</div><br>\(content)</div>"
    }

    private static func escapeHTML(_ s: String) -> String {
        ComposeLinks.escapeText(s).replacingOccurrences(of: "\n", with: "<br>")
    }
}

/// Builds the quoted trail for replies — plain `> ` lines in the compose
/// editor (collapsed behind "…"), and a Gmail-compatible HTML alternative
/// at send time when the quote is untouched.
///
/// Without the HTML upgrade, replies went out as multipart with
/// `Markdown.toHTML` turning every `> ` line into a flat
/// `<blockquote type="cite">`. Nested history from the original (already
/// containing `>` prefixes and "On … wrote:" lines) leaked as visible
/// text, original markup/links were stripped, and Gmail had no
/// `gmail_quote` container to style or collapse. Recipients saw a messy
/// trail unlike gmail.com / Apple Mail.
///
/// Parallel to `ForwardComposer`: recompute the plain quote at send; if
/// it still suffixes the body byte-for-byte, wrap user text + original
/// HTML in a standard Gmail quote block. If the user edited the quote,
/// fall back to plain/markdown on the full body.
enum ReplyComposer {
    /// Attribution line, e.g. `On Jul 6, 2026 at 11:55 PM, Jane <j@x.com> wrote:`.
    static func attribution(for message: Message) -> String {
        let when = formatDate(message.date)
        let sender = MessageParser.emailAddress(message.fromHeader)
        let who = "\(MessageParser.displayName(fromHeader: message.fromHeader)) <\(sender)>"
        return "On \(when), \(who) wrote:"
    }

    /// Collapsed quote tail stored outside the editor (`quotedTail`).
    /// Leading `\n` matches the historical prefill so `fullBody` joins as
    /// `head + "\n\n" + plainQuote` → the same shape the expand/collapse
    /// regex and send-time matcher expect.
    static func plainQuote(of message: Message) -> String {
        let quoted = MessageParser
            .replyQuotableText(text: message.bodyText, html: message.bodyHTML)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return "\n\(attribution(for: message))\n\(quoted)"
    }

    /// User-authored text above an untouched reply quote, or nil when the
    /// quote was edited/removed (caller regenerates HTML from the full body).
    static func userText(inBody body: String, expectedQuote quote: String) -> String? {
        guard body.hasSuffix(quote) else { return nil }
        return String(body.dropLast(quote.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Send-path match: body still ends with the recomputed plain quote.
    static func matchHTMLUpgrade(body: String, original: Message)
        -> (userText: String, original: Message)? {
        let quote = plainQuote(of: original)
        guard let userText = userText(inBody: body, expectedQuote: quote) else {
            return nil
        }
        return (userText, original)
    }

    /// Gmail-style HTML alternative: authored head (markdown or linkified
    /// plain), then `gmail_quote` / `gmail_attr` / nested `blockquote`
    /// carrying the original message's HTML when present.
    static func htmlBody(userText: String, original: Message) -> String {
        var out = ""
        if !userText.isEmpty {
            if Markdown.looksLikeMarkdown(userText) {
                out += Markdown.toHTML(userText)
            } else {
                // Always wrap so multi-line replies keep structure; fragment
                // already escapes and turns newlines into <br>.
                out += "<div>\(ComposeLinks.htmlFragment(from: userText))</div>"
            }
        }
        let attr = ComposeLinks.escapeText(attribution(for: original))
        let content: String
        if let html = original.bodyHTML, !html.isEmpty {
            content = html
        } else {
            let plain = MessageParser.replyQuotableText(
                text: original.bodyText, html: nil)
            let escaped = ComposeLinks.escapeText(plain)
                .replacingOccurrences(of: "\n", with: "<br>")
            content = "<div>\(escaped)</div>"
        }
        // Style matches gmail.com so the trail collapses and indents correctly
        // in Gmail and other clients that key off these class names.
        out += "<br><div class=\"gmail_quote\">"
            + "<div dir=\"ltr\" class=\"gmail_attr\">\(attr)<br></div>"
            + "<blockquote class=\"gmail_quote\" style=\"margin:0px 0px 0px 0.8ex;"
            + "border-left:1px solid rgb(204,204,204);padding-left:1ex\">"
            + content
            + "</blockquote></div>"
        return out
    }

    /// Locale-aware date matching the historical compose prefill
    /// (`formatted(date: .abbreviated, time: .shortened)`). Send-time
    /// recompute must use the same function or the quote suffix won't match.
    static func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Detects the quoted reply trail inside a message body so the thread view
/// can collapse it behind a "…" pill, Gmail-style. Every message in a thread
/// carries the full history below its new text; showing it all makes long
/// threads unreadable.
enum QuotedReply {
    // Precompiled: these run over whole bodies every time the thread view
    // renders a card, so per-call compilation would add up fast.
    //
    // The attribution may wrap onto a second line (Gmail folds long
    // "On …, Full Name <address> wrote:" lines), hence the optional `\n.+`.
    // One alternation, not a pattern list — the split must happen at the
    // EARLIEST marker, not at the first pattern that matches anywhere.
    private static let textMarker = try! NSRegularExpression(
        pattern: #"\n+(On .+(\n.+)? wrote:\s*\n|-{2,} ?Forwarded message ?-{2,})"#)

    /// The quote containers `hideQuoteCSS` hides: Gmail (`gmail_quote` class
    /// on any element, single- or double-quoted), Outlook's reply-header div,
    /// Apple Mail's cite blockquotes. Keep in sync with `hideQuoteCSS`.
    private static let htmlMarker = try! NSRegularExpression(
        pattern: #"<[^>]+class\s*=\s*["'][^"']*gmail_quote"# + "|"
            + #"<[^>]+id\s*=\s*["']?divRplyFwdMsg"# + "|"
            + #"<blockquote[^>]*type\s*=\s*["']?cite"#,
        options: [.caseInsensitive])

    /// Splits a plain-text body at the reply attribution ("On …, X wrote:")
    /// or forwarded-message marker. Returns nil when there is no quoted trail
    /// or no authored text above it (collapsing would hide the whole message).
    static func splitText(_ body: String) -> (head: String, tail: String)? {
        let ns = body as NSString
        guard let match = textMarker.firstMatch(
            in: body, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let head = ns.substring(to: match.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return nil }
        return (head, ns.substring(from: match.range.location))
    }

    /// True when an HTML body carries a quoted trail that `hideQuoteCSS`
    /// knows how to hide *and* has authored content above it — same guard
    /// as the plain-text split.
    static func hasHTMLQuote(_ html: String) -> Bool {
        let ns = html as NSString
        guard let match = htmlMarker.firstMatch(
            in: html, range: NSRange(location: 0, length: ns.length))
        else { return false }
        return !MessageParser.stripHTML(ns.substring(to: match.range.location)).isEmpty
    }

    /// Stylesheet rule that hides those quoted trails while collapsed.
    /// Mirrors `htmlMarker`; Outlook's quoted body follows its header div as
    /// siblings, so everything after `#divRplyFwdMsg` goes too.
    static let hideQuoteCSS = #"[class*="gmail_quote"], blockquote[type="cite" i], "#
        + "#divRplyFwdMsg, #divRplyFwdMsg ~ * { display: none; }"
}

/// Builds RFC 2822 messages for sending/replying, optionally multipart/mixed
/// with attachments.
enum MIMEBuilder {
    struct Attachment: Codable {
        let filename: String
        let mimeType: String
        let data: Data
    }

    static func build(from: String, to: String, cc: String = "", bcc: String = "",
                      subject: String, bodyText: String, bodyHTML: String? = nil,
                      inReplyTo: String? = nil, references: String? = nil,
                      attachments: [Attachment] = []) -> Data {
        var lines: [String] = []
        lines.append("From: \(clean(from))")
        lines.append("To: \(clean(to))")
        if !cc.isEmpty { lines.append("Cc: \(clean(cc))") }
        if !bcc.isEmpty { lines.append("Bcc: \(clean(bcc))") }
        lines.append("Subject: \(encodeHeader(clean(subject)))")
        if let inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(clean(inReplyTo))")
            let refs = [references, inReplyTo].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            lines.append("References: \(clean(refs))")
        }
        lines.append("MIME-Version: 1.0")

        // The body: text/plain alone, or multipart/alternative when an HTML
        // version exists (formatted forwards). Content-type header + parts.
        func bodyPart(_ contentType: String, _ content: String) -> [String] {
            ["Content-Type: \(contentType); charset=UTF-8",
             "Content-Transfer-Encoding: base64",
             "",
             Data(content.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])]
        }
        func bodyLines() -> [String] {
            guard let bodyHTML else { return bodyPart("text/plain", bodyText) }
            let alt = "pm-alt-\(UUID().uuidString)"
            return ["Content-Type: multipart/alternative; boundary=\"\(alt)\"", "",
                    "--\(alt)"] + bodyPart("text/plain", bodyText)
                + ["--\(alt)"] + bodyPart("text/html", bodyHTML)
                + ["--\(alt)--"]
        }

        if attachments.isEmpty {
            lines.append(contentsOf: bodyLines())
        } else {
            let boundary = "pm-\(UUID().uuidString)"
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines.append(contentsOf: bodyLines())
            for att in attachments {
                let name = quotable(att.filename)
                lines.append("--\(boundary)")
                lines.append("Content-Type: \(clean(att.mimeType)); name=\"\(name)\"")
                lines.append("Content-Disposition: attachment; filename=\"\(name)\"")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("")
                lines.append(att.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
            }
            lines.append("--\(boundary)--")
        }
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// RFC 2047 encoding for non-ASCII header values.
    private static func encodeHeader(_ value: String) -> String {
        value.allSatisfy(\.isASCII) ? value
            : "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
    }

    /// A header value is a single line. Untrusted input (reply threading
    /// headers from received mail, pasted subjects) must not be able to
    /// inject extra headers, so CR/LF are folded to spaces.
    private static func clean(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// A value inside a quoted header parameter (attachment filenames):
    /// additionally strip quotes and backslashes so it can't escape the quoting.
    private static func quotable(_ value: String) -> String {
        clean(value).filter { $0 != "\"" && $0 != "\\" }
    }
}
