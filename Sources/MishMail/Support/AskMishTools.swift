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
    static let clickRequiredToolNames: Set<String> = [
        "create_draft",
        sendDraftToolName,
    ]

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
            let people = joined(recipients(args))
            guard !people.isEmpty else { return nil }
            var line = "Create a draft to \(people)."
            if let subject = text(args, "subject"), !subject.isEmpty {
                line += " Subject: \(quoted(subject))."
            }
            return line

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

    /// Truncated draft body for the confirm card. Nil when empty.
    static func preview(_ text: String?, limit: Int = 500) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
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
