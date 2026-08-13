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

    /// Read tools run freely; write tools need an in-chat confirm.
    static func isWriteTool(_ name: String) -> Bool {
        writeToolNames.contains(name)
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

    /// One short user-facing line for the confirm card. Falls back to the tool
    /// name when the arguments are unusable, so a card is never blank.
    ///
    /// This is the pure fallback: it only sees the model's arguments. For
    /// `send_draft` those arguments are a bare draft id, which tells the user
    /// nothing about the mail that leaves. The controller MUST prefer
    /// `MailStore.askMishSendConfirmSummary(draftId:)` for `send_draft` — it
    /// resolves the stored draft and names the recipients and the subject —
    /// and use this line only when the store returns `nil`.
    static func confirmSummary(toolName: String, argumentsJSON: String) -> String {
        let args = (try? decodeArguments(argumentsJSON)) ?? [:]
        return specificSummary(toolName: toolName, args: args)
            ?? "Run the tool \(toolName)."
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
            return "Save an AI summary on thread \(threadId)."

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
    /// opaque draft id. `MailStore.askMishSendConfirmSummary(draftId:)` reads
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
        hiddenCount: Int = 0
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
        return line + "."
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
