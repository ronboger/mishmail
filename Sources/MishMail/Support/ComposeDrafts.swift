import Foundation

/// Pure compose / draft helpers. `MailStore` owns the observable compose
/// card; this type answers parent-thread and undo-window questions without
/// AppKit.
enum ComposeDrafts {
    static let undoSendWindow: TimeInterval = 10

    /// Latest non-draft message to thread a reopened reply draft against.
    /// Nil for forward drafts (body carries the forward marker / Fwd: subject)
    /// and for draft-only threads (new compose never left the box).
    static func replyParent(forDraft draft: Message, inThread msgs: [Message]) -> Message? {
        if draft.bodyText.contains(ForwardComposer.marker) { return nil }
        if draft.subject.lowercased().hasPrefix("fwd:") { return nil }
        let nonDrafts = msgs.filter { !ForwardComposer.hasDraftLabel($0.labelIds) }
        guard !nonDrafts.isEmpty else { return nil }
        // Prefer matching References' last Message-ID (immediate parent) when
        // Gmail echoed it onto the draft row after save.
        if !draft.referencesHeader.isEmpty {
            let tokens = draft.referencesHeader
                .split(whereSeparator: \.isWhitespace).map(String.init)
            if let last = tokens.last {
                let bare = last.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                if let match = nonDrafts.last(where: {
                    let mid = $0.messageIdHeader
                        .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    return !mid.isEmpty && mid == bare
                }) {
                    return match
                }
            }
        }
        // Chronological last non-draft (msgs is oldest-first from messages(inThread:)).
        return nonDrafts.last
    }
}

/// How the user explicitly left a compose card.
///
/// A draft save can still be queued or on the wire at that moment. Whether
/// it may land depends on the exit: after Send / Schedule / Discard the
/// content is mail (or gone) and a late save would leave a stray draft;
/// after save-and-close (Esc / ✕) the save *is* the point and must land.
enum ComposeFinish: Equatable {
    case saveAndClose
    case send
    case schedule
    case discard

    /// True when a draft save that completes (or starts) after this exit
    /// must be skipped, and a draft it already created must be deleted.
    var dropsLateDraftSave: Bool {
        switch self {
        case .saveAndClose: return false
        case .send, .schedule, .discard: return true
        }
    }

    /// Same rule for "no explicit exit" (still editing, or the card was
    /// replaced and saves on unmount): never drop.
    static func dropsLateDraftSave(_ finish: ComposeFinish?) -> Bool {
        finish?.dropsLateDraftSave ?? false
    }
}
