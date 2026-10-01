import Foundation
import CoreFoundation

/// Converts a Gmail API `GMessage` (format=full) into our local rows.
enum MessageParser {
    /// Below this many messages the task-group overhead outweighs the win;
    /// parse inline. Metadata refreshes and single-message history deltas
    /// usually land here.
    static let concurrentParseThreshold = 4

    /// `parse` for a whole fetched page, results in input order.
    ///
    /// `nonisolated async` so it runs on the global concurrent executor, not
    /// on the calling actor: SyncEngine used to parse each message serially
    /// on its own actor, so a page of HTML-heavy mail (base64 decode, charset
    /// transcode, CID inlining, stripHTML) pinned one core while the rest sat
    /// idle and every other SyncEngine call queued behind it.
    ///
    /// `parse` is pure and non-throwing, so there is no per-message failure
    /// to preserve: every input yields exactly one output, at the same index.
    /// Work is split into at most `activeProcessorCount` contiguous chunks so
    /// a 25-100 message page costs a handful of child tasks, not one each.
    nonisolated static func parseConcurrently(
        _ messages: [GMessage], accountId: String
    ) async -> [(Message, [AttachmentRow])] {
        guard messages.count >= concurrentParseThreshold else {
            return messages.map { parse($0, accountId: accountId) }
        }
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount,
                                 messages.count))
        let chunkSize = (messages.count + workers - 1) / workers
        return await withTaskGroup(
            of: (Int, [(Message, [AttachmentRow])]).self
        ) { group in
            for start in stride(from: 0, to: messages.count, by: chunkSize) {
                let end = min(start + chunkSize, messages.count)
                let slice = Array(messages[start..<end])
                group.addTask {
                    (start, slice.map { parse($0, accountId: accountId) })
                }
            }
            var chunks: [(Int, [(Message, [AttachmentRow])])] = []
            for await chunk in group { chunks.append(chunk) }
            return chunks.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    static func parse(_ g: GMessage, accountId: String) -> (Message, [AttachmentRow]) {
        func header(_ name: String) -> String {
            g.payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        var text = ""
        var html: String?
        var attachments: [AttachmentRow] = []
        /// Image bytes already present on the wire (no separate getAttachment).
        /// Keyed by normalized Content-ID for parse-time `cid:` rewrite.
        var inlineBlobs: [String: (mimeType: String, data: Data)] = [:]
        let localId = "\(accountId):\(g.id)"
        collectParts(g.payload, messageId: localId, text: &text, html: &html,
                     attachments: &attachments, inlineBlobs: &inlineBlobs)
        if var bodyHTML = html, !inlineBlobs.isEmpty {
            bodyHTML = CIDImageInliner.rewrite(bodyHTML, parts: inlineBlobs)
            html = bodyHTML
        }
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
            hasAttachment: !attachments.isEmpty,
            senderAuth: senderAuthenticated(g),
            // Empty string (not nil) so a parse is distinguishable from a
            // pre-v37 row that has never recorded these headers.
            listUnsubscribe: header("List-Unsubscribe"),
            listUnsubscribePost: header("List-Unsubscribe-Post")
        )
        return (message, attachments)
    }

    /// Verdict from Gmail's own `Authentication-Results` header: true only on
    /// an aligned `dmarc=pass`, false when the header is present without one,
    /// nil when absent (legacy rows, unusual payloads).
    ///
    /// SPF/DKIM alone do NOT authenticate the visible sender: a spoofer
    /// passes both for their *own* domain (`spf=pass
    /// smtp.mailfrom=evil.example`) while `From:` names the victim. DMARC is
    /// the alignment check that binds the authenticated identifiers to the
    /// From domain, so it is the bar. Senders whose domains publish no DMARC
    /// record judge as failures — safe direction: their images need one
    /// explicit click. (`dmarc=bestguesspass`, Google's no-record value,
    /// correctly does not qualify.)
    ///
    /// Two trust details: only the FIRST such header counts (Gmail prepends
    /// its own at delivery; headers deeper in the list can be forwarded
    /// copies — though mail added via `users.messages.insert`/import can
    /// carry an attacker-authored first header, so this is a guard, not a
    /// guarantee). And the match is a boundary-checked method token after
    /// stripping parenthesized comments and quoted strings, because Google
    /// echoes attacker bytes verbatim in the same value (`smtp.mailfrom=`
    /// envelope sender) — a quoted local part like `"dmarc=pass"@evil.example`
    /// or `"x;dmarc=pass"@evil.example` must not satisfy it.
    static func senderAuthenticated(_ g: GMessage) -> Bool? {
        guard let raw = g.payload?.headers?
            .first(where: {
                $0.name.caseInsensitiveCompare("Authentication-Results") == .orderedSame
            })?
            .value else { return nil }
        let results = strippingCommentsAndQuotedStrings(raw.lowercased())
        guard let verdict = results.range(
            of: #"(?:^|;)\s*dmarc\s*=\s*([a-z0-9-]+)"#,
            options: .regularExpression) else { return false }
        let value = results[verdict]
            .split(separator: "=", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespaces)
        return value == "pass"
    }

    /// Removes parenthesized CFWS comments (nested) and double-quoted
    /// strings from a structured header value. Both can hold
    /// attacker-influenced text, and a `;` inside either is not a method
    /// separator: `smtp.mailfrom="x;dmarc=pass"@evil.example` must not read
    /// as a verdict. A backslash escapes the next character inside both. An
    /// unterminated quote or comment swallows the rest of the value — fail
    /// closed, since nothing after it can be told from sender text.
    static func strippingCommentsAndQuotedStrings(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        var inQuotes = false
        var escaped = false
        var commentDepth = 0
        for ch in value {
            if inQuotes || commentDepth > 0 {
                if escaped { escaped = false; continue }
                if ch == "\\" { escaped = true; continue }
                if inQuotes {
                    if ch == "\"" { inQuotes = false }
                } else if ch == "(" {
                    commentDepth += 1
                } else if ch == ")" {
                    commentDepth -= 1
                }
                continue
            }
            switch ch {
            case "\"": inQuotes = true
            case "(": commentDepth += 1
            default: out.append(ch)
            }
        }
        return out
    }

    private static func partHeader(_ part: GMessage.Part, _ name: String) -> String? {
        part.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func collectParts(_ part: GMessage.Part?, messageId: String,
                                     text: inout String, html: inout String?,
                                     attachments: inout [AttachmentRow],
                                     inlineBlobs: inout [String: (mimeType: String, data: Data)]) {
        guard let part else { return }
        let mime = part.mimeType ?? "application/octet-stream"
        let isImage = mime.lowercased().hasPrefix("image/")
        let contentIdRaw = partHeader(part, "Content-ID")
        let contentId = contentIdRaw.map { CIDImageInliner.normalize($0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let filename = part.filename.flatMap { $0.isEmpty ? nil : $0 }

        // Downloadable / inline MIME parts: filename or Content-ID with an
        // attachmentId. Empty-filename inline images with a Content-ID used to
        // be dropped entirely, so USPS-style mailpiece scans never rendered.
        // (Plain image/* parts with neither stay excluded — admitting them put
        // a paperclip on every logo-bearing marketing mail.)
        if let attachmentId = part.body?.attachmentId,
           filename != nil || contentId != nil {
            let name = filename
                ?? CIDImageInliner.syntheticFilename(contentId: contentId, mimeType: mime)
            let row = AttachmentRow(
                id: nil, messageId: messageId, gmailAttachmentId: attachmentId,
                filename: name, mimeType: mime,
                size: part.body?.size ?? 0, contentId: contentId)
            // Google Calendar: `text/calendar` alternative often precedes the
            // downloadable `application/ics` / invite.ics sibling. Drop an
            // earlier inline calendar row with the *same* filename key and
            // skip same-key duplicates so the reading pane only gets one
            // Accept card. Distinct filenames (standup.ics + retro.ics) keep
            // both rows — including mixed inline + downloadable.
            if CalendarInvite.isCalendarAttachment(mimeType: mime, filename: name) {
                let key = CalendarInvite.calendarAttachmentDedupeKey(filename: name)
                attachments.removeAll {
                    AttachmentRow.isInlineCalendarId($0.gmailAttachmentId)
                        && CalendarInvite.isCalendarAttachment(
                            mimeType: $0.mimeType, filename: $0.filename)
                        && CalendarInvite.calendarAttachmentDedupeKey(
                            filename: $0.filename) == key
                }
                let already = attachments.contains {
                    CalendarInvite.isCalendarAttachment(
                        mimeType: $0.mimeType, filename: $0.filename)
                        && CalendarInvite.calendarAttachmentDedupeKey(
                            filename: $0.filename) == key
                }
                if !already {
                    attachments.append(row)
                }
            } else {
                attachments.append(row)
            }
            // No blob capture here: attachmentId parts are resolved at render
            // time via getAttachment, session-only. Persisting their bytes as
            // data: URIs in message_body would bloat SQLCipher.
        } else if let data = part.body?.data {
            if let decoded = decodeBase64URL(
                data, contentType: partHeader(part, "Content-Type")) {
                switch part.mimeType {
                case "text/plain" where text.isEmpty: text = decoded
                case "text/html" where html == nil: html = decoded
                default: break
                }
            }
            // Inline image with Content-ID but no attachmentId: the bytes on
            // the wire are the only copy (getAttachment can't fetch these), so
            // they get inlined at parse time and persist with the body. Gmail
            // hands large parts an attachmentId, so these are small; the cap
            // bounds message_body growth against pathological payloads.
            if isImage, let cid = contentId,
               let bytes = decodeBase64URLData(data),
               bytes.count <= CIDImageInliner.maxPersistedBlobBytes {
                inlineBlobs[cid] = (mime, bytes)
            }
            // Inline text/calendar without attachmentId (Outlook / Calendly).
            // Skip only when a same-filename-key calendar row already exists
            // so Google invites (invite.ics + multipart alternative) don't
            // double-card, while a different .ics on the same message still
            // gets its own card. A later downloadable same-key part replaces
            // this via the attachmentId branch above.
            if isCalendarMime(mime),
               let bytes = decodeBase64URLData(data), !bytes.isEmpty {
                let name = filename.map { MessageParser.safeFilename($0) } ?? "invite.ics"
                let key = CalendarInvite.calendarAttachmentDedupeKey(filename: name)
                let already = attachments.contains {
                    CalendarInvite.isCalendarAttachment(
                        mimeType: $0.mimeType, filename: $0.filename)
                        && CalendarInvite.calendarAttachmentDedupeKey(
                            filename: $0.filename) == key
                }
                if !already {
                    attachments.append(AttachmentRow(
                        id: nil, messageId: messageId,
                        gmailAttachmentId: AttachmentRow.inlineCalendarAttachmentId,
                        filename: name, mimeType: mime,
                        size: bytes.count, contentId: contentId))
                }
            }
        }
        for child in part.parts ?? [] {
            collectParts(child, messageId: messageId, text: &text, html: &html,
                         attachments: &attachments, inlineBlobs: &inlineBlobs)
        }
    }

    static func decodeBase64URL(_ s: String, contentType: String? = nil) -> String? {
        decodeBase64URLData(s).flatMap {
            decodeText($0, contentType: contentType)
        }
    }

    /// Gmail's part `mimeType` omits the charset parameter; the MIME header
    /// is authoritative for legacy mail. Order: a 7-bit stateful label
    /// (ISO-2022-JP, UTF-7), then UTF-8, then any other declared charset,
    /// then Windows-1252 / ISO-8859-1 for malformed headers.
    private static func decodeText(_ data: Data, contentType: String?) -> String? {
        let charset = contentType.flatMap(declaredCharset)?.lowercased()
        let declared: String.Encoding? = charset.flatMap { name in
            ["utf-8", "utf8", "us-ascii", "ascii"].contains(name)
                ? nil : stringEncoding(forIANAName: name)
        }
        // 7-bit stateful charsets are always valid UTF-8, so only the label
        // can pick them. Any other label loses to bytes that are valid UTF-8:
        // UTF-8 mail labelled ISO-8859-1 is common, while real Latin-1 or
        // Shift_JIS text with non-ASCII bytes is almost never valid UTF-8.
        if let charset, let declared, isSevenBitStateful(charset),
           let decoded = String(data: data, encoding: declared) {
            return decoded
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let declared, let decoded = String(data: data, encoding: declared) {
            return decoded
        }
        return String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func isSevenBitStateful(_ charset: String) -> Bool {
        charset.hasPrefix("iso-2022") || charset == "utf-7" || charset == "hz-gb-2312"
    }

    /// The `charset` parameter of a Content-Type value, unquoted.
    private static func declaredCharset(_ contentType: String) -> String? {
        guard let range = contentType.range(
            of: #"charset\s*=\s*[\"']?([^;\"'\s]+)"#,
            options: [.regularExpression, .caseInsensitive]) else { return nil }
        let match = String(contentType[range])
        guard let equals = match.firstIndex(of: "=") else { return nil }
        let value = match[match.index(after: equals)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        return value.isEmpty ? nil : value
    }

    private static func stringEncoding(forIANAName name: String) -> String.Encoding? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    /// Base64url (RFC 4648 §5, unpadded as Gmail sends it) → bytes.
    ///
    /// Single pass over the UTF-8 bytes: map `-`/`_` to `+`/`/` and append
    /// the missing `=` padding once. The old version built two intermediate
    /// Strings and then appended `=` in a loop whose `count` was an O(n)
    /// Character walk, which adds up on multi-MB inline parts at sync time.
    ///
    /// Behavior is identical for every input: valid base64url is all ASCII
    /// (so byte count == Character count), and any input with a byte outside
    /// the base64 alphabet fails `Data(base64Encoded:)` both ways regardless
    /// of how much padding was added. A length ≡ 1 (mod 4) still gets three
    /// `=` and still decodes to nil. Pinned against the old implementation
    /// in `SyncCPUEquivalenceTests`.
    static func decodeBase64URLData(_ s: String) -> Data? {
        let utf8 = s.utf8
        let padding = (4 - utf8.count % 4) % 4
        var bytes = [UInt8]()
        bytes.reserveCapacity(utf8.count + padding)
        for byte in utf8 {
            switch byte {
            case UInt8(ascii: "-"): bytes.append(UInt8(ascii: "+"))
            case UInt8(ascii: "_"): bytes.append(UInt8(ascii: "/"))
            default: bytes.append(byte)
            }
        }
        for _ in 0..<padding { bytes.append(UInt8(ascii: "=")) }
        return Data(base64Encoded: Data(bytes))
    }

    /// MIME types that carry iCalendar payloads (not just `.ics` filenames).
    static func isCalendarMime(_ mime: String) -> Bool {
        let m = mime.lowercased()
        return m.hasPrefix("text/calendar") || m.contains("application/ics")
    }

    /// First inline `text/calendar` part body (no attachmentId) in a full Gmail
    /// payload. Used when the attachment row was stored with the inline
    /// sentinel and we need the bytes again.
    static func inlineCalendarData(in g: GMessage) -> Data? {
        var found: Data?
        func walk(_ part: GMessage.Part?) {
            guard found == nil, let part else { return }
            let mime = part.mimeType ?? ""
            if isCalendarMime(mime),
               part.body?.attachmentId == nil,
               let b64 = part.body?.data,
               let bytes = decodeBase64URLData(b64), !bytes.isEmpty {
                found = bytes
                return
            }
            for child in part.parts ?? [] { walk(child) }
        }
        walk(g.payload)
        return found
    }

    /// Converts an HTML body to readable plain text. Non-content elements
    /// (`<style>`, `<script>`, `<head>`, comments) are removed *with their
    /// contents* — Notion Mail in particular ships a large `<style>` block
    /// whose CSS used to leak into quoted replies. Structural tags become
    /// newlines so paragraphs survive, then entities are decoded.
    /// Precompiled `stripHTML` patterns. `String.replacingOccurrences(of:
    /// options: .regularExpression)` compiles a fresh NSRegularExpression on
    /// every call, and stripHTML runs for every HTML-only message at sync
    /// time: ~10 compiles per message plus one per *line*. It cannot simply
    /// be made lazy — `bodyText` is persisted to `message_body` and read by
    /// export, MCP, Gmail filter matching and compose quoting.
    ///
    /// The patterns and options below are exactly the ones the String API
    /// used, and no replacement template contains `$` or `\`, so the output
    /// is byte-identical (pinned by `SyncCPUEquivalenceTests`).
    /// NSRegularExpression is documented thread-safe, which matters now that
    /// sync parses a page of messages concurrently.
    private static func stripRegex(_ pattern: String,
                                   caseInsensitive: Bool = false) -> NSRegularExpression {
        // Literal patterns: a compile failure is a programmer error.
        try! NSRegularExpression(pattern: pattern,
                                 options: caseInsensitive ? [.caseInsensitive] : [])
    }
    private static let stripNonContentTags: [NSRegularExpression] =
        ["style", "script", "head", "title"].map {
            stripRegex("<\($0)\\b[^>]*>[\\s\\S]*?</\($0)\\s*>", caseInsensitive: true)
        }
    private static let stripComments = stripRegex("<!--[\\s\\S]*?-->")
    private static let stripBreaks = stripRegex("<br\\s*/?\\s*>", caseInsensitive: true)
    private static let stripBlockClosers = stripRegex(
        "</(p|div|li|ul|ol|h[1-6]|tr|table|blockquote|pre|section|article|header|footer)\\s*>",
        caseInsensitive: true)
    private static let stripAnyTag = stripRegex("<[^>]+>")
    private static let stripHorizontalSpace = stripRegex("[ \\t\\r\u{00A0}]+")

    private static func replacing(_ regex: NSRegularExpression, in s: String,
                                  with template: String) -> String {
        regex.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: (s as NSString).length),
            withTemplate: template)
    }

    static func stripHTML(_ html: String) -> String {
        var s = html
        // Tags whose contents are not message text: drop tag AND contents.
        for regex in stripNonContentTags {
            s = replacing(regex, in: s, with: " ")
        }
        s = replacing(stripComments, in: s, with: " ")
        // Structure → newlines, before the tags themselves are stripped.
        // Closing tags only: open+close both breaking would leave a blank
        // line between every adjacent paragraph/list item.
        s = replacing(stripBreaks, in: s, with: "\n")
        s = replacing(stripBlockClosers, in: s, with: "\n")
        s = replacing(stripAnyTag, in: s, with: "")
        s = decodeEntities(s)
        // Tidy: collapse horizontal whitespace per line, trim line edges,
        // and allow at most one blank line between paragraphs.
        var lines: [String] = []
        for raw in s.components(separatedBy: "\n") {
            let line = replacing(stripHorizontalSpace, in: raw, with: " ")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty && (lines.last?.isEmpty ?? true) { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Decodes the common named entities plus numeric forms
    /// (`&#8217;`, `&#x1F600;`). `&amp;` goes last so `&amp;lt;` stays `&lt;`.
    /// Compiled once: decodeEntities runs inside every stripHTML (sync time).
    private static let numericEntityRegex = try? NSRegularExpression(
        pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")

    static func decodeEntities(_ s: String) -> String {
        var r = s
        for (entity, ch) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
                             ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            r = r.replacingOccurrences(of: entity, with: ch)
        }
        if let regex = numericEntityRegex {
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
    /// The name is the text before the same `<` that `emailAddress` uses, so
    /// the two never describe different mailboxes.
    static func displayName(fromHeader: String) -> String {
        if let lt = angleAddress(in: fromHeader)?.lt ?? fromHeader.firstIndex(of: "<") {
            let name = fromHeader[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return name }
        }
        return fromHeader.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    /// Extracts a bare email address from an address header.
    /// Tolerates malformed headers (missing or out-of-order angle brackets).
    ///
    /// Security: the result feeds block, VIP, reply and the remote-image
    /// gate, so it must be the mailbox the message really names. See
    /// `angleAddress(in:)` for which `<...>` pair counts.
    static func emailAddress(_ header: String) -> String {
        if let pair = angleAddress(in: header) {
            return String(header[header.index(after: pair.lt)..<pair.gt])
        }
        return header.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    /// The `<` and `>` of the angle-addr in one mailbox (RFC 5322 name-addr:
    /// `[display-name] angle-addr`, so the mailbox is the LAST pair).
    ///
    /// Brackets inside a quoted string or a parenthesized comment are sender
    /// text, not syntax: `"Boss <boss@trusted.com>" <attacker@evil.example>`
    /// and `Boss <attacker@evil.example> (<boss@trusted.com>)` both name the
    /// attacker. Taking the first pair let the decoy address through.
    ///
    /// Rule: the last `<` outside quotes and comments, then the first `>`
    /// outside them after it. A header with an unbalanced quote or comment
    /// has no such pair; retry with comments only, then quotes only, then
    /// plain text, so one stray `"` or `(` cannot turn the whole header
    /// into "quoted" text and hand the choice back to a decoy. Nil when the
    /// header has no ordered pair at all.
    private static func angleAddress(
        in header: String
    ) -> (lt: String.Index, gt: String.Index)? {
        guard header.contains("<") else { return nil }
        for (quotes, comments) in [(true, true), (false, true), (true, false), (false, false)] {
            if let pair = angleAddress(in: header, honorQuotes: quotes, honorComments: comments) {
                return pair
            }
        }
        return nil
    }

    private static func angleAddress(
        in header: String, honorQuotes: Bool, honorComments: Bool
    ) -> (lt: String.Index, gt: String.Index)? {
        var inQuotes = false
        var escaped = false
        var commentDepth = 0
        var lt: String.Index?
        var gt: String.Index?
        for index in header.indices {
            let ch = header[index]
            if escaped { escaped = false; continue }
            // Backslash escapes the next character in quotes and comments.
            if ch == "\\", inQuotes || commentDepth > 0 { escaped = true; continue }
            if inQuotes {
                if ch == "\"" { inQuotes = false }
                continue
            }
            if commentDepth > 0 {
                if ch == "(" { commentDepth += 1 }
                if ch == ")" { commentDepth -= 1 }
                continue
            }
            switch ch {
            case "\"" where honorQuotes: inQuotes = true
            case "(" where honorComments: commentDepth += 1
            case "<": lt = index; gt = nil
            case ">": if lt != nil, gt == nil { gt = index }
            default: break
            }
        }
        // Still inside a quote or comment at the end: the run was never
        // closed, so what it hid is not trustworthy as "not syntax".
        guard !inQuotes, commentDepth == 0, let lt, let gt else { return nil }
        return (lt, gt)
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
        "app", "tool", "terminal", "fileloc", "webloc", "inetloc", "mobileconfig",
        "shortcut", "scpt", "applescript", "scptd", "workflow", "action", "osax",
        "iso", "img", "dmg", "pkg", "mpkg", "appimage",
        "html", "htm", "svg", "docm", "xlsm", "pptm", "prefpane", "saver", "kext",
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
    /// Includes discarded drafts (`DRAFT TRASH`) — prefer `isLiveDraft` for
    /// unsent chrome / Continue / Discard.
    static func hasDraftLabel(_ labelIds: String) -> Bool {
        labelIds.split(whereSeparator: \.isWhitespace).contains { $0 == "DRAFT" }
    }

    /// Unsent draft the user can still continue: `DRAFT` without `TRASH`.
    /// Gmail keeps discarded drafts as `DRAFT TRASH` on the message; those are
    /// not live drafts (see `SyncEngine.trashDraftFlags`).
    static func isLiveDraft(_ labelIds: String) -> Bool {
        let labs = Set(labelIds.split(whereSeparator: \.isWhitespace).map(String.init))
        return labs.contains("DRAFT") && !labs.contains("TRASH")
    }

    /// Discarded compose attempt: still labeled DRAFT but already in TRASH.
    static func isDiscardedDraft(_ labelIds: String) -> Bool {
        let labs = Set(labelIds.split(whereSeparator: \.isWhitespace).map(String.init))
        return labs.contains("DRAFT") && labs.contains("TRASH")
    }

    /// Gmail `drafts.list` entry whose message id matches a local draft row.
    /// Pure — unit-tested. Nil when the draft is already gone on the server
    /// (orphaned local row, or DRAFT+TRASH no longer in the drafts list).
    static func remoteDraftId(
        forGmailMessageId messageId: String,
        drafts: [(id: String, messageId: String)]
    ) -> String? {
        drafts.first(where: { $0.messageId == messageId })?.id
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

    /// Newest *live* draft (oldest-first list → last match). Discarded
    /// `DRAFT TRASH` rows are ignored so Continue/Discard target a real draft.
    static func newestDraft(in msgs: [Message]) -> Message? {
        msgs.last(where: { isLiveDraft($0.labelIds) })
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
    ///
    /// Plain text: **per blank-line paragraph** `dir` (first strong char), so
    /// an English greeting + Hebrew body is not forced LTR for the whole
    /// message. Markdown blocks carry their own `dir` (no single outer wrap).
    static func authoredHeadHTML(_ userText: String) -> String {
        guard !userText.isEmpty else { return "" }
        if Markdown.looksLikeMarkdown(userText) {
            return Markdown.toHTML(userText)
        }
        return plainAuthoredHTML(userText)
    }

    /// Blank-line paragraphs each get their own `dir` + linkified body.
    /// Runs of N blank lines become N Gmail-style `<div><br></div>` spacers
    /// (multi-blank fidelity; whitespace-only lines count as blank).
    private static func plainAuthoredHTML(_ userText: String) -> String {
        let blocks = TextDirection.blocks(in: userText)
        if blocks.isEmpty {
            let dir = TextDirection.htmlDir(of: userText)
            return "<div dir=\"\(dir)\">\(ComposeLinks.htmlFragment(from: userText))</div>"
        }
        var out = ""
        for block in blocks {
            switch block {
            case .paragraph(let para):
                let dir = TextDirection.htmlDir(of: para)
                out += "<div dir=\"\(dir)\">\(ComposeLinks.htmlFragment(from: para))</div>"
            case .blanks(let n):
                // One spacer per blank line (Gmail-shaped).
                for _ in 0..<n {
                    out += "<div><br></div>"
                }
            }
        }
        return out
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

    /// Generates once per logical send; callers persist/pass the result across
    /// retries so Gmail can identify a message that may already have landed.
    static func makeMessageID(domain: String = "mishmail.local") -> String {
        "<\(UUID().uuidString.lowercased())@\(domain)>"
    }

    static func build(from: String, to: String, cc: String = "", bcc: String = "",
                      subject: String, bodyText: String, bodyHTML: String? = nil,
                      inReplyTo: String? = nil, references: String? = nil,
                      messageId: String? = nil,
                      attachments: [Attachment] = []) -> Data {
        var lines: [String] = []
        lines.append("From: \(clean(from))")
        lines.append("To: \(clean(to))")
        if !cc.isEmpty { lines.append("Cc: \(clean(cc))") }
        if !bcc.isEmpty { lines.append("Bcc: \(clean(bcc))") }
        lines.append("Subject: \(encodeHeader(clean(subject)))")
        if let messageId, !messageId.isEmpty {
            lines.append("Message-ID: \(clean(messageId))")
        }
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
