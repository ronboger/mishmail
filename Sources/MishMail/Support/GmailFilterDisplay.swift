import SwiftUI

/// Shared Notion Mail-style rendering of a Gmail filter as a sentence
/// ("If mail is from x, then Skip inbox"). Used by Settings → Gmail filters
/// and by the per-message matching-filters disclosure on a message card.
enum GmailFilterDisplay {

    static func iconName(for filter: GFilter) -> String {
        let adds = filter.action?.addLabelIds ?? []
        if filter.action?.forward != nil { return "arrowshape.turn.up.right" }
        if adds.contains(where: { !["TRASH", "SPAM", "STARRED", "IMPORTANT"].contains($0)
                                  && !$0.hasPrefix("CATEGORY_") }) {
            return "tag"
        }
        if adds.contains("TRASH") { return "trash" }
        if adds.contains("SPAM") || (filter.action?.removeLabelIds ?? []).contains("SPAM") {
            return "nosign"
        }
        return "line.3.horizontal.decrease"
    }

    /// A phrase with plain lead-in text and an optional emphasized value.
    struct Phrase: Equatable {
        var plain: String
        var value: String = ""
    }

    static func conditionPhrases(for filter: GFilter) -> [Phrase] {
        var out: [Phrase] = []
        if let from = filter.criteria?.from { out.append(.init(plain: "is from ", value: from)) }
        if let to = filter.criteria?.to { out.append(.init(plain: "is to ", value: to)) }
        if let subject = filter.criteria?.subject {
            out.append(.init(plain: "has subject ", value: subject))
        }
        if let query = filter.criteria?.query {
            out.append(.init(plain: "matches ", value: query))
        }
        if let negated = filter.criteria?.negatedQuery {
            out.append(.init(plain: "does not match ", value: negated))
        }
        if filter.criteria?.hasAttachment == true {
            out.append(.init(plain: "has an attachment"))
        }
        if let size = filter.criteria?.size {
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(size),
                                                      countStyle: .binary)
            let comparison = filter.criteria?.sizeComparison == "smaller" ? "smaller" : "larger"
            out.append(.init(plain: "is \(comparison) than ", value: formatted))
        }
        if out.isEmpty { out.append(.init(plain: "arrives")) }
        return out
    }

    /// Resolve user-label ids via `labelName`. System labels are named inline.
    static func actionPhrases(for filter: GFilter,
                              labelName: (String) -> String?) -> [Phrase] {
        var out: [Phrase] = []
        for id in filter.action?.addLabelIds ?? [] {
            switch id {
            case "TRASH": out.append(.init(plain: "Delete it"))
            case "STARRED": out.append(.init(plain: "Star it"))
            case "IMPORTANT": out.append(.init(plain: "Always mark it as important"))
            case "SPAM": out.append(.init(plain: "Send it to Spam"))
            case let cat where cat.hasPrefix("CATEGORY_"):
                let name = cat.dropFirst("CATEGORY_".count).capitalized
                out.append(.init(plain: "Categorize as ", value: name))
            default:
                let name = labelName(id) ?? id
                out.append(.init(plain: "Add label ", value: name))
            }
        }
        for id in filter.action?.removeLabelIds ?? [] {
            switch id {
            case "INBOX": out.append(.init(plain: "Skip inbox"))
            case "UNREAD": out.append(.init(plain: "Mark it as read"))
            case "SPAM": out.append(.init(plain: "Never send it to Spam"))
            case "IMPORTANT": out.append(.init(plain: "Never mark it as important"))
            default:
                let name = labelName(id) ?? id
                out.append(.init(plain: "Remove label ", value: name))
            }
        }
        if let forward = filter.action?.forward {
            out.append(.init(plain: "Forward to ", value: forward))
        }
        if out.isEmpty { out.append(.init(plain: "do nothing")) }
        return out
    }

    static func styledSentence(conditions: [Phrase], actions: [Phrase]) -> Text {
        var t = Text("If mail ").foregroundColor(.secondary)
        for (i, c) in conditions.enumerated() {
            if i > 0 { t = t + Text(" and ").foregroundColor(.secondary) }
            t = t + styled(c)
        }
        t = t + Text(", then ").foregroundColor(.secondary)
        for (i, a) in actions.enumerated() {
            if i > 0 { t = t + Text(" and ").foregroundColor(.secondary) }
            t = t + styled(a)
        }
        return t
    }

    private static func styled(_ phrase: Phrase) -> Text {
        let lead = Text(phrase.plain).foregroundColor(.primary)
        guard !phrase.value.isEmpty else { return lead }
        return lead + Text(phrase.value).foregroundColor(.accentColor)
    }
}

/// One filter as an icon + Notion-style sentence. Compact mode drops the
/// circular icon chrome for embedding under a message card.
struct GmailFilterSentenceRow: View {
    @EnvironmentObject var store: MailStore
    let filter: GFilter
    let accountId: String
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 8 : 12) {
            Image(systemName: GmailFilterDisplay.iconName(for: filter))
                .font(.system(size: compact ? 11 : 13))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 18 : 26, height: compact ? 18 : 26)
                .background(
                    compact ? Color.clear : Color.primary.opacity(0.06),
                    in: Circle())
            sentence
                .font(.system(size: compact ? 12 : 13))
                .lineSpacing(compact ? 2 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sentence: Text {
        let conditions = GmailFilterDisplay.conditionPhrases(for: filter)
        let actions = GmailFilterDisplay.actionPhrases(for: filter) { id in
            store.labelName(id, account: accountId)
        }
        return GmailFilterDisplay.styledSentence(conditions: conditions, actions: actions)
    }
}
