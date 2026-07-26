import Foundation

/// In-place refresh for the open reading pane: when this thread's content
/// revision moves (`MailStore.contentRevision(of:)`), ThreadDetailView
/// re-queries its header rows and merges them over what's on screen.
enum ThreadRefresh {

    /// True when a reading-pane message still needs a body fetch.
    static func needsBodyLoad(_ message: Message) -> Bool {
        message.bodyText.isEmpty && (message.bodyHTML == nil || message.bodyHTML?.isEmpty == true)
    }

    /// Fresh header rows win (labels/read state may have changed); bodies
    /// already hydrated in `current` are spliced back in so a refresh never
    /// collapses an open card to "Loading…". Messages gone from `fresh` are
    /// gone for real (e.g. a discarded draft).
    static func merge(current: [Message], fresh: [Message]) -> [Message] {
        let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return fresh.map { row in
            guard needsBodyLoad(row), let old = byId[row.id], !needsBodyLoad(old) else {
                return row
            }
            var merged = row
            merged.bodyText = old.bodyText
            merged.bodyHTML = old.bodyHTML
            return merged
        }
    }

    /// Initial reading-pane scroll id: newest sent when multi-message; nil for
    /// a single card (default top). Draft-only multi falls back to last row.
    static func initialScrolledMessageId(in messages: [Message]) -> String? {
        guard messages.count > 1 else { return nil }
        return ForwardComposer.newestSentMessage(in: messages)?.id
            ?? messages.last?.id
    }

    /// Flatten a payload into the (message, attachment) pairs the thread meta
    /// row shows. Shared by the seeding init and the load path so a pane
    /// rendered from the mirror is identical to one rendered from a load.
    static func threadAttachments(
        in payload: ThreadDetailPayload
    ) -> [(message: Message, attachment: AttachmentRow)] {
        payload.messages.flatMap { msg in
            (payload.attachmentsByMessageId[msg.id] ?? []).map {
                (message: msg, attachment: $0)
            }
        }
    }

    /// Message ids that arrive hydrated on open and must not re-trigger a body
    /// fetch (newest sent + any draft cards).
    static func initialBodyLoadSeedIds(in messages: [Message]) -> [String] {
        var ids: [String] = []
        if let sentId = ForwardComposer.newestSentMessage(in: messages)?.id {
            ids.append(sentId)
        }
        for draft in messages where ForwardComposer.hasDraftLabel(draft.labelIds) {
            ids.append(draft.id)
        }
        return ids
    }
}
