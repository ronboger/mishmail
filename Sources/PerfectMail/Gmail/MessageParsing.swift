import Foundation

/// Converts a Gmail API `GMessage` (format=full) into our local `Message` row.
enum MessageParser {
    static func parse(_ g: GMessage, accountId: String) -> Message {
        func header(_ name: String) -> String {
            g.payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        var text = ""
        var html: String?
        collectBodies(g.payload, text: &text, html: &html)
        if text.isEmpty, let html { text = Self.stripHTML(html) }

        let millis = Double(g.internalDate ?? "0") ?? 0
        let labels = g.labelIds ?? []
        return Message(
            id: "\(accountId):\(g.id)",
            accountId: accountId,
            gmailId: g.id,
            threadId: "\(accountId):\(g.threadId)",
            fromHeader: header("From"),
            toHeader: header("To"),
            ccHeader: header("Cc"),
            subject: header("Subject"),
            date: Date(timeIntervalSince1970: millis / 1000),
            snippet: g.snippet ?? "",
            bodyText: text,
            bodyHTML: html,
            messageIdHeader: header("Message-ID"),
            referencesHeader: header("References"),
            labelIds: labels.joined(separator: " "),
            isUnread: labels.contains("UNREAD")
        )
    }

    private static func collectBodies(_ part: GMessage.Part?, text: inout String, html: inout String?) {
        guard let part else { return }
        if let data = part.body?.data, let decoded = decodeBase64URL(data) {
            switch part.mimeType {
            case "text/plain" where text.isEmpty: text = decoded
            case "text/html" where html == nil: html = decoded
            default: break
            }
        }
        for child in part.parts ?? [] { collectBodies(child, text: &text, html: &html) }
    }

    static func decodeBase64URL(_ s: String) -> String? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
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
    static func emailAddress(_ header: String) -> String {
        if let lt = header.firstIndex(of: "<"), let gt = header.firstIndex(of: ">") {
            return String(header[header.index(after: lt)..<gt])
        }
        return header.trimmingCharacters(in: .whitespaces)
    }
}

/// Builds RFC 2822 messages for sending/replying.
enum MIMEBuilder {
    static func build(from: String, to: String, cc: String = "",
                      subject: String, bodyText: String,
                      inReplyTo: String? = nil, references: String? = nil) -> Data {
        var lines: [String] = []
        lines.append("From: \(from)")
        lines.append("To: \(to)")
        if !cc.isEmpty { lines.append("Cc: \(cc)") }
        lines.append("Subject: \(encodeHeader(subject))")
        if let inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(inReplyTo)")
            let refs = [references, inReplyTo].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            lines.append("References: \(refs)")
        }
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(Data(bodyText.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// RFC 2047 encoding for non-ASCII header values.
    private static func encodeHeader(_ value: String) -> String {
        value.allSatisfy(\.isASCII) ? value
            : "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
    }
}
