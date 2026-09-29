import Foundation

/// Tool surface offered to the Ask Mish chat model.
///
/// It is the MCP catalog plus one Ask Mish-only tool (`send_draft`), converted
/// into the wire shape the LLM codecs take. Execution goes through
/// `MCPRouter.dispatch` — in-app chat and external MCP clients run the same
/// code — except `send_draft`, which `MailStore.askMishSendDraft` performs.
enum AskMishTools {

    /// Name of the Ask Mish-only send tool.
    static let sendDraftToolName = "send_draft"

    /// Sending is deliberately absent from `MCPTools.catalog`: an external MCP
    /// client can write a draft, but only the in-app confirm card can send it.
    static let sendDraftTool = MCPTools.ToolDefinition(
        name: sendDraftToolName,
        description: """
            Send an existing MishMail draft after user confirmation. \
            Create the draft first with create_draft.
            """,
        inputSchema: [
            "type": .string("object"),
            "properties": .object([
                "draft_id": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Draft message id, as returned by create_draft or list_drafts"),
                ]),
            ]),
            "required": .array([.string("draft_id")]),
        ]
    )

    /// Tools that change mail, VIPs, or summaries. Each one needs an in-chat
    /// confirm before it runs; everything else is a read and runs freely.
    static let writeToolNames: Set<String> = [
        "create_draft",
        "set_thread_summary",
        "clear_thread_summary",
        "add_vip",
        "add_vips",
        "set_vip_groups",
        "remove_vip",
        sendDraftToolName,
    ]

    /// Read tools. Every offered tool must be in this set or `writeToolNames`
    /// — a new mutating tool must not default to read.
    static let readToolNames: Set<String> = [
        "list_accounts",
        "list_threads",
        "search_threads",
        "get_thread",
        "list_drafts",
        "list_vips",
    ]

    /// Writes that can put mail on the wire. Return must not confirm these.
    static let clickRequiredToolNames: Set<String> = writeToolNames

    /// Read tools run freely. Anything not in `readToolNames` needs a confirm,
    /// including unknown names, so a new mutating tool cannot default to read.
    static func isWriteTool(_ name: String) -> Bool {
        !readToolNames.contains(name)
    }

    static func requiresExplicitClick(_ name: String) -> Bool {
        if clickRequiredToolNames.contains(name) { return true }
        // Unknown names are not in either set; they must not be Return-confirmable.
        return !readToolNames.contains(name) && !writeToolNames.contains(name)
    }

    /// MCP catalog + `send_draft`, converted for the LLM wire codecs.
    static func llmToolSpecs() -> [LLMToolSpec] {
        let encoder = JSONEncoder()
        // Stable key order: the specs go into a prompt that gets cached.
        encoder.outputFormatting = [.sortedKeys]
        return (MCPTools.catalog + [sendDraftTool]).map { definition in
            // Schemas are literal `AnyCodableJSON` trees, so encoding cannot
            // fail; an empty object would only lose the tool's arguments.
            let json = (try? encoder.encode(definition.inputSchema))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"type\":\"object\"}"
            return LLMToolSpec(
                name: definition.name,
                description: definition.description,
                inputSchemaJSON: json)
        }
    }

    /// Parse the model's arguments JSON into the `[String: JSONValue]` the MCP
    /// dispatcher takes. Throws on anything that is not a JSON object.
    /// Empty input means "no arguments" — several providers send `""` for
    /// no-argument tools such as `list_accounts`.
    static func decodeArguments(_ argumentsJSON: String) throws -> [String: JSONValue] {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let data = trimmed.data(using: .utf8) else {
            throw MCPToolError("Tool arguments are not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch {
            throw MCPToolError("Tool arguments must be a JSON object")
        }
    }

    // MARK: - Confirm card

    /// What the confirm card shows. `summary` is the one-line action;
    /// `bodyPreview` is the draft body when we have one.
    struct ConfirmContent: Equatable {
        var summary: String
        var bodyPreview: String?
        var requiresExplicitClick: Bool
    }

    /// Prefill for "Open in compose" on a `create_draft` confirm. Nil when
    /// the arguments have no To recipients.
    struct ComposePrefill: Equatable {
        var to: String
        var cc: String
        var bcc: String
        var subject: String
        var body: String
    }

    static func composePrefill(argumentsJSON: String) -> ComposePrefill? {
        guard let args = try? decodeArguments(argumentsJSON) else { return nil }
        let to = strings(args, "to")
        guard !to.isEmpty else { return nil }
        return ComposePrefill(
            to: to.joined(separator: ", "),
            cc: strings(args, "cc").joined(separator: ", "),
            bcc: strings(args, "bcc").joined(separator: ", "),
            subject: text(args, "subject") ?? "",
            body: text(args, "body") ?? "")
    }

    /// One short user-facing line for the confirm card. Falls back to the tool
    /// name when the arguments are unusable, so a card is never blank.
    ///
    /// This is the pure fallback: it only sees the model's arguments. For
    /// `send_draft` those arguments are a bare draft id, which tells the user
    /// nothing about the mail that leaves. The controller MUST prefer
    /// `MailStore.askMishSendConfirmPreview(draftId:)` for `send_draft` — it
    /// resolves the stored draft and names the recipients and the subject —
    /// and use this line only when the store returns `nil`.
    static func confirmSummary(toolName: String, argumentsJSON: String) -> String {
        confirmContent(toolName: toolName, argumentsJSON: argumentsJSON).summary
    }

    static func confirmContent(toolName: String, argumentsJSON: String) -> ConfirmContent {
        let args = (try? decodeArguments(argumentsJSON)) ?? [:]
        let summary = specificSummary(toolName: toolName, args: args)
            ?? "Run the tool \(toolName)."
        let body: String?
        if toolName == "create_draft" {
            body = preview(text(args, "body"))
        } else {
            body = nil
        }
        return ConfirmContent(
            summary: summary,
            bodyPreview: body,
            requiresExplicitClick: requiresExplicitClick(toolName))
    }

    private static func specificSummary(
        toolName: String,
        args: [String: JSONValue]
    ) -> String? {
        switch toolName {
        case "create_draft":
            return createDraftSummary(
                recipients: recipients(args),
                subject: text(args, "subject") ?? "",
                hiddenCount: strings(args, "bcc").count)

        case sendDraftToolName:
            guard let id = text(args, "draft_id") else { return nil }
            return "Send the draft \(id)."

        case "set_thread_summary":
            guard let threadId = text(args, "thread_id") else { return nil }
            var line = "Save an AI summary on thread \(threadId)."
            if let summary = text(args, "summary") {
                line += " \(quoted(summary))"
            }
            return line

        case "clear_thread_summary":
            guard let threadId = text(args, "thread_id") else { return nil }
            return "Delete the AI summary on thread \(threadId)."

        case "add_vip":
            guard let email = text(args, "email") else { return nil }
            var line = "Add the VIP \(email)."
            let groups = groupNames(args)
            if !groups.isEmpty { line += " Groups: \(joined(groups))." }
            return line

        case "add_vips":
            let emails = strings(args, "emails")
            guard !emails.isEmpty else { return nil }
            if emails.count == 1 { return "Add the VIP \(emails[0])." }
            return "Add \(emails.count) VIPs: \(joined(emails))."

        case "set_vip_groups":
            guard let email = text(args, "email") else { return nil }
            let groups = strings(args, "groups")
            if groups.isEmpty { return "Remove all groups from the VIP \(email)." }
            return "Set the groups on the VIP \(email) to \(joined(groups))."

        case "remove_vip":
            guard let email = text(args, "email") else { return nil }
            return "Remove the VIP \(email)."

        default:
            return nil
        }
    }

    /// Confirm line for `send_draft`, built from the **resolved** draft instead
    /// of the model's arguments. The confirm card is the last barrier before
    /// mail leaves, so it must name the recipients and the subject, not an
    /// opaque draft id. `MailStore.askMishSendConfirmPreview(draftId:)` reads
    /// the draft and calls this; keep the formatting here so it stays testable.
    ///
    /// - Parameters:
    ///   - recipients: visible recipients (To + Cc), already resolved.
    ///   - subject: draft subject; blank subjects are omitted.
    ///   - hiddenCount: number of Bcc recipients. Counted, never named — the
    ///     card must warn that blind copies leave without exposing them.
    static func sendDraftSummary(
        recipients: [String],
        subject: String,
        hiddenCount: Int = 0,
        from: String = ""
    ) -> String {
        let people = joined(recipients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        let hidden = max(0, hiddenCount)
        let hiddenPhrase = hidden == 0
            ? ""
            : "\(hidden) hidden recipient\(hidden == 1 ? "" : "s")"

        var line: String
        switch (people.isEmpty, hiddenPhrase.isEmpty) {
        case (false, false): line = "Send the draft to \(people) and \(hiddenPhrase)"
        case (false, true): line = "Send the draft to \(people)"
        case (true, false): line = "Send the draft to \(hiddenPhrase)"
        case (true, true): line = "Send the draft"
        }

        let title = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { line += " — \(quoted(title))" }
        let sender = from.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sender.isEmpty { line += " From \(sender)" }
        return line + "."
    }

    /// Summary for `create_draft`, including warnings that can be derived
    /// before the draft exists. The controller adds the off-thread warning
    /// after it compares recipients with the reply thread.
    static func createDraftSummary(recipients: [String], subject: String,
                                   hiddenCount: Int = 0,
                                   offThreadRecipients: [String] = []) -> String {
        let people = joined(recipients.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        var line = people.isEmpty ? "Create the draft" : "Create a draft to \(people)"
        let title = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { line += " — \(quoted(title))" }
        let hidden = max(0, hiddenCount)
        if hidden > 0 {
            line += " Warning: includes \(hidden) Bcc recipient\(hidden == 1 ? "" : "s")."
        } else {
            line += "."
        }
        if !offThreadRecipients.isEmpty {
            let listed = joined(offThreadRecipients)
            line += " Warning: recipient\(offThreadRecipients.count == 1 ? "" : "s") not on the thread: \(listed)."
        }
        return line
    }

    static func createDraftRecipients(argumentsJSON: String) -> [String] {
        let args = (try? decodeArguments(argumentsJSON)) ?? [:]
        return recipients(args)
    }

    static func createDraftReplyThreadID(argumentsJSON: String) -> String? {
        let args = (try? decodeArguments(argumentsJSON)) ?? [:]
        return text(args, "reply_to_thread_id")
    }

    static func createDraftSubject(argumentsJSON: String) -> String {
        let args = (try? decodeArguments(argumentsJSON)) ?? [:]
        return text(args, "subject") ?? ""
    }

    static func createDraftBccCount(argumentsJSON: String) -> Int {
        let args = (try? decodeArguments(argumentsJSON)) ?? [:]
        return strings(args, "bcc").count
    }

    /// Stable snapshot of the draft the user confirmed. Send aborts if the
    /// stored draft no longer matches.
    static func sendFingerprint(accountId: String, from: String,
                                to: String, cc: String, bcc: String,
                                subject: String, body: String) -> String {
        [accountId, from, to, cc, bcc, subject, body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\u{1e}")
    }

    /// Recipients on the outgoing draft that are not already on the thread.
    /// Addresses compare case-insensitively.
    static func offThreadRecipients(sending: [String],
                                    threadAddresses: [String]) -> [String] {
        let thread = Set(threadAddresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        var seen = Set<String>()
        var out: [String] = []
        for raw in sending {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !key.isEmpty, !thread.contains(key), seen.insert(key).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    static func addresses(in header: String) -> [String] {
        MessageParser.splitAddresses(header)
            .map { MessageParser.emailAddress($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Full draft body for the confirm card. The view bounds it in a scroll
    /// region and makes whitespace-only hiding visible.
    static func preview(_ text: String?, limit: Int = 500) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        _ = limit // Kept for source compatibility with older callers.
        return trimmed
    }

    /// Replaces runs of blank lines with an explicit marker in bounded UI.
    /// The original body remains unchanged for compose and send.
    ///
    /// A line counts as blank when it holds only whitespace, separators
    /// (`\p{Z}`: NBSP, U+3000, …) or invisible format characters
    /// (`\p{Cf}`: U+200B, U+FEFF, …). Every line-break form is normalized
    /// first, so CRLF, U+2028 or a form feed cannot sneak a run past the
    /// check.
    static func collapsedBlankLines(_ text: String) -> String {
        let lines = normalizedLineBreaks(text)
            .split(separator: "\n", omittingEmptySubsequences: false)
        var output: [String] = []
        var run = 0
        func flushRun() {
            if run >= 2 {
                output.append("[\(run) blank lines]")
            } else if run == 1 {
                output.append("")
            }
            run = 0
        }
        for line in lines {
            if isBlankLine(line) {
                run += 1
            } else {
                flushRun()
                output.append(String(line))
            }
        }
        flushRun()
        return output.joined(separator: "\n")
    }

    /// CRLF, CR, NEL, U+2028, U+2029, VT and FF all become `\n`.
    static func normalizedLineBreaks(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D:
                out.append("\n")
                previousWasCR = true
                continue
            case 0x0A:
                if !previousWasCR { out.append("\n") }
            case 0x0B, 0x0C, 0x85, 0x2028, 0x2029:
                out.append("\n")
            default:
                out.append(scalar)
            }
            previousWasCR = false
        }
        return String(out)
    }

    /// Hangul and Braille fillers render as nothing but are letters or
    /// symbols, so `\p{Z}` misses them.
    private static let invisibleFillers: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800]

    static func isBlankLine<S: StringProtocol>(_ line: S) -> Bool {
        line.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isWhitespace
                || scalar.properties.generalCategory == .spaceSeparator
                || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
                || scalar.properties.generalCategory == .format
                || invisibleFillers.contains(scalar.value)
        }
    }

    /// Scalars that render as nothing (or reorder text) and so can hide a
    /// payload from the confirm card: every format (Cf) scalar — zero-width,
    /// bidi controls, Unicode tags U+E0000–E007F — plus variation selectors,
    /// fillers, the soft hyphen, and the combining grapheme joiner. The
    /// preview shows each one as a visible `⟨U+XXXX⟩` marker.
    static func isRevealedFormatCharacter(_ value: UInt32) -> Bool {
        if (0xE0000...0xE007F).contains(value)          // tags
            || (0xFE00...0xFE0F).contains(value)         // variation selectors
            || (0xE0100...0xE01EF).contains(value)
            || [0x00AD, 0x034F, 0x115F, 0x1160, 0x180E, 0x3164, 0xFFA0].contains(value) {
            return true
        }
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.generalCategory == .format
    }

    static func revealedInvisibleCharacters(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if isRevealedFormatCharacter(scalar.value) {
                out += String(format: "⟨U+%04X⟩", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// A long run of spaces inside one line (non-breaking ones cannot wrap)
    /// renders as a tall blank gap. Runs of 8+ become a counted marker.
    static func collapsedSpaceRuns(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[\t\p{Zs}]{8,}"#) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let run = ns.substring(with: match.range)
            out += "⟨\(run.unicodeScalars.count) spaces⟩"
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Caps combining marks per character: a flood of marks stacks glyphs
    /// over neighbouring lines while counting as one character.
    static func cappedCombiningMarks(_ text: String, keep: Int = 3) -> String {
        var out = ""
        for character in text {
            let scalars = Array(character.unicodeScalars)
            let marks = scalars.dropFirst().filter {
                switch $0.properties.generalCategory {
                case .nonspacingMark, .enclosingMark, .spacingMark: return true
                default: return false
                }
            }
            guard marks.count > keep else { out.append(character); continue }
            var kept = 0
            for (index, scalar) in scalars.enumerated() {
                if index > 0, marks.contains(scalar) {
                    guard kept < keep else { continue }
                    kept += 1
                }
                out.unicodeScalars.append(scalar)
            }
            out += "⟨+\(marks.count - keep) marks⟩"
        }
        return out
    }

    /// Confirm-card text: line breaks normalized, blank runs collapsed to
    /// a counted marker, then invisible format characters made visible.
    static func confirmPreviewText(_ body: String) -> String {
        revealedInvisibleCharacters(
            cappedCombiningMarks(collapsedSpaceRuns(collapsedBlankLines(body))))
    }

    /// Line count for the card header. Empty lines count: a run of blank
    /// lines is exactly how a body hides text below the fold.
    static func confirmPreviewLineCount(_ body: String) -> Int {
        guard !body.isEmpty else { return 0 }
        return normalizedLineBreaks(body)
            .split(separator: "\n", omittingEmptySubsequences: false).count
    }

    // MARK: - Argument readers

    /// Trimmed non-empty string argument.
    private static func text(_ args: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let s)? = args[key] else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func strings(_ args: [String: JSONValue], _ key: String) -> [String] {
        guard case .array(let items)? = args[key] else { return [] }
        return items.compactMap {
            guard case .string(let s) = $0 else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// To + Cc + Bcc, in that order.
    private static func recipients(_ args: [String: JSONValue]) -> [String] {
        strings(args, "to") + strings(args, "cc") + strings(args, "bcc")
    }

    /// `group` and `groups` merged — both spellings are accepted by the VIP tools.
    private static func groupNames(_ args: [String: JSONValue]) -> [String] {
        var names = strings(args, "groups")
        if let single = text(args, "group"), !names.contains(single) {
            names.insert(single, at: 0)
        }
        return names
    }

    /// Cap on names listed in a confirm line; the rest become a count.
    private static let listLimit = 3

    private static func joined(_ values: [String]) -> String {
        guard values.count > listLimit else { return values.joined(separator: ", ") }
        let head = values.prefix(listLimit).joined(separator: ", ")
        return "\(head) and \(values.count - listLimit) more"
    }

    /// Cap on a quoted subject; long ones would push the card off-screen.
    private static let quoteLimit = 60

    private static func quoted(_ value: String) -> String {
        guard value.count > quoteLimit else { return "“\(value)”" }
        return "“\(value.prefix(quoteLimit))…”"
    }
}
