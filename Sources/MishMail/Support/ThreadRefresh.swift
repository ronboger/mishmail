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

    /// True when `lhs` and `rhs` would render the same reading pane, so a
    /// refresh can skip reassigning `messages`.
    ///
    /// Replaces a synthesized `!=` over whole `Message` values, which walked
    /// every hydrated body — multi-MB HTML — on the main actor on each sync
    /// refresh. Headers (ids, labels, read state, dates, addresses, auth,
    /// List-Unsubscribe …) are still compared in full: they are small, and
    /// comparing them via `Message ==` with bodies blanked keeps any field
    /// added later covered automatically.
    ///
    /// Bodies compare by UTF-8 length (O(1) for native strings). That is
    /// exact for what a refresh can change on a sent message — Gmail message
    /// bodies are immutable per id, so the only transitions are hydrate
    /// (empty ↔ full) and `cid:` → `data:` inlining, both of which change the
    /// length. Draft bodies are the exception (an edit can keep the length),
    /// so a message labelled DRAFT on either side still compares its bodies
    /// in full; those are small.
    static func isDisplayEquivalent(_ lhs: [Message], _ rhs: [Message]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) where !isDisplayEquivalent(a, b) {
            return false
        }
        return true
    }

    static func isDisplayEquivalent(_ a: Message, _ b: Message) -> Bool {
        var headerA = a
        var headerB = b
        headerA.bodyText = ""
        headerA.bodyHTML = nil
        headerB.bodyText = ""
        headerB.bodyHTML = nil
        guard headerA == headerB else { return false }
        if ForwardComposer.hasDraftLabel(a.labelIds)
            || ForwardComposer.hasDraftLabel(b.labelIds) {
            return a.bodyText == b.bodyText && a.bodyHTML == b.bodyHTML
        }
        return a.bodyText.utf8.count == b.bodyText.utf8.count
            && a.bodyHTML?.utf8.count == b.bodyHTML?.utf8.count
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
        for draft in messages where ForwardComposer.isLiveDraft(draft.labelIds) {
            ids.append(draft.id)
        }
        return ids
    }
}

/// Draft vs sent split of an open thread's messages, computed once per
/// `messages` change. The reading pane reads these on every body pass (card
/// chrome choice, draft banner, expand seed); recomputing them there split
/// each message's `labelIds` into a `Set` several times per pass.
struct ThreadMessageRoles: Equatable {
    /// Live (unsent, not trashed) drafts, in display order.
    let liveDraftIds: [String]
    /// Everything else (sent mail + discarded DRAFT+TRASH rows), in display
    /// order — these render as `MessageCard`.
    let nonDraftIds: [String]
    /// Newest message without a DRAFT label — the default expanded card.
    let lastNonDraftId: String?
    private let liveDraftIdSet: Set<String>

    init(messages: [Message]) {
        var live: [String] = []
        var nonDraft: [String] = []
        for message in messages {
            if ForwardComposer.isLiveDraft(message.labelIds) {
                live.append(message.id)
            } else {
                nonDraft.append(message.id)
            }
        }
        liveDraftIds = live
        nonDraftIds = nonDraft
        liveDraftIdSet = Set(live)
        lastNonDraftId = ForwardComposer.newestSentMessage(in: messages)?.id
    }

    func isLiveDraft(_ id: String) -> Bool {
        liveDraftIdSet.contains(id)
    }
}
