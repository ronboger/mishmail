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
        // en_US_POSIX keeps the prefill/send recompute byte-stable across
        // locale / 12-24h toggles (same contract as ReplyComposer).
        f.locale = Locale(identifier: "en_US_POSIX")
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
    /// Shared with `ReplyComposer` — keep one "untouched quote" contract.
    static func userText(inBody body: String, expectedBlock block: String) -> String? {
        ComposeQuote.userText(inBody: body, expectedQuote: block)
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

    /// Newest non-draft message in an oldest-first list. Shared by keyboard
    /// reply/forward, command palette, and the reading-pane toolbar so none
    /// parent a compose on an unsent draft at the end of the thread.
    static func newestSentMessage(in msgs: [Message]) -> Message? {
        msgs.last(where: { !hasDraftLabel($0.labelIds) })
    }

    /// Newest DRAFT-labeled message (oldest-first list → last match).
    static func newestDraft(in msgs: [Message]) -> Message? {
        msgs.last(where: { hasDraftLabel($0.labelIds) })
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
        var out = ComposeQuote.authoredHeadHTML(userText)
        if !userText.isEmpty { out += "<br>" }
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
        var header = "\(marker)<br>From: \(ComposeQuote.escapeHTML(part.fromHeader))<br>"
            + "Date: \(ComposeQuote.escapeHTML(dateFormatter.string(from: part.date)))<br>"
            + "Subject: \(ComposeQuote.escapeHTML(part.subject))<br>"
            + "To: \(ComposeQuote.escapeHTML(part.toHeader))<br>"
        if !part.ccHeader.isEmpty {
            header += "Cc: \(ComposeQuote.escapeHTML(part.ccHeader))<br>"
        }
        let content: String
        if let html = part.bodyHTML {
            content = ComposeQuote.sanitizeQuotedHTML(html)
        } else {
            content = "<div>\(ComposeQuote.escapeHTML(part.bodyText))</div>"
        }
        return "<div class=\"gmail_quote\"><div>\(header)</div><br>\(content)</div>"
    }
}

/// Shared helpers for reply/forward quote matching and HTML emission.
/// Keep one "untouched quote" contract and one authored-head policy so
/// reply and forward can't silently diverge.
enum ComposeQuote {
    /// Byte-suffix match for an untouched quote package.
    static func userText(inBody body: String, expectedQuote quote: String) -> String? {
        guard body.hasSuffix(quote) else { return nil }
        return String(body.dropLast(quote.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Authored head → HTML: markdown when present, else linkified plain.
    static func authoredHeadHTML(_ userText: String) -> String {
        guard !userText.isEmpty else { return "" }
        if Markdown.looksLikeMarkdown(userText) {
            return Markdown.toHTML(userText)
        }
        return "<div>\(ComposeLinks.htmlFragment(from: userText))</div>"
    }

    static func escapeHTML(_ s: String) -> String {
        ComposeLinks.escapeText(s).replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Harden HTML we nest under gmail_quote: drop document chrome and
    /// `cid:` images (we don't re-attach inline parts on reply/forward, so
    /// those refs would show as broken images). Style/script would also let
    /// quoted CSS restyle the authored head in some clients.
    static func sanitizeQuotedHTML(_ html: String) -> String {
        var s = html
        for tag in ["style", "script", "head", "title"] {
            s = s.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>",
                with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(
            of: "</?(html|body)\\b[^>]*>",
            with: "", options: [.regularExpression, .caseInsensitive])
        // Whole <img … src="cid:…"> tags (and single-quoted / unquoted variants).
        s = s.replacingOccurrences(
            of: #"<img\b[^>]*\bsrc\s*=\s*(['"]?)cid:[^'"\s>]*\1[^>]*/?>"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        return s
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
    /// Pinned like ForwardComposer's formatter so send-time recompute matches
    /// the prefill even if the user toggles 12/24-hour or locale mid-compose.
    /// en_US_POSIX keeps month names stable; wall-clock timezone stays local.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return f
    }()

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
        ComposeQuote.userText(inBody: body, expectedQuote: quote)
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
        var out = ComposeQuote.authoredHeadHTML(userText)
        let attr = ComposeLinks.escapeText(attribution(for: original))
        let content: String
        if let html = original.bodyHTML, !html.isEmpty {
            content = ComposeQuote.sanitizeQuotedHTML(html)
        } else {
            let plain = MessageParser.replyQuotableText(
                text: original.bodyText, html: nil)
            content = "<div>\(ComposeQuote.escapeHTML(plain))</div>"
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

    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// True when Reply All would put someone on Cc beyond a plain Reply's To.
    /// Mirrors `ComposeView` recipient prefill so the button only appears when
    /// it would change the recipient set (group threads / multi-recipient mail).
    static func hasAdditionalReplyAllRecipients(
        _ message: Message,
        ownAddresses: Set<String>
    ) -> Bool {
        let own = Set(ownAddresses.map { $0.lowercased() })
        let sender = MessageParser.emailAddress(message.fromHeader).lowercased()

        // Plain-reply To targets — same rules as ComposeView.setupFromReply.
        let toTargets: [String]
        if own.contains(sender) {
            // Replying to own mail: target its recipients, not self.
            toTargets = MessageParser.splitAddresses(message.toHeader)
                .map { MessageParser.emailAddress($0).lowercased() }
                .filter { $0.contains("@") && !own.contains($0) }
        } else {
            toTargets = sender.contains("@") ? [sender] : []
        }
        let taken = Set(toTargets)

        let extras = MessageParser.splitAddresses(message.toHeader + "," + message.ccHeader)
            .map { MessageParser.emailAddress($0).lowercased() }
            .filter { $0.contains("@") }
            .filter { !own.contains($0)
                      && $0 != sender
                      && !taken.contains($0) }
        return !extras.isEmpty
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

    /// Structured quote containers emitted by Gmail (`gmail_quote` class on
    /// any element, single- or double-quoted), Outlook's reply-header div, and
    /// Apple Mail's cite blockquotes.
    private static let htmlMarker = try! NSRegularExpression(
        pattern: #"<[^>]+class\s*=\s*["'][^"']*gmail_quote"# + "|"
            + #"<[^>]+id\s*=\s*["']?divRplyFwdMsg"# + "|"
            + #"<blockquote[^>]*type\s*=\s*["']?cite"#,
        options: [.caseInsensitive])

    /// Splits a plain-text body at the earliest quoted trail so the thread
    /// card can collapse history behind "…". Boundaries (earliest wins):
    /// 1. Reply attribution ("On …, X wrote:") or forwarded-message marker
    /// 2. A run of ≥2 `>`-prefixed lines that continues to EOF after prose
    ///    (clients that dump nested history without a bare attribution)
    ///
    /// After a marker cut, a trailing `>` block still sitting in the head
    /// (attribution below inlined quotes) is peeled into the trail so the
    /// pill actually hides the history the user sees.
    ///
    /// Returns nil when there is no trail or no authored text above it
    /// (collapsing would hide the whole message).
    static func splitText(_ body: String) -> (head: String, tail: String)? {
        // CRLF is a single Swift Character; Character-based line scans never
        // see "\n" inside it. Normalize before any line walk or String.Index cut.
        let body = normalizeNewlines(body)
        var cut: String.Index?

        let ns = body as NSString
        if let match = textMarker.firstMatch(
            in: body, range: NSRange(location: 0, length: ns.length)),
           let range = Range(match.range, in: body) {
            cut = range.lowerBound
        }
        if let gt = greaterThanBlockStart(in: body) {
            cut = cut.map { min($0, gt) } ?? gt
        }
        guard let cut else { return nil }

        var head = String(body[..<cut])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var tail = String(body[cut...])

        if let peeled = peelTrailingGreaterThanBlock(from: head) {
            head = peeled.head
            let mid = peeled.peeled
            if mid.isEmpty {
                // keep tail
            } else if tail.isEmpty {
                tail = mid
            } else {
                let needsNL = !mid.hasSuffix("\n") && !tail.hasPrefix("\n")
                tail = mid + (needsNL ? "\n" : "") + tail
            }
        }

        guard !head.isEmpty else { return nil }
        return (head, tail)
    }

    /// Gmail plain text may use CRLF or bare CR. Swift treats U+000D U+000A as
    /// one Character, which breaks Character-indexed line scans that look for
    /// `"\n"`. Collapse to LF so line walks and regex cuts stay consistent.
    private static func normalizeNewlines(_ body: String) -> String {
        guard body.utf8.contains(UInt8(ascii: "\r")) else { return body }
        return body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// True when a line is a classic plain-text quote (`>` / `> `), ignoring
    /// leading horizontal whitespace.
    private static func isGreaterThanLine(_ line: Substring) -> Bool {
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        return t.first == ">"
    }

    private static func isBlankLine(_ line: Substring) -> Bool {
        line.allSatisfy { $0.isWhitespace }
    }

    /// Line starts + content (split on `\n`, keeps empty lines).
    private static func enumeratedLines(_ body: String)
        -> [(start: String.Index, content: Substring)] {
        var lines: [(start: String.Index, content: Substring)] = []
        var start = body.startIndex
        var i = body.startIndex
        while i < body.endIndex {
            if body[i] == "\n" {
                lines.append((start, body[start..<i]))
                i = body.index(after: i)
                start = i
            } else {
                i = body.index(after: i)
            }
        }
        lines.append((start, body[start..<body.endIndex]))
        return lines
    }

    /// Start of a pure `>`-prefixed trail to EOF (≥2 quoted lines) after
    /// authored prose. Nested history often has no bare "On … wrote:" —
    /// only `> On … wrote:` — so the attribution regex never fires.
    ///
    /// Single backward pass (O(n)): the pure trailing region is a suffix of
    /// blank + `>` lines; the first non-quoted non-blank line walking up from
    /// EOF ends it. Avoids the O(n²) forward scan that re-counted to EOF at
    /// every candidate.
    private static func greaterThanBlockStart(in body: String) -> String.Index? {
        let lines = enumeratedLines(body)
        guard !lines.isEmpty else { return nil }

        var idx = lines.count - 1
        while idx >= 0, isBlankLine(lines[idx].content) { idx -= 1 }
        guard idx >= 0 else { return nil }

        var quoted = 0
        var blockStart: Int?
        while idx >= 0 {
            let c = lines[idx].content
            if isBlankLine(c) {
                idx -= 1
                continue
            }
            if isGreaterThanLine(c) {
                blockStart = idx
                quoted += 1
                idx -= 1
                continue
            }
            // Non-quoted non-blank = prose; pure trailing region ends above.
            break
        }

        // Need ≥2 quoted lines and prose before the block (`idx` still on that
        // prose line, or -1 when the body is quote-only from the top).
        guard let start = blockStart, quoted >= 2, idx >= 0 else { return nil }
        return lines[start].start
    }

    /// If `head` ends with a pure `>` block (≥2 lines) after real prose, peel
    /// it off so a later "On … wrote:" cut doesn't leave history in the head.
    private static func peelTrailingGreaterThanBlock(from head: String)
        -> (head: String, peeled: String)? {
        let lines = enumeratedLines(head)
        var lastProse: Int?
        for (idx, line) in lines.enumerated() {
            if isBlankLine(line.content) { continue }
            if !isGreaterThanLine(line.content) { lastProse = idx }
        }
        guard let proseIdx = lastProse else { return nil }

        var blockStart: Int?
        var quoted = 0
        for idx in (proseIdx + 1)..<lines.count {
            let c = lines[idx].content
            if isBlankLine(c) { continue }
            if isGreaterThanLine(c) {
                if blockStart == nil { blockStart = idx }
                quoted += 1
            } else {
                return nil
            }
        }
        guard let start = blockStart, quoted >= 2 else { return nil }

        let newHead = String(head[head.startIndex..<lines[proseIdx].content.endIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newHead.isEmpty else { return nil }
        // Blanks between last prose and the first `>` line travel with the trail.
        let peeled = String(head[lines[start].start...])
        return (newHead, peeled)
    }

    /// Raw markup before the first structured quote container.
    ///
    /// A bounded scan includes a small overlap so a marker that starts just
    /// before the cutoff is not truncated mid-tag. Matches must still begin
    /// before the requested limit.
    static func rawHTMLHead(_ html: String, scanCharacterLimit: Int? = nil) -> String? {
        let sample: String
        let matchLocationLimit: Int?
        if let scanCharacterLimit {
            let limit = max(0, scanCharacterLimit)
            let cutoff = html.index(
                html.startIndex, offsetBy: limit, limitedBy: html.endIndex) ?? html.endIndex
            let scanEnd = html.index(
                cutoff, offsetBy: 512, limitedBy: html.endIndex) ?? html.endIndex
            sample = String(html[..<scanEnd])
            matchLocationLimit = html[..<cutoff].utf16.count
        } else {
            sample = html
            matchLocationLimit = nil
        }
        let ns = sample as NSString
        guard let match = htmlMarker.firstMatch(
            in: sample, range: NSRange(location: 0, length: ns.length)),
              matchLocationLimit.map({ match.range.location < $0 }) ?? true
        else { return nil }
        return ns.substring(to: match.range.location)
    }

    /// Authored markup before the first quote container. The reading pane
    /// loads this smaller fragment so WebKit never parses/layouts recursively
    /// repeated history.
    ///
    /// Returns nil when no marker exists or the body is quote-only; collapsing
    /// in the latter case would blank the message.
    static func authoredHTMLHead(_ html: String, scanCharacterLimit: Int? = nil) -> String? {
        guard let head = rawHTMLHead(html, scanCharacterLimit: scanCharacterLimit) else {
            return nil
        }
        guard !MessageParser.stripHTML(head).isEmpty else { return nil }
        return head
    }

    /// True when an HTML body carries a collapsible quoted trail and has
    /// authored content above it.
    static func hasHTMLQuote(_ html: String) -> Bool {
        authoredHTMLHead(html) != nil
    }

    /// Raw authored HTML above a known quote container, or the original body
    /// when no safe split exists.
    static func authoredHTML(_ html: String) -> String {
        authoredHTMLHead(html) ?? html
    }

    /// User-authored text above any quoted trail — for draft cards and other
    /// compact previews. Prefers the plain-text split (matches compose's
    /// `quotedTail`); falls back to HTML strip above the quote marker so a
    /// multipart draft still shows only what the user wrote, not the thread.
    ///
    /// Quote-only bodies (reply opened, quote auto-inserted, user saved
    /// without typing) return `""` so the UI can show an empty-draft state
    /// instead of dumping the whole trail into the preview.
    static func authoredPreview(text: String, html: String?) -> String {
        if let head = splitText(text)?.head {
            return head
        }
        // splitText is nil when there is no marker *or* when the marker sits
        // at the start with an empty authored head. The latter must not fall
        // through to "return the whole body".
        if isQuoteOnlyText(text) {
            return htmlAuthoredHead(html)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return htmlAuthoredHead(html)
    }

    /// True when plain text is only a quoted trail (marker present, no head,
    /// or every non-blank line is `>`-prefixed). Same empty-head guard as
    /// `splitText`, exposed so previews don't treat quote-only bodies as
    /// authored content.
    static func isQuoteOnlyText(_ body: String) -> Bool {
        let body = normalizeNewlines(body)
        let ns = body as NSString
        if let match = textMarker.firstMatch(
            in: body, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(to: match.range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        let lines = enumeratedLines(body)
        let nonBlank = lines.map(\.content).filter { !isBlankLine($0) }
        guard !nonBlank.isEmpty else { return false }
        return nonBlank.allSatisfy { isGreaterThanLine($0) }
    }

    /// Authored head of an HTML body above a known quote container, or the
    /// full stripped body when no marker is present. Empty when the HTML is
    /// quote-only (or blank).
    private static func htmlAuthoredHead(_ html: String?) -> String {
        guard let html, !html.isEmpty else { return "" }
        let ns = html as NSString
        if let match = htmlMarker.firstMatch(
            in: html, range: NSRange(location: 0, length: ns.length)) {
            return MessageParser.stripHTML(ns.substring(to: match.range.location))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return MessageParser.stripHTML(html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
