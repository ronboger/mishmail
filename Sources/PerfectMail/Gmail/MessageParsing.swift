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
/// The compose editor is plain text, but most mail is HTML. To forward
/// without losing formatting, the send path recomputes this block from the
/// original message: if the composed body still ends with it verbatim, the
/// message is upgraded to multipart/alternative with the user's (escaped)
/// text on top of the original HTML. If the user edited inside the quoted
/// block, we send plain text only — the two parts must never disagree.
enum ForwardComposer {
    static let marker = "---------- Forwarded message ---------"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        return f
    }()

    /// The plain-text quoted block: marker, original headers, original body.
    static func forwardBlock(fromHeader: String, date: Date, subject: String,
                             toHeader: String, ccHeader: String,
                             bodyText: String) -> String {
        var lines = [marker,
                     "From: \(fromHeader)",
                     "Date: \(dateFormatter.string(from: date))",
                     "Subject: \(subject)",
                     "To: \(toHeader)"]
        if !ccHeader.isEmpty { lines.append("Cc: \(ccHeader)") }
        return lines.joined(separator: "\n") + "\n\n" + bodyText
    }

    /// The text the user authored above the quoted block, or nil when the
    /// block was edited or removed (→ caller must send plain text only).
    static func userText(inBody body: String, expectedBlock block: String) -> String? {
        guard body.hasSuffix(block) else { return nil }
        return String(body.dropLast(block.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HTML alternative: escaped user text, header block, original HTML.
    static func htmlBody(userText: String, fromHeader: String, date: Date,
                         subject: String, toHeader: String, ccHeader: String,
                         originalHTML: String) -> String {
        var out = ""
        if !userText.isEmpty {
            out += "<div>\(escapeHTML(userText))</div><br>"
        }
        var header = "\(marker)<br>From: \(escapeHTML(fromHeader))<br>"
            + "Date: \(escapeHTML(dateFormatter.string(from: date)))<br>"
            + "Subject: \(escapeHTML(subject))<br>To: \(escapeHTML(toHeader))<br>"
        if !ccHeader.isEmpty { header += "Cc: \(escapeHTML(ccHeader))<br>" }
        out += "<div class=\"gmail_quote\"><div>\(header)</div><br>\(originalHTML)</div>"
        return out
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
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
