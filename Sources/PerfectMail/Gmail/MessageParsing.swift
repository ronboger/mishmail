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

    static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .decodingHTMLEntities()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Builds RFC 2822 messages for sending/replying, optionally multipart/mixed
/// with attachments.
enum MIMEBuilder {
    struct Attachment: Codable {
        let filename: String
        let mimeType: String
        let data: Data
    }

    static func build(from: String, to: String, cc: String = "", bcc: String = "",
                      subject: String, bodyText: String,
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

        let textB64 = Data(bodyText.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        if attachments.isEmpty {
            lines.append("Content-Type: text/plain; charset=UTF-8")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("")
            lines.append(textB64)
        } else {
            let boundary = "pm-\(UUID().uuidString)"
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/plain; charset=UTF-8")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("")
            lines.append(textB64)
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
