import Foundation

/// Live tool-trace helpers for the Ask Mish panel. Pure.
enum AskMishTrace {

    enum Status: String, Equatable {
        case running, done, failed
    }

    struct ThreadRef: Equatable, Identifiable {
        var id: String
        var subject: String
    }

    struct Tool: Equatable, Identifiable {
        var id: String
        var name: String
        var status: Status
        var argumentsJSON: String
        var resultPreview: String?
        var threads: [ThreadRef]
        var canUndoSend: Bool
    }

    struct PromptChip: Equatable, Identifiable {
        var title: String
        var prompt: String
        var id: String { title }
    }

    static func traces(calls: [LLMToolCall], results: [LLMToolResult]) -> [Tool] {
        let byID = Dictionary(results.map { ($0.callID, $0) }, uniquingKeysWith: { first, _ in first })
        return calls.map { call in
            let running = running(call)
            guard let result = byID[call.id] else { return running }
            return finished(from: running, result: result)
        }
    }

    static func running(_ call: LLMToolCall) -> Tool {
        Tool(id: call.id, name: call.name, status: .running,
             argumentsJSON: call.argumentsJSON, resultPreview: nil,
             threads: [], canUndoSend: false)
    }

    /// One short live line. Present tense while running, past when done.
    static func statusLabel(_ tool: Tool) -> String {
        let verb: String
        switch (tool.name, tool.status) {
        case ("search_threads", .running): verb = "Searching mail…"
        case ("search_threads", _): verb = "Searched mail"
        case ("list_threads", .running): verb = "Listing mail…"
        case ("list_threads", _): verb = "Listed mail"
        case ("get_thread", .running): verb = "Reading thread…"
        case ("get_thread", _): verb = "Read thread"
        case ("list_accounts", .running): verb = "Listing accounts…"
        case ("list_accounts", _): verb = "Listed accounts"
        case ("list_drafts", .running): verb = "Listing drafts…"
        case ("list_drafts", _): verb = "Listed drafts"
        case ("list_vips", .running): verb = "Listing VIPs…"
        case ("list_vips", _): verb = "Listed VIPs"
        case ("create_draft", .running): verb = "Creating a draft…"
        case ("create_draft", _): verb = "Created a draft"
        case ("send_draft", .running): verb = "Queuing send…"
        case ("send_draft", _): verb = "Queued send"
        case ("set_thread_summary", .running): verb = "Saving a summary…"
        case ("set_thread_summary", _): verb = "Saved a summary"
        case ("clear_thread_summary", .running): verb = "Clearing a summary…"
        case ("clear_thread_summary", _): verb = "Cleared a summary"
        case ("add_vip", .running), ("add_vips", .running): verb = "Adding VIP…"
        case ("add_vip", _), ("add_vips", _): verb = "Added VIP"
        case ("remove_vip", .running): verb = "Removing VIP…"
        case ("remove_vip", _): verb = "Removed VIP"
        case ("set_vip_groups", .running): verb = "Updating VIP groups…"
        case ("set_vip_groups", _): verb = "Updated VIP groups"
        case (_, .running): verb = "Running \(tool.name)…"
        default: verb = tool.name
        }
        if tool.status == .failed { return verb + " — failed" }
        return verb
    }

    /// One-line argument cue (query, mailbox, thread id). Nil when nothing useful.
    static func argumentSummary(name: String, argumentsJSON: String) -> String? {
        let args = (try? AskMishTools.decodeArguments(argumentsJSON)) ?? [:]
        switch name {
        case "search_threads":
            return string(args, "query")
        case "list_threads":
            return string(args, "mailbox")
        case "get_thread", "set_thread_summary", "clear_thread_summary":
            return string(args, "thread_id")
        case "create_draft":
            if let to = stringArray(args, "to"), !to.isEmpty {
                return to.prefix(2).joined(separator: ", ")
            }
            return nil
        case "send_draft":
            return string(args, "draft_id")
        case "add_vip", "remove_vip", "set_vip_groups":
            return string(args, "email")
        default:
            return nil
        }
    }

    static func finished(from running: Tool, result: LLMToolResult) -> Tool {
        var next = running
        next.status = result.isError ? .failed : .done
        next.resultPreview = preview(result.content)
        next.threads = threads(name: running.name,
                               argumentsJSON: running.argumentsJSON,
                               result: result.content)
        next.canUndoSend = running.name == AskMishTools.sendDraftToolName
            && !result.isError
            && result.content.contains("\"status\":\"queued\"")
        return next
    }

    static func threads(name: String, argumentsJSON: String,
                        result: String) -> [ThreadRef] {
        if name == "get_thread" {
            let args = (try? AskMishTools.decodeArguments(argumentsJSON)) ?? [:]
            guard let id = string(args, "thread_id") else { return [] }
            return [ThreadRef(id: id, subject: markdownTitle(result) ?? "")]
        }
        if name == "search_threads" || name == "list_threads" {
            return threadsFromJSONList(result)
        }
        if name == "create_draft" {
            return threadFromObject(result)
        }
        return []
    }

    /// One audit sentence for a finished turn. Nil when no tools ran.
    static func auditLine(tools: [Tool]) -> String? {
        let done = tools.filter { $0.status != .running }
        guard !done.isEmpty else { return nil }
        var threadIDs = Set<String>()
        var created = 0
        var sent = 0
        var failed = 0
        for tool in done {
            if tool.status == .failed { failed += 1 }
            for ref in tool.threads { threadIDs.insert(ref.id) }
            if tool.name == "create_draft", tool.status == .done { created += 1 }
            if tool.name == AskMishTools.sendDraftToolName, tool.status == .done { sent += 1 }
        }
        var parts: [String] = []
        if !threadIDs.isEmpty {
            let n = threadIDs.count
            parts.append("Read \(n) thread\(n == 1 ? "" : "s")")
        } else if done.contains(where: {
            ["search_threads", "list_threads", "get_thread"].contains($0.name)
                && $0.status == .done
        }) {
            parts.append("Read mail")
        }
        if created > 0 {
            parts.append("Created \(created) draft\(created == 1 ? "" : "s")")
        }
        if sent > 0 {
            parts.append("Queued \(sent) send\(sent == 1 ? "" : "s")")
        } else if created > 0 {
            parts.append("Sent nothing")
        }
        if failed > 0 {
            parts.append("\(failed) failed")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ". ") + "."
    }

    static func emptyPrompts(hasSelectedThread: Bool) -> [PromptChip] {
        if hasSelectedThread {
            return [
                PromptChip(title: "Summarize this",
                           prompt: "Summarize this thread."),
                PromptChip(title: "Draft a yes",
                           prompt: "Draft a reply saying yes."),
                PromptChip(title: "Find related mail",
                           prompt: "Find other mail from this sender."),
            ]
        }
        return [
            PromptChip(title: "What's unread?",
                       prompt: "What unread mail needs my attention?"),
            PromptChip(title: "Who should I reply to?",
                       prompt: "Search my mail for the most recent conversation I should reply to."),
            PromptChip(title: "What's waiting?",
                       prompt: "List unread threads in my inbox."),
        ]
    }

    static func followUps(toolNames: [String], hasSelectedThread: Bool) -> [PromptChip] {
        var chips: [PromptChip] = []
        if toolNames.contains("create_draft") {
            chips.append(PromptChip(title: "Send it",
                                    prompt: "Send the draft you just created."))
        }
        if toolNames.contains("search_threads") || toolNames.contains("list_threads") {
            chips.append(PromptChip(title: "Summarize the top one",
                                    prompt: "Summarize the first result."))
            chips.append(PromptChip(title: "Draft a reply",
                                    prompt: "Draft a reply to the most relevant thread."))
        }
        if toolNames.contains("get_thread") || hasSelectedThread {
            chips.append(PromptChip(title: "Draft a reply",
                                    prompt: "Draft a reply to this thread."))
            chips.append(PromptChip(title: "Find related mail",
                                    prompt: "Find other mail from this sender."))
        }
        var seen = Set<String>()
        return chips.filter { seen.insert($0.title).inserted }.prefix(3).map { $0 }
    }

    // MARK: - Internals

    private static func preview(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 160 { return trimmed }
        return String(trimmed.prefix(160)) + "…"
    }

    private static func markdownTitle(_ markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let title = trimmed.dropFirst(2)
                    .trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : String(title)
            }
        }
        return nil
    }

    private static func threadsFromJSONList(_ json: String) -> [ThreadRef] {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.prefix(8).compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return ThreadRef(id: id, subject: (row["subject"] as? String) ?? "")
        }
    }

    private static func threadFromObject(_ json: String) -> [ThreadRef] {
        guard let data = json.data(using: .utf8),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (row["threadId"] as? String) ?? (row["thread_id"] as? String),
              !id.isEmpty
        else { return [] }
        return [ThreadRef(id: id, subject: (row["subject"] as? String) ?? "")]
    }

    private static func string(_ args: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let s)? = args[key] else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringArray(_ args: [String: JSONValue], _ key: String) -> [String]? {
        guard case .array(let items)? = args[key] else { return nil }
        let values = items.compactMap { item -> String? in
            guard case .string(let s) = item else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? nil : values
    }
}
